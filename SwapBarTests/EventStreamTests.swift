import Testing
import Foundation
@testable import SwapBar

// MARK: - URLProtocol stub

/// Feeds canned SSE byte chunks to whatever `URLSession` is configured with it, in the
/// order enqueued. Single global queue — tests `reset()` it and only ever drive one
/// connection at a time, so no locking is needed for this test-only stub.
final class SSEStubProtocol: URLProtocol, @unchecked Sendable {
    struct Script {
        var chunks: [Data] = []
        var endsWithError: Bool = false
    }

    nonisolated(unsafe) private static var scripts: [Script] = []

    static func enqueue(_ script: Script) {
        scripts.append(script)
    }

    static func reset() {
        scripts.removeAll()
    }

    private static func dequeue() -> Script? {
        scripts.isEmpty ? nil : scripts.removeFirst()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let script = Self.dequeue() else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        let client = self.client
        // Deliver callbacks with a tiny real gap between them. Firing them all
        // synchronously races the AsyncBytes consumer — a terminal error signaled in
        // the same tick as a preceding data chunk can be observed before the data is.
        Task {
            let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            try? await Task.sleep(nanoseconds: 1_000_000)
            for chunk in script.chunks {
                client?.urlProtocol(self, didLoad: chunk)
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
            if script.endsWithError {
                client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            } else {
                client?.urlProtocolDidFinishLoading(self)
            }
        }
    }

    override func stopLoading() {}
}

private func stubbedSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [SSEStubProtocol.self]
    return URLSession(configuration: config)
}

/// Builds one raw SSE frame ("event:message\ndata:{...}\n\n") the same way llama-swap does —
/// double-encoded JSON via the real `SSEFrame` type, so fixtures stay in sync with production decoding.
private func sseFrameBytes(type: String, innerJSON: String) -> Data {
    let outer = SSEFrame(type: type, data: innerJSON)
    let outerData = try! JSONEncoder().encode(outer)
    let text = "event:message\ndata:" + String(data: outerData, encoding: .utf8)! + "\n\n"
    return Data(text.utf8)
}

private let inflightEmptySnapshotInnerJSON = #"{"operation":"snapshot"}"#

// MARK: - Tests

// .serialized — reconnectsAfterDrop() uses SSEStubProtocol's static stub queue, which
// would race against other tests in this suite under Swift Testing's default parallelism.
@Suite("EventStream — SSE parsing & reconnect", .serialized)
struct EventStreamTests {

    // MARK: Pure parsing (no networking)

    @Test("parses modelStatus frame")
    func parsesModelStatus() {
        let raw = #"{"type":"modelStatus","data":"[{\"id\":\"embed\",\"name\":\"\",\"description\":\"\",\"state\":\"ready\",\"unlisted\":false,\"peerID\":\"\"}]"}"#
        guard case .modelStatusReceived(let models) = SSESource.parseFrame(raw) else {
            Issue.record("expected modelStatusReceived")
            return
        }
        #expect(models.count == 1)
        #expect(models[0].id == "embed")
    }

    @Test("parses inflight upsert (start) frame")
    func parsesInflightUpsert() {
        let inner = #"{"operation":"upsert","request":{"id":"41","timestamp":"t","model":"m","req_path":"/v1","method":"POST","req_headers":{},"remote_ip":"127.0.0.1","resp_headers":{},"resp_bytes":0,"elapsed_ms":0}}"#
        let escaped = inner.replacingOccurrences(of: "\"", with: "\\\"")
        let raw = "{\"type\":\"inflight\",\"data\":\"\(escaped)\"}"
        guard case .inflightReceived(.upsert(let req)) = SSESource.parseFrame(raw) else {
            Issue.record("expected inflight upsert")
            return
        }
        #expect(req.id == "41")
        #expect(req.isStart)
    }

