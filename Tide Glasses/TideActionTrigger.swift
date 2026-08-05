//
//  TideActionTrigger.swift
//  Tide Glasses
//
//  Turns something said out loud into a calendar or reminder action.
//
//  Third trigger in the same family as "take a photo" and "update memory", and
//  built the same way for the same reason: the phone decides, locally, before
//  anything is sent. Asking the model to classify the request would cost a
//  round trip on top of an action that takes milliseconds to run, and the
//  utterance would leave the phone to do it. Nothing here touches the network.
//
//  Dates come from NSDataDetector — the same parser behind tappable dates in
//  Mail and Messages. It already understands "tomorrow at 6", "next Tuesday",
//  "in two hours". Three of its habits had to be worked around, and each one is
//  measured rather than assumed; see the notes on each fix below.
//

import Foundation

enum TideAction: Equatable {
    case createReminder(title: String, due: Date?)
    case listReminders
    case createEvent(title: String, start: Date, duration: TimeInterval)
    case listEvents(day: Date)
}

enum TideActionTrigger {
    // MARK: - Vocabulary

    /// Note "reminds" is absent on purpose: "that reminds me of a film" is not
    /// a request to create anything.
    private static let reminderWords: Set<String> = ["remind", "reminder", "reminders"]
    private static let calendarWords: Set<String> = ["calendar", "schedule", "agenda"]

    private static var triggerWords: Set<String> { reminderWords.union(calendarWords) }

    private static let createWords: Set<String> = [
        "add", "create", "put", "make", "new", "set", "book", "schedule",
    ]
    private static let questionWords: Set<String> = [
        "what", "whats", "which", "list", "show", "any", "anything",
        "when", "read", "tell", "do", "got", "have",
    ]

    /// Dropped from the front of a title until real content appears.
    private static let leadingFiller: Set<String> = [
        "add", "create", "put", "make", "new", "set", "book", "up",
        "me", "to", "a", "an", "the", "that", "my", "on", "for", "at", "in",
        "please", "i", "want", "need", "event", "appointment", "and", "of",
    ]

    /// Dropped from the end, where a stripped date usually leaves a dangling
    /// preposition — "lunch with" after "with Ana" never existed.
    private static let trailingFiller: Set<String> = [
        "at", "on", "for", "to", "in", "by", "the", "a", "an", "and", "my", "of", "with",
    ]

    /// NSDataDetector treats meal names as times and swallows them into the
    /// match: "lunch tomorrow at noon" comes back as one range, so cutting the
    /// date out also deletes the event's name. Measured, not guessed.
    private static let mealWords = ["breakfast", "brunch", "lunch", "dinner", "supper"]

    private static let numberWords: [(word: String, value: Int)] = [
        ("one", 1), ("two", 2), ("three", 3), ("four", 4), ("five", 5), ("six", 6),
        ("seven", 7), ("eight", 8), ("nine", 9), ("ten", 10), ("eleven", 11), ("twelve", 12),
    ]

    /// How far in the sentence a trigger word may appear. "What reminders do I
    /// have" puts it second; anything deep in a long sentence is someone
    /// talking rather than asking.
    private static let triggerWindow = 6

    // MARK: - Parsing

    /// Returns the action the wearer asked for, or nil when this is an ordinary
    /// question that should go to the AI as normal.
    static func action(in text: String, now: Date = Date()) -> TideAction? {
        let words = tokens(in: text)
        guard !words.isEmpty else { return nil }

        let window = words.prefix(triggerWindow)
        let isReminder = window.contains { reminderWords.contains($0) }
        let isCalendar = window.contains { calendarWords.contains($0) }
        guard isReminder || isCalendar else { return nil }

        let (date, duration, remainder) = extractDate(from: text, now: now)
        let wantsCreate = shouldCreate(words: words, text: text, isReminder: isReminder, hasDate: date != nil)
        let name = title(from: remainder)

        // Reminders win when both words appear — "remind me about my calendar
        // sync" is a reminder, not a calendar query.
        if isReminder {
            guard wantsCreate, !name.isEmpty else { return .listReminders }
            return .createReminder(title: name, due: date)
        }

        guard wantsCreate, !name.isEmpty, let start = date else {
            // "Calendar, add lunch" with no time is not schedulable; showing
            // the day is more useful than inventing a slot.
            return .listEvents(day: date ?? now)
        }
        return .createEvent(title: name, start: start, duration: duration)
    }

    private static func shouldCreate(
        words: [String],
        text: String,
        isReminder: Bool,
        hasDate: Bool
    ) -> Bool {
        // "Remind me to …" is unambiguous however the rest of it reads.
        if text.range(of: "remind me to", options: .caseInsensitive) != nil { return true }
        if words.contains(where: { createWords.contains($0) }) { return true }
        if words.prefix(4).contains(where: { questionWords.contains($0) }) { return false }

        // A bare "calendar tomorrow" is a look-up; "remind me, milk" is not.
        return isReminder && hasDate
    }

    // MARK: - Dates

