import Foundation

// MARK: - EventSource Protocol

/// Abstraction over "a live source of `SwapStateEvent`s." `SSESource` (below) is the
/// primary implementation (§0 — SSE is real and stable against a live instance).
/// A `PollingSource` fallback conformance is deferred: §0 notes SSE is no longer the
/// thing blocking v1, so it isn't built until something actually needs it.
protocol EventSource: Sendable {
    /// Never completes on its own — reconnect/backoff happens internally.
    /// The stream only finishes once its consumer stops iterating (cancelling the
    /// underlying reconnect loop). `async` so actor conformances (like `SSESource`) don't
    /// create an isolation mismatch — without this, calling `.events()` through the `any
    /// EventSource` existential silently skipped the actor hop instead of erroring, which
    /// the compiler flags as a genuine potential data race.
    func events() async -> AsyncStream<SwapStateEvent>
}

// MARK: - Backoff

/// Exponential backoff: 1s, 2s, 4s, 8s, 16s, capped at 30s (§4). Reset on successful connect.
enum BackoffPolicy {
    nonisolated static let steps: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16), .seconds(30)]

    nonisolated static func delay(forAttempt attempt: Int) -> Duration {
        steps[min(attempt, steps.count - 1)]
    }
}

enum EventStreamError: Error, Sendable {
    case badResponse
    case streamEnded
}

/// Tracks the reconnect attempt count driving `BackoffPolicy`. Pulled out as its own pure
/// type — independent of networking — so "reset on successful connect" (§4) is unit-testable
/// directly, without needing a real or stubbed connection to exercise the timing.
nonisolated struct ReconnectAttemptCounter: Sendable {
    private(set) var attempt = 0

    mutating func nextDelay() -> Duration {
        defer { attempt += 1 }
        return BackoffPolicy.delay(forAttempt: attempt)
    }

    mutating func reset() {
        attempt = 0
    }
}

// MARK: - SSESource

/// Consumes `GET /api/events` (§0) and republishes parsed frames as `SwapStateEvent`s.
/// Reconnects with backoff on any drop — a clean server close and a transport error
/// are both just "the stream isn't there anymore."
actor SSESource: EventSource {
    private let url: URL
    private let session: URLSession
    private let sleep: @Sendable (Duration) async throws -> Void

    /// `URLSession.shared`'s default `timeoutIntervalForRequest` is 60s — fatal for a
    /// connection that's deliberately held open indefinitely. Without this, a perfectly
    /// healthy SSE stream gets killed and reconnected once a minute forever.
    nonisolated static func makeDefaultSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 24 * 60 * 60
        return URLSession(configuration: config)
    }

    init(
        url: URL,
        session: URLSession? = nil,
        sleep: @Sendable @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.url = url
        self.session = session ?? Self.makeDefaultSession()
        self.sleep = sleep
    }

    func events() async -> AsyncStream<SwapStateEvent> {
        AsyncStream { continuation in
            let task = Task {
                var counter = ReconnectAttemptCounter()
                while !Task.isCancelled {
                    do {
                        try await self.connectOnce(continuation: continuation, onConnected: { counter.reset() })
                    } catch {
                        guard !Task.isCancelled else { break }
                        continuation.yield(.disconnected(at: Date()))
                        try? await self.sleep(counter.nextDelay())
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Opens one connection and reads it until it drops. Always throws when it returns —
    /// a still-open SSE stream never returns normally, so returning at all means a drop.
    private func connectOnce(
        continuation: AsyncStream<SwapStateEvent>.Continuation,
        onConnected: () -> Void
    ) async throws {
        var request = URLRequest(url: url)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw EventStreamError.badResponse
        }

        onConnected()
        continuation.yield(.connected)

        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }   // ignore "event:" lines and blank separators
            let jsonString = String(line.dropFirst(5))
            if let event = Self.parseFrame(jsonString) {
                continuation.yield(event)
            }
        }
        throw EventStreamError.streamEnded   // server closed the connection cleanly — still a drop
    }

    /// Decodes one outer SSE frame. `.data` is itself a JSON-encoded string (§0) — double-decode.
    /// Only `modelStatus` and `inflight` map to a `SwapStateEvent`; `uiConfig`/`profileChanged`/`logData`
    /// are out of scope for the state machine in v1 and are dropped here.
    nonisolated static func parseFrame(_ jsonString: String) -> SwapStateEvent? {
        guard let outerData = jsonString.data(using: .utf8),
              let frame = try? JSONDecoder().decode(SSEFrame.self, from: outerData),
              let innerData = frame.data.data(using: .utf8)
        else { return nil }

        switch frame.type {
        case "modelStatus":
            guard let models = try? JSONDecoder().decode([ModelStatus].self, from: innerData) else { return nil }
            return .modelStatusReceived(models)
        case "inflight":
            guard let payload = try? JSONDecoder().decode(InflightPayload.self, from: innerData),
                  let event = InflightEvent(payload: payload)
            else { return nil }
            return .inflightReceived(event)
        default:
            return nil
        }
    }
}
