//
//  TideActions.swift
//  Tide Glasses
//
//  Runs calendar and reminder actions through EventKit, on this phone.
//
//  Nothing in this file talks to the network. A spoken "remind me to call Mom
//  tomorrow at six" is parsed locally, written to the local store, and read
//  back — the words never reach the AI service, and neither does anything
//  already in the wearer's calendar.
//
//  Confirmations are written to be *heard*, not read: one short sentence, the
//  resolved time always spoken back so a misheard hour is caught immediately
//  rather than discovered at six in the morning.
//

import Combine
import EventKit
import Foundation

struct TideActionOutcome {
    let spoken: String
    let succeeded: Bool
    /// Nil for look-ups, which are not worth keeping in the history.
    let record: TideActionRecord?
}

@MainActor
final class TideActionRunner: ObservableObject {
    private let store = EKEventStore()

    @Published private(set) var calendarStatus = EKEventStore.authorizationStatus(for: .event)
    @Published private(set) var reminderStatus = EKEventStore.authorizationStatus(for: .reminder)

    var hasCalendarAccess: Bool { calendarStatus == .fullAccess }
    var hasReminderAccess: Bool { reminderStatus == .fullAccess }

    // MARK: - Permissions

    /// Asked for from the Actions tab, in the foreground. A voice action that
    /// arrives before this has been granted says so out loud instead of
    /// silently failing — the system prompt cannot appear on a locked phone.
    func requestCalendarAccess() async {
        _ = try? await store.requestFullAccessToEvents()
        refreshStatuses()
    }

    func requestReminderAccess() async {
        _ = try? await store.requestFullAccessToReminders()
        refreshStatuses()
    }

    func refreshStatuses() {
        calendarStatus = EKEventStore.authorizationStatus(for: .event)
        reminderStatus = EKEventStore.authorizationStatus(for: .reminder)
    }

    // MARK: - Running

    func perform(_ action: TideAction) async -> TideActionOutcome {
        switch action {
        case .createReminder(let title, let due):
            await createReminder(title: title, due: due)
        case .listReminders:
            await listReminders()
        case .createEvent(let title, let start, let duration):
            createEvent(title: title, start: start, duration: duration)
        case .listEvents(let day):
            listEvents(on: day)
        }
    }

    // MARK: - Reminders

    private func createReminder(title: String, due: Date?) async -> TideActionOutcome {
        guard hasReminderAccess else { return denied(.reminder) }
        guard let list = store.defaultCalendarForNewReminders() else {
            return failure("I could not find a reminders list to add that to.")
        }

        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.calendar = list

        if let due {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: due
            )
            // A due date alone shows in the list but never speaks up. The alarm
            // is what makes "remind me" actually remind anyone.
            reminder.addAlarm(EKAlarm(absoluteDate: due))
        }

        do {
            try store.save(reminder, commit: true)
        } catch {
            return failure("That reminder could not be saved.")
        }

