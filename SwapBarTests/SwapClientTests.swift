import Testing
import Foundation
@testable import SwapBar

// MARK: - URLProtocol stub

/// Stubs plain request/response HTTP calls by path. Simpler than `SSEStubProtocol` —
/// `URLSession.data(for:)` awaits full completion before returning, so there's no
/// streaming/`AsyncBytes` race to worry about here.
final class HTTPStubProtocol: URLProtocol, @unchecked Sendable {
    struct Stub {
        var statusCode: Int
    }

    nonisolated(unsafe) private static var stubsByPath: [String: Stub] = [:]
    nonisolated(unsafe) static private(set) var requestedPaths: [String] = []
    nonisolated(unsafe) static private(set) var requestedMethods: [String] = []

    static func stub(path: String, statusCode: Int) {
        stubsByPath[path] = Stub(statusCode: statusCode)
    }

    static func reset() {
        stubsByPath.removeAll()
        requestedPaths.removeAll()
        requestedMethods.removeAll()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        Self.requestedPaths.append(path)
        Self.requestedMethods.append(request.httpMethod ?? "")
        guard let url = request.url, let stub = Self.stubsByPath[path] else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: stub.statusCode, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func stubbedSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [HTTPStubProtocol.self]
    return URLSession(configuration: config)
}

// MARK: - Tests

// .serialized — all tests share HTTPStubProtocol's static stub state, which races
// under Swift Testing's default parallel execution within a suite.
@Suite("SwapClient — actions", .serialized)
@MainActor
struct SwapClientTests {

    @Test("unload posts to /api/models/unload/:model_id")
    func unloadPostsToCorrectPath() async throws {
        HTTPStubProtocol.reset()
        HTTPStubProtocol.stub(path: "/api/models/unload/coder-flash", statusCode: 200)

        let client = SwapClient(
            name: "test",
            baseURL: URL(string: "https://stub.invalid")!,
            session: stubbedSession()
        )
        try await client.unload(modelID: "coder-flash")

        #expect(HTTPStubProtocol.requestedPaths == ["/api/models/unload/coder-flash"])
        #expect(HTTPStubProtocol.requestedMethods == ["POST"])
    }

    @Test("unloadAll posts to /api/models/unload")
    func unloadAllPostsToCorrectPath() async throws {
        HTTPStubProtocol.reset()
        HTTPStubProtocol.stub(path: "/api/models/unload", statusCode: 200)

        let client = SwapClient(
            name: "test",
            baseURL: URL(string: "https://stub.invalid")!,
            session: stubbedSession()
        )
        try await client.unloadAll()

        #expect(HTTPStubProtocol.requestedPaths == ["/api/models/unload"])
        #expect(HTTPStubProtocol.requestedMethods == ["POST"])
    }

    @Test("load hits GET /upstream/:model_id/health")
    func loadHitsUpstreamHealth() async throws {
        HTTPStubProtocol.reset()
        HTTPStubProtocol.stub(path: "/upstream/embed/health", statusCode: 200)

        let client = SwapClient(
            name: "test",
            baseURL: URL(string: "https://stub.invalid")!,
            session: stubbedSession()
        )
        try await client.load(modelID: "embed")

        #expect(HTTPStubProtocol.requestedPaths == ["/upstream/embed/health"])
        #expect(HTTPStubProtocol.requestedMethods == ["GET"])
    }

    @Test("toggleLoad unloads a ready model")
    func toggleLoadUnloadsWhenReady() async throws {
        HTTPStubProtocol.reset()
        HTTPStubProtocol.stub(path: "/api/models/unload/embed", statusCode: 200)

        let client = SwapClient(
            name: "test",
            baseURL: URL(string: "https://stub.invalid")!,
            session: stubbedSession()
        )
        let model = ModelStatus(id: "embed", name: "", description: "", state: "ready", unlisted: false, peerID: "", aliases: nil)
        try await client.toggleLoad(for: model)

        #expect(HTTPStubProtocol.requestedPaths == ["/api/models/unload/embed"])
    }

    @Test("toggleLoad loads a non-ready model")
    func toggleLoadLoadsWhenNotReady() async throws {
        HTTPStubProtocol.reset()
        HTTPStubProtocol.stub(path: "/upstream/embed/health", statusCode: 200)

        let client = SwapClient(
            name: "test",
            baseURL: URL(string: "https://stub.invalid")!,
            session: stubbedSession()
        )
        let model = ModelStatus(id: "embed", name: "", description: "", state: "stopped", unlisted: false, peerID: "", aliases: nil)
        try await client.toggleLoad(for: model)

        #expect(HTTPStubProtocol.requestedPaths == ["/upstream/embed/health"])
    }

    @Test("model ID with a slash (e.g. author/model) is preserved in the path")
    func modelIDWithSlashIsPreserved() async throws {
        HTTPStubProtocol.reset()
        HTTPStubProtocol.stub(path: "/api/models/unload/author/model", statusCode: 200)

        let client = SwapClient(
            name: "test",
            baseURL: URL(string: "https://stub.invalid")!,
            session: stubbedSession()
        )
        try await client.unload(modelID: "author/model")

        #expect(HTTPStubProtocol.requestedPaths == ["/api/models/unload/author/model"])
    }

    @Test("non-2xx response throws requestFailed with the status code")
    func nonSuccessStatusThrows() async throws {
        HTTPStubProtocol.reset()
        HTTPStubProtocol.stub(path: "/api/models/unload/missing", statusCode: 404)

        let client = SwapClient(
            name: "test",
            baseURL: URL(string: "https://stub.invalid")!,
            session: stubbedSession()
        )

        do {
            try await client.unload(modelID: "missing")
            Issue.record("expected requestFailed to be thrown")
        } catch SwapClientError.requestFailed(let statusCode) {
            #expect(statusCode == 404)
        } catch {
            Issue.record("expected SwapClientError.requestFailed, got \(error)")
        }
    }
}
