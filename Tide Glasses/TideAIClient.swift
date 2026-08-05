//
//  TideAIClient.swift
//  Tide Glasses
//
//  Talks to the `tide-vision` edge function, which holds the OpenRouter key so
//  the app never has to. The reply arrives as an SSE stream and is yielded a
//  chunk at a time, so the UI can start showing the answer while the model is
//  still writing it — and so the spoken path can start talking early later on.
//
//  This uses a plain URLSession on purpose. The raw-socket NWConnection code in
//  the transfer manager exists only because the glasses hotspot has no route to
//  the internet; this request goes out over normal Wi-Fi or cellular.
//

import Foundation
import UIKit

struct TideAITurn {
    let role: String       // "user" | "assistant"
    let content: String
}

enum TideAIError: LocalizedError {
    case notConfigured
    case unauthorized
    case server(Int, String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "The AI key is missing. Add it to TideSecrets.swift."
        case .unauthorized:
            "The glasses key was rejected. It may have been rotated on the server."
        case .server(let code, let message):
            message.isEmpty ? "The AI service returned an error (\(code))." : message
        }
    }
}

struct TideAIClient {
    private static let endpoint = URL(
        string: "https://zwxmmkiwvhsjdztenwfy.supabase.co/functions/v1/tide-vision"
    )!

    /// The function rejects anything over 400 KB decoded; stay clear of the edge.
    private static let imageByteBudget = 360_000

    /// Streams the answer. Each yielded value is a fragment to append.
    ///
    /// `memory` is the wearer's own block of facts. It goes out with every
    /// request rather than being asked for, because the questions where it
    /// matters most — "is this safe for me to eat" — are exactly the ones where
    /// nobody remembers to ask for it.
    func stream(
        question: String,
        image: UIImage?,
        history: [TideAITurn],
        memory: String? = nil
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let work = Task {
                do {
                    let request = try Self.makeRequest(
                        question: question,
                        image: image,
                        history: history,
                        memory: memory
                    )
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0

                    guard status == 200 else {
                        // The error body is JSON, not SSE, so read it whole.
                        var raw = ""
                        for try await line in bytes.lines { raw += line }
                        throw status == 401
                            ? TideAIError.unauthorized
                            : TideAIError.server(status, Self.message(fromErrorBody: raw))
                    }

                    for try await line in bytes.lines {
                        // Lines beginning with ':' are keep-alive comments
                        // (OpenRouter sends ": OPENROUTER PROCESSING").
                        guard line.hasPrefix("data:") else { continue }

                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }

                        if let fragment = Self.content(fromChunk: payload), !fragment.isEmpty {
                            continuation.yield(fragment)
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in work.cancel() }
        }
    }

    // MARK: - Request

    private static func makeRequest(
        question: String,
        image: UIImage?,
        history: [TideAITurn],
        memory: String?
    ) throws -> URLRequest {
        let key = TideSecrets.deviceKey
        guard !key.isEmpty else { throw TideAIError.notConfigured }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(key, forHTTPHeaderField: "x-tide-key")
        request.timeoutInterval = 60

        var body: [String: Any] = ["question": question]
        if let image, let jpeg = compressed(image) {
            body["imageBase64"] = jpeg.base64EncodedString()
        }
        if !history.isEmpty {
            body["history"] = history.map { ["role": $0.role, "content": $0.content] }
        }
        if let memory, !memory.isEmpty {
            body["memory"] = memory
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Shrinks a photo until it fits the function's size cap. A full-resolution
    /// glasses photo is far larger than a vision model needs.
    private static func compressed(_ image: UIImage) -> Data? {
        for maxDimension in [1024.0, 768.0, 512.0, 384.0] as [CGFloat] {
            guard let resized = image.tide_resized(maxDimension: maxDimension) else { continue }
            for quality in [0.6, 0.45, 0.3] as [CGFloat] {
                guard let data = resized.jpegData(compressionQuality: quality) else { continue }
                if data.count <= imageByteBudget { return data }
            }
        }
        return nil
    }

    // MARK: - Response parsing

    /// Pulls `choices[0].delta.content` out of one SSE chunk.
    private static func content(fromChunk chunk: String) -> String? {
        guard let data = chunk.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let delta = choices.first?["delta"] as? [String: Any] else { return nil }
        return delta["content"] as? String
    }

    /// The function reports failures as `{ "error": "..." }`.
    private static func message(fromErrorBody body: String) -> String {
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = object["error"] as? String else { return body }
        return message
    }

    /// Turns any thrown error into something worth showing a person.
    static func describe(_ error: Error) -> String {
        if let aiError = error as? TideAIError {
            return aiError.localizedDescription
        }
        guard let urlError = error as? URLError else { return error.localizedDescription }
        return switch urlError.code {
        case .notConnectedToInternet, .dataNotAllowed:
            "No internet connection."
        case .timedOut:
            "The AI took too long to answer. Try again."
        case .networkConnectionLost:
            "The connection dropped mid-answer."
        case .cannotFindHost, .cannotConnectToHost:
            "Could not reach the AI service."
        default:
            urlError.localizedDescription
        }
    }
}

extension UIImage {
    /// Aspect-preserving resize; returns self when already small enough.
    func tide_resized(maxDimension: CGFloat) -> UIImage? {
        let longest = max(size.width, size.height)
        guard longest > maxDimension, longest > 0 else { return self }

        let scale = maxDimension / longest
        let target = CGSize(width: size.width * scale, height: size.height * scale)

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