        let when = due.map { ", \(Self.spoken($0))" } ?? ""
        return TideActionOutcome(
            spoken: "Reminder set: \(title)\(when).",
            succeeded: true,
            record: TideActionRecord(kind: .reminder, title: title, date: due)
        )
    }

    private func listReminders() async -> TideActionOutcome {
        guard hasReminderAccess else { return denied(.reminder) }

        let predicate = store.predicateForIncompleteReminders(
            withDueDateStarting: nil,
            ending: nil,
            calendars: nil
        )
        let reminders: [EKReminder] = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { found in
                continuation.resume(returning: found ?? [])
            }
        }

        guard !reminders.isEmpty else {
            return TideActionOutcome(spoken: "You have no reminders.", succeeded: true, record: nil)
        }

        let titles = reminders.compactMap { $0.title }.filter { !$0.isEmpty }
        return TideActionOutcome(
            spoken: "\(count(titles.count, "reminder")): \(Self.list(titles)).",
            succeeded: true,
            record: nil
        )
    }

    // MARK: - Calendar

    private func createEvent(title: String, start: Date, duration: TimeInterval) -> TideActionOutcome {
        guard hasCalendarAccess else { return denied(.event) }
        guard let calendar = store.defaultCalendarForNewEvents else {
            return failure("I could not find a calendar to add that to.")
        }

        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = start
        event.endDate = start.addingTimeInterval(duration)
        event.calendar = calendar

        do {
            try store.save(event, span: .thisEvent, commit: true)
        } catch {
            return failure("That event could not be saved.")
        }

        return TideActionOutcome(
            spoken: "Added \(title) to your calendar, \(Self.spoken(start)).",
            succeeded: true,
            record: TideActionRecord(kind: .event, title: title, date: start)
        )
    }

    private func listEvents(on day: Date) -> TideActionOutcome {
        guard hasCalendarAccess else { return denied(.event) }

        let calendar = Calendar.current
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else {
            return failure("I could not work out which day you meant.")
        }

        let events = store
            .events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
            .sorted { $0.startDate < $1.startDate }

        let dayName = Self.spokenDay(start)
        guard !events.isEmpty else {
            return TideActionOutcome(
                spoken: "Nothing on your calendar \(dayName).",
                succeeded: true,
                record: nil
            )
        }

        let described = events.prefix(4).map { event -> String in
            let title = (event.title?.isEmpty == false) ? event.title! : "an event"
            return event.isAllDay ? title : "\(title) at \(Self.spokenTime(event.startDate))"
        }
        let extra = events.count > described.count ? ", and \(events.count - described.count) more" : ""

        return TideActionOutcome(
            spoken: "\(count(events.count, "thing")) \(dayName): \(Self.list(Array(described)))\(extra).",
            succeeded: true,
            record: nil
        )
    }

    // MARK: - Failures

    private func denied(_ type: EKEntityType) -> TideActionOutcome {
        let what = type == .reminder ? "reminders" : "calendar"
        return TideActionOutcome(
            spoken: "I do not have access to your \(what) yet. Open the Actions tab to allow it.",
            succeeded: false,
            record: nil
        )
    }

    private func failure(_ message: String) -> TideActionOutcome {
        TideActionOutcome(spoken: message, succeeded: false, record: nil)
    }

    private func count(_ number: Int, _ noun: String) -> String {
        "You have \(number) \(noun)\(number == 1 ? "" : "s")"
    }

    // MARK: - Saying dates out loud

    /// "tomorrow at 6 PM" rather than "06/08/2026, 18:00" — this is read aloud.
    static func spoken(_ date: Date) -> String {
        let time = spokenTime(date)
        let day = spokenDay(date)
        return "\(day) at \(time)"
    }

    static func spokenDay(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "today" }
        if calendar.isDateInTomorrow(date) { return "tomorrow" }
        if calendar.isDateInYesterday(date) { return "yesterday" }

        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: Date()),
            to: calendar.startOfDay(for: date)
        ).day ?? 0

        // Inside a week a weekday is unambiguous and shorter to hear.
        if (0...6).contains(days) {
            return "on \(date.formatted(.dateTime.weekday(.wide)))"
        }
        return "on \(date.formatted(.dateTime.month(.wide).day()))"
    }

    static func spokenTime(_ date: Date) -> String {
        let minute = Calendar.current.component(.minute, from: date)
        return minute == 0
            ? date.formatted(.dateTime.hour(.defaultDigits(amPM: .abbreviated)))
            : date.formatted(.dateTime.hour(.defaultDigits(amPM: .abbreviated)).minute())
    }

    /// "a, b, and c" — spoken lists need the conjunction or they run together.
    static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: ""
        case 1: items[0]
        case 2: "\(items[0]) and \(items[1])"
        default: "\(items.dropLast().joined(separator: ", ")), and \(items.last!)"
        }
    }
}