    @Test("parses inflight snapshot with absent requests key as empty")
    func parsesEmptyInflightSnapshot() {
        let escaped = inflightEmptySnapshotInnerJSON.replacingOccurrences(of: "\"", with: "\\\"")
        let raw = "{\"type\":\"inflight\",\"data\":\"\(escaped)\"}"
        guard case .inflightReceived(.snapshot(let requests)) = SSESource.parseFrame(raw) else {
            Issue.record("expected inflight snapshot")
            return
        }
        #expect(requests.isEmpty)
    }

    @Test("ignores unhandled event types")
    func ignoresUnhandledTypes() {
        let raw = #"{"type":"logData","data":"{}"}"#
        #expect(SSESource.parseFrame(raw) == nil)
    }

    @Test("returns nil on malformed outer JSON")
    func malformedOuterJSONReturnsNil() {
        #expect(SSESource.parseFrame("not json") == nil)
    }

    // MARK: Backoff (pure)

    @Test("backoff escalates 1s, 2s, 4s, 8s, 16s, then caps at 30s")
    func backoffEscalatesThenCaps() {
        let expected: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16), .seconds(30)]
        for (attempt, expectedDelay) in expected.enumerated() {
            #expect(BackoffPolicy.delay(forAttempt: attempt) == expectedDelay)
        }
        // Beyond the table, stays capped at 30s.
        #expect(BackoffPolicy.delay(forAttempt: 99) == .seconds(30))
    }

    // MARK: Reconnect attempt bookkeeping (pure — no networking needed for the reset semantic)

    @Test("reconnect attempt counter escalates, then resets on a successful connect")
    func reconnectAttemptCounterResets() {
        var counter = ReconnectAttemptCounter()
        #expect(counter.nextDelay() == .seconds(1))
        #expect(counter.nextDelay() == .seconds(2))
        counter.reset()
        #expect(counter.nextDelay() == .seconds(1))
        #expect(counter.nextDelay() == .seconds(2))
    }

    // MARK: Reconnect (URLProtocol stub) — proves the loop actually reconnects on drop.

    @Test("drop triggers .disconnected, then a fresh connection reconnects and delivers data", .timeLimit(.minutes(1)))
    func reconnectsAfterDrop() async throws {
        SSEStubProtocol.reset()
        // First connection: connects, then drops with no data — a bare connection loss.
        // (A transport error surfacing mid-stream can race delivery of already-buffered
        // data in the URLProtocol/AsyncBytes bridge, so this scenario intentionally
        // carries no payload — parsing-before-drop is covered by the clean-close case below.)
        SSEStubProtocol.enqueue(.init(endsWithError: true))
        // Second connection: connects, delivers a frame, then closes cleanly — proving
        // the reconnect isn't just a fresh TCP handshake but a fully working stream again.
        SSEStubProtocol.enqueue(.init(
            chunks: [sseFrameBytes(type: "inflight", innerJSON: inflightEmptySnapshotInnerJSON)],
            endsWithError: false
        ))

        let source = SSESource(
            url: URL(string: "https://stub.invalid/api/events")!,
            session: stubbedSession(),
            sleep: { _ in }   // no real delay — this test asserts sequence, not timing
        )

        var collected: [SwapStateEvent] = []
        let stream = await source.events()
        for await event in stream {
            collected.append(event)
            if collected.count == 4 { break }
        }

        // connected → disconnected (drop) → connected (reconnect) → inflight snapshot
        #expect(collected.count == 4)
        guard case .connected = collected[0] else { Issue.record("expected .connected, got \(collected[0])"); return }
        guard case .disconnected = collected[1] else { Issue.record("expected .disconnected (drop), got \(collected[1])"); return }
        guard case .connected = collected[2] else { Issue.record("expected reconnect .connected, got \(collected[2])"); return }
        guard case .inflightReceived(.snapshot(let requests)) = collected[3] else {
            Issue.record("expected inflight snapshot after reconnect, got \(collected[3])")
            return
        }
        #expect(requests.isEmpty)
    }
}
