import Foundation

enum SwapClientError: Error, Sendable {
    case requestFailed(statusCode: Int)
}

/// Owns one llama-swap instance: wires an `EventSource` into a `StateMachine` and exposes
/// the instance's quick actions (§6). Multi-instance support falls out of the app holding
/// an array of these — nothing here assumes it's the only instance.
@MainActor
final class SwapClient {
    let name: String
    let baseURL: URL

    let stateMachine: StateMachine

    /// llama-swap's own web UI (§0.5: `GET /ui`).
    var webUIURL: URL { baseURL.appendingPathComponent("ui") }

    /// "host:port" for the dropdown header (§6), e.g. "localhost:8090".
    var displayAddress: String {
        guard let host = baseURL.host else { return baseURL.absoluteString }
        guard let port = baseURL.port else { return host }
        return "\(host):\(port)"
    }

    private let eventSource: any EventSource
    private let session: URLSession
    private var consumeTask: Task<Void, Never>?

    init(
        name: String,
        baseURL: URL,
        eventSource: (any EventSource)? = nil,
        session: URLSession = .shared
    ) {
        self.name = name
        self.baseURL = baseURL
        self.session = session
        self.stateMachine = StateMachine()
        self.eventSource = eventSource ?? SSESource(url: baseURL.appendingPathComponent("api/events"))
    }

    /// Starts consuming events into the state machine. Idempotent — call once per instance.
    func start() {
        guard consumeTask == nil else { return }
        consumeTask = Task { [eventSource, stateMachine] in
            let stream = await eventSource.events()
            for await event in stream {
                stateMachine.handle(event)
            }
        }
    }

    func stop() {
        consumeTask?.cancel()
        consumeTask = nil
    }

    // MARK: - Actions (§0.5, §6)

    func unload(modelID: String) async throws {
        try await post(path: "api/models/unload/\(modelID)")
    }

    func unloadAll() async throws {
        try await post(path: "api/models/unload")
    }

    /// llama-swap has no dedicated "load" endpoint (§0.5, verified live) — models load
    /// lazily on first request, same as a real inference call. Hitting the model's own
    /// upstream `/health` triggers that on-demand load without needing a model-type-specific
    /// payload (chat vs. embeddings vs. completion all differ; health doesn't).
    func load(modelID: String) async throws {
        try await get(path: "upstream/\(modelID)/health")
    }

    /// Convenience for the dropdown row tap (§6): unload if ready, load otherwise.
    func toggleLoad(for model: ModelStatus) async throws {
        if model.state == "ready" {
            try await unload(modelID: model.id)
        } else {
            try await load(modelID: model.id)
        }
    }

    private func post(path: String) async throws {
        try await request(path: path, method: "POST")
    }

    private func get(path: String) async throws {
        try await request(path: path, method: "GET")
    }

    private func request(path: String, method: String) async throws {
        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw SwapClientError.requestFailed(statusCode: code)
        }
    }
}
