import Foundation

// MARK: - API DTOs

/// One entry in a modelStatus event array.
nonisolated struct ModelStatus: Codable, Sendable, Equatable {
    let id: String
    let name: String
    let description: String
    let state: String           // "stopped" | "ready" | anything future
    let unlisted: Bool
    let peerID: String
    let aliases: [String]?
}

/// Shape of one in-flight request across upsert/snapshot payloads.
nonisolated struct InFlightRequest: Codable, Sendable, Equatable {
    let id: String
    let timestamp: String
    let model: String
    let reqPath: String
    let method: String
    let reqHeaders: [String: String]
    let remoteIP: String
    let respHeaders: [String: String]
    let respBytes: Int
    let elapsedMs: Int

    // upsert is overloaded for start AND completion events.
    // Disambiguate: elapsed_ms == 0 AND resp_headers empty → this is a start event (t=0 for the ramp).
    // Any other upsert (elapsed_ms > 0) is the completion — final timing, no longer drives animation.
    var isStart: Bool { elapsedMs == 0 && respHeaders.isEmpty }

    enum CodingKeys: String, CodingKey {
        case id, timestamp, model, method
        case reqPath    = "req_path"
        case reqHeaders = "req_headers"
        case remoteIP   = "remote_ip"
        case respHeaders = "resp_headers"
        case respBytes  = "resp_bytes"
        case elapsedMs  = "elapsed_ms"
    }
}

// MARK: - SSE Outer Frame

/// Outer envelope of every SSE frame. `.data` is itself a JSON-encoded string.
nonisolated struct SSEFrame: Codable, Sendable {
    let type: String
    let data: String
}

// MARK: - Parsed Inflight Events

nonisolated enum InflightEvent: Sendable, Equatable {
    case upsert(InFlightRequest)
    case snapshot([InFlightRequest])
    case remove(id: String)
}

// MARK: - Domain Model

nonisolated struct LoadedModel: Equatable, Sendable, Hashable {
    let id: String
    let name: String
    let description: String
    let aliases: [String]

    init(_ status: ModelStatus) {
        self.id          = status.id
        self.name        = status.name.isEmpty ? status.id : status.name
        self.description = status.description
        self.aliases     = status.aliases ?? []
    }

    // Memberwise init for tests.
    init(id: String, name: String = "", description: String = "", aliases: [String] = []) {
        self.id          = id
        self.name        = name.isEmpty ? id : name
        self.description = description
        self.aliases     = aliases
    }
}

// MARK: - Running Model (from GET /running)

nonisolated struct RunningModel: Codable, Sendable {
    let model: String
    let state: String
    let cmd: String     // full command line; -m flag contains model path for PID correlation
    let proxy: String
    let ttl: Int
    let name: String
    let description: String
}

nonisolated struct RunningResponse: Codable, Sendable {
    let running: [RunningModel]
}

// MARK: - Inflight Decoding Helpers (internal)

/// Intermediate for decoding inflight JSON before dispatching on `operation`.
nonisolated struct InflightPayload: Decodable, Sendable {
    let operation: String
    let request: InFlightRequest?   // present for upsert
    let requests: [InFlightRequest]? // present for snapshot (absent when empty)
    let id: String?                  // present for remove
}

extension InflightEvent {
    nonisolated init?(payload: InflightPayload) {
        switch payload.operation {
        case "upsert":
            guard let req = payload.request else { return nil }
            self = .upsert(req)
        case "snapshot":
            self = .snapshot(payload.requests ?? [])
        case "remove":
            guard let id = payload.id else { return nil }
            self = .remove(id: id)
        default:
            return nil
        }
    }
}