    private static let detector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.date.rawValue
    )

    /// Pulls the first date out, and hands back the sentence without it so the
    /// title is not left saying "call Mom tomorrow at six".
    private static func extractDate(
        from text: String,
        now: Date
    ) -> (date: Date?, duration: TimeInterval, remainder: String) {
        let normalized = normalizingSpokenTimes(text)
        guard let detector else { return (nil, 3600, normalized) }

        let range = NSRange(normalized.startIndex..., in: normalized)
        guard let match = detector.matches(in: normalized, range: range).first,
              let matched = Range(match.range, in: normalized),
              let parsed = match.date
        else { return (nil, 3600, normalized) }

        let date = correctingMorning(parsed, spokenAs: String(normalized[matched]), now: now)

        var remainder = normalized
        remainder.removeSubrange(removalRange(for: matched, in: normalized))

        return (date, match.duration > 0 ? match.duration : 3600, remainder)
    }

    /// Keeps a meal name out of the range that gets deleted, so "lunch" stays
    /// in the title while "tomorrow at noon" is removed.
    private static func removalRange(
        for matched: Range<String.Index>,
        in text: String
    ) -> Range<String.Index> {
        let matchedText = text[matched].lowercased()
        for meal in mealWords where matchedText.hasPrefix(meal) {
            let mealEnd = text.index(matched.lowerBound, offsetBy: meal.count)
            return mealEnd..<matched.upperBound
        }
        return matched
    }

    /// NSDataDetector reads digits but not spoken numbers: "tomorrow at six"
    /// matches only "tomorrow" and silently defaults to noon, while "tomorrow
    /// at 6" parses correctly. Rewriting the number is enough, and it is only
    /// done next to a time word so "buy six eggs" is left alone.
    private static func normalizingSpokenTimes(_ text: String) -> String {
        var result = text
        for (word, value) in numberWords {
            result = replacing(
                #"\b(at|around|by|from|until|till)\s+\#(word)\b"#,
                in: result,
                with: "$1 \(value)"
            )
            result = replacing(
                #"\b\#(word)\s+(o'clock|oclock|thirty|fifteen|am|pm)\b"#,
                in: result,
                with: "\(value) $1"
            )
        }
        result = replacing(#"\b(\d{1,2})\s+thirty\b"#, in: result, with: "$1:30")
        result = replacing(#"\b(\d{1,2})\s+fifteen\b"#, in: result, with: "$1:15")
        return result
    }

    private static func replacing(_ pattern: String, in text: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        else { return text }
        return regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: template
        )
    }

    /// "At six" means six in the evening far more often than six in the
    /// morning, and NSDataDetector reads a bare number as AM. Only shifted when
    /// the wearer did not actually say "am" or "morning", and the spoken
    /// confirmation always reads the resolved time back so a wrong guess is
    /// caught immediately.
    private static func correctingMorning(_ date: Date, spokenAs phrase: String, now: Date) -> Date {
        let calendar = Calendar.current
        let lowered = phrase.lowercased()
        let saidMorning = ["am", "a.m", "morning", "midnight", "noon"].contains { lowered.contains($0) }

        var corrected = date
        let hour = calendar.component(.hour, from: date)
        if !saidMorning, (1...7).contains(hour) {
            corrected = calendar.date(byAdding: .hour, value: 12, to: date) ?? date
        }

        // A time that has already gone by today means the next one.
        if corrected < now, calendar.isDate(corrected, inSameDayAs: now) {
            corrected = calendar.date(byAdding: .day, value: 1, to: corrected) ?? corrected
        }
        return corrected
    }

    // MARK: - Titles

    /// Everything up to and including the trigger word is instruction, not
    /// title. Stripping only leading filler is not enough — "Can you remind me
    /// to take the bins out" stops dead on "Can".
    private static func title(from remainder: String) -> String {
        var words = tokensPreservingCase(in: remainder)

        if let triggerIndex = words.prefix(triggerWindow).lastIndex(where: {
            triggerWords.contains(normalized($0))
        }) {
            words.removeFirst(triggerIndex + 1)
        }

        while let first = words.first, leadingFiller.contains(normalized(first)) {
            words.removeFirst()
        }
        while let last = words.last, trailingFiller.contains(normalized(last)) {
            words.removeLast()
        }

        return capitalizedFirst(words.joined(separator: " "))
    }

    /// Lowercased for matching. Apostrophes go too, so "what's" and "whats" are
    /// the same word — dictation produces both.
    private static func normalized(_ word: String) -> String {
        word.lowercased()
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")
    }

    private static func tokens(in text: String) -> [String] {
        tokensPreservingCase(in: text).map(normalized)
    }

    private static func tokensPreservingCase(in text: String) -> [String] {
        text
            .components(separatedBy: CharacterSet(charactersIn: " \t\n,.;:!?—"))
            .filter { !$0.isEmpty }
    }

    /// Same rule as the memory trigger: leave "iPhone" and "eBay" alone.
    private static func capitalizedFirst(_ value: String) -> String {
        let characters = Array(value)
        guard let first = characters.first, first.isLowercase else { return value }
        if characters.count > 1, characters[1].isUppercase { return value }
        return first.uppercased() + String(characters.dropFirst())
    }
}
