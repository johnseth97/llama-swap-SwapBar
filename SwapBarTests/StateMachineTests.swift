import Testing
import Foundation
@testable import SwapBar

// MARK: - Helpers

private func makeRequest(id: String, elapsedMs: Int = 0, respHeaders: [String: String] = [:]) -> InFlightRequest {
    InFlightRequest(
        id: id, timestamp: "2026-08-12T00:00:00Z", model: "coder-flash",
        reqPath: "/v1/chat/completions", method: "POST",
        reqHeaders: [:], remoteIP: "127.0.0.1",
        respHeaders: respHeaders, respBytes: 0, elapsedMs: elapsedMs
    )
}

private func makeModel(id: String, state: String = "ready") -> ModelStatus {
    ModelStatus(id: id, name: id, description: "", state: state, unlisted: false, peerID: "", aliases: nil)
}

// MARK: - StateMachine Tests

@Suite("StateMachine — pure reducer")
struct StateMachineTests {

    // MARK: Connection lifecycle

    @Test("disconnected → unreachable with provided date")
    func disconnectedBecomesUnreachable() {
        let date = Date(timeIntervalSinceReferenceDate: 1000)
        let result = reduce(state: .init(), event: .disconnected(at: date))
        guard case .unreachable(let since) = result.swap else {
            Issue.record("Expected .unreachable, got \(result.swap)")
            return
        }
        #expect(since == date)
    }

    @Test("connected from unreachable → idle")
    func connectedFromUnreachableBecomesIdle() {
        let initial = MachineState(swap: .unreachable(since: .distantPast))
        let result  = reduce(state: initial, event: .connected)
        #expect(result.swap == .idle)
    }

    @Test("connected from loaded stays loaded (modelStatus will follow)")
    func connectedFromLoadedStaysLoaded() {
        let model   = LoadedModel(id: "embed")
        let initial = MachineState(swap: .loaded(models: [model]))
        let result  = reduce(state: initial, event: .connected)
        #expect(result.swap == .loaded(models: [model]))
    }

    // MARK: modelStatus events

    @Test("modelStatus with ready models → loaded")
    func modelStatusReadyBecomesLoaded() {
        let result = reduce(
            state: .init(swap: .idle),
            event: .modelStatusReceived([makeModel(id: "embed", state: "ready")])
        )
        guard case .loaded(let models) = result.swap else {
            Issue.record("Expected .loaded, got \(result.swap)")
            return
        }
        #expect(models.count == 1)
        #expect(models[0].id == "embed")
    }

    @Test("modelStatus with all stopped → idle")
    func modelStatusAllStoppedBecomesIdle() {
        let result = reduce(
            state: .init(swap: .loaded(models: [LoadedModel(id: "embed")])),
            event: .modelStatusReceived([makeModel(id: "embed", state: "stopped")])
        )
        #expect(result.swap == .idle)
    }

    @Test("modelStatus with loading model → loading state")
    func modelStatusLoadingBecomesLoading() {
        let result = reduce(
            state: .init(swap: .idle),
            event: .modelStatusReceived([makeModel(id: "coder", state: "loading")])
        )
        guard case .loading(let id, _) = result.swap else {
            Issue.record("Expected .loading, got \(result.swap)")
            return
        }
        #expect(id == "coder")
    }

    @Test("modelStatus with a stopping model (unload in progress) does NOT trigger loading")
    func modelStatusStoppingDoesNotBecomeLoading() {
        // Observed live against llama-swap: unloading a model briefly reports "stopping"
        // before "stopped". `.loading` is specifically the model-loads direction (§2) —
        // showing the loading spinner while a model is actually tearing down is backwards.
        let result = reduce(
            state: .init(swap: .loaded(models: [LoadedModel(id: "embed")])),
            event: .modelStatusReceived([makeModel(id: "embed", state: "stopping")])
        )
        #expect(result.swap == .idle)
    }

    @Test("modelStatus replaces model list (no merge)")
    func modelStatusReplacesModels() {
        let initial = MachineState(swap: .loaded(models: [LoadedModel(id: "old")]))
        let result  = reduce(
            state: initial,
            event: .modelStatusReceived([
                makeModel(id: "new1", state: "ready"),
                makeModel(id: "new2", state: "ready"),
            ])
        )
        guard case .loaded(let models) = result.swap else {
            Issue.record("Expected .loaded")
            return
        }
        #expect(models.map(\.id).sorted() == ["new1", "new2"])
    }

    @Test("modelStatus during active preserves inflight request")
    func modelStatusDuringActivePreservesRequest() {
        let req     = makeRequest(id: "1")
        let initial = MachineState(
            swap: .active(models: [LoadedModel(id: "embed")], request: req),
            inflight: ["1": req]
        )
        let result = reduce(
            state: initial,
            event: .modelStatusReceived([makeModel(id: "embed", state: "ready")])
        )
        guard case .active(_, let r) = result.swap else {
            Issue.record("Expected .active, got \(result.swap)")
            return
        }
        #expect(r.id == "1")
    }

    // MARK: inflight events

    @Test("inflight upsert (start) → active")
    func inflightUpsertStartBecomesActive() {
        let req    = makeRequest(id: "41")  // elapsedMs=0, respHeaders={} → isStart
        let initial = MachineState(swap: .loaded(models: [LoadedModel(id: "embed")]))
        let result  = reduce(state: initial, event: .inflightReceived(.upsert(req)))
        guard case .active(_, let r) = result.swap else {
            Issue.record("Expected .active, got \(result.swap)")
            return
        }
        #expect(r.id == "41")
        #expect(r.isStart)
    }

    @Test("inflight upsert (completion) stays active with updated request")
    func inflightUpsertCompletionUpdatesRequest() {
        let startReq = makeRequest(id: "41")
        let initial  = MachineState(
            swap: .active(models: [LoadedModel(id: "embed")], request: startReq),
            inflight: ["41": startReq]
        )
        let doneReq = makeRequest(id: "41", elapsedMs: 14275, respHeaders: ["Content-Type": "application/json"])
        let result  = reduce(state: initial, event: .inflightReceived(.upsert(doneReq)))
        guard case .active(_, let r) = result.swap else {
            Issue.record("Expected .active, got \(result.swap)")
            return
        }
        #expect(r.elapsedMs == 14275)
        #expect(!r.isStart)
    }

    @Test("inflight remove → loaded when models present")
    func inflightRemoveReturnsToLoaded() {
        let req     = makeRequest(id: "41")
        let initial = MachineState(
            swap: .active(models: [LoadedModel(id: "embed")], request: req),
            inflight: ["41": req]
        )
        let result = reduce(state: initial, event: .inflightReceived(.remove(id: "41")))
        guard case .loaded(let models) = result.swap else {
            Issue.record("Expected .loaded, got \(result.swap)")
            return
        }
        #expect(models.map(\.id) == ["embed"])
    }

    @Test("inflight remove → idle when no models")
    func inflightRemoveWithNoModelsBecomesIdle() {
        let req     = makeRequest(id: "41")
        let initial = MachineState(
            swap: .active(models: [], request: req),
            inflight: ["41": req]
        )
        let result = reduce(state: initial, event: .inflightReceived(.remove(id: "41")))
        #expect(result.swap == .idle)
    }

    @Test("inflight snapshot with requests → active")
    func inflightSnapshotBecomesActive() {
        let req     = makeRequest(id: "10")
        let initial = MachineState(swap: .loaded(models: [LoadedModel(id: "embed")]))
        let result  = reduce(state: initial, event: .inflightReceived(.snapshot([req])))
        guard case .active = result.swap else {
            Issue.record("Expected .active, got \(result.swap)")
            return
        }
        #expect(result.inflight.count == 1)
    }

    @Test("inflight snapshot empty → stays loaded")
    func inflightSnapshotEmptyStaysLoaded() {
        let initial = MachineState(swap: .loaded(models: [LoadedModel(id: "embed")]))
        let result  = reduce(state: initial, event: .inflightReceived(.snapshot([])))
        guard case .loaded = result.swap else {
            Issue.record("Expected .loaded, got \(result.swap)")
            return
        }
    }

    @Test("disconnected clears inflight requests")
    func disconnectedClearsInflight() {
        let req     = makeRequest(id: "41")
        let initial = MachineState(
            swap: .active(models: [LoadedModel(id: "embed")], request: req),
            inflight: ["41": req]
        )
        let result = reduce(state: initial, event: .disconnected(at: .now))
        #expect(result.inflight.isEmpty)
        guard case .unreachable = result.swap else {
            Issue.record("Expected .unreachable")
            return
        }
    }

    // MARK: Multi-request

    @Test("oldest request drives active state")
    func oldestRequestDrivesActive() {
        let req1    = makeRequest(id: "1")
        let req2    = makeRequest(id: "2")
        let initial = MachineState(swap: .loaded(models: [LoadedModel(id: "embed")]))
        var state   = reduce(state: initial, event: .inflightReceived(.upsert(req2)))
        state       = reduce(state: state,   event: .inflightReceived(.upsert(req1)))
        guard case .active(_, let r) = state.swap else {
            Issue.record("Expected .active")
            return
        }
        // ID "1" < "2" lexicographically → oldest
        #expect(r.id == "1")
    }

    @Test("removing non-oldest request stays active with oldest remaining")
    func removingYoungerRequestKeepsActive() {
        let req1    = makeRequest(id: "1")
        let req2    = makeRequest(id: "2")
        var initial = MachineState(
            swap: .active(models: [LoadedModel(id: "embed")], request: req1),
            inflight: ["1": req1, "2": req2]
        )
        initial = reduce(state: initial, event: .inflightReceived(.remove(id: "2")))
        guard case .active(_, let r) = initial.swap else {
            Issue.record("Expected .active after removing younger request")
            return
        }
        #expect(r.id == "1")
    }
}

// MARK: - StateMachine class — activeRequestAnchor bookkeeping

@Suite("StateMachine — activeRequestAnchor")
@MainActor
struct StateMachineAnchorTests {

    @Test("no anchor while never active")
    func noAnchorInitially() {
        let machine = StateMachine()
        #expect(machine.activeRequestAnchor == nil)
    }

    @Test("anchor set to (approximately) now on first observation of an active request")
    func anchorSetOnFirstObservation() {
        let machine = StateMachine()
        machine.handle(.modelStatusReceived([]))
        let before = Date()
        machine.handle(.inflightReceived(.upsert(makeRequest(id: "1"))))
        let after = Date()

        guard let anchor = machine.activeRequestAnchor else {
            Issue.record("expected an anchor once active")
            return
        }
        #expect(anchor >= before && anchor <= after)
    }

    @Test("anchor stays stable across repeated updates to the same request")
    func anchorStableForSameRequest() {
        let machine = StateMachine()
        machine.handle(.inflightReceived(.upsert(makeRequest(id: "1"))))
        let firstAnchor = machine.activeRequestAnchor

        // A completion upsert for the SAME id shouldn't move the anchor.
        machine.handle(.inflightReceived(.upsert(makeRequest(
            id: "1", elapsedMs: 500, respHeaders: ["Content-Type": "application/json"]
        ))))
        #expect(machine.activeRequestAnchor == firstAnchor)

        // Neither should an unrelated modelStatus refresh while still active.
        machine.handle(.modelStatusReceived([makeModel(id: "embed", state: "ready")]))
        #expect(machine.activeRequestAnchor == firstAnchor)
    }

    @Test("anchor resets when a different request becomes the active one")
    func anchorResetsForNewRequest() async throws {
        let machine = StateMachine()
        machine.handle(.inflightReceived(.upsert(makeRequest(id: "1"))))
        let firstAnchor = machine.activeRequestAnchor

        try await Task.sleep(for: .milliseconds(5))
        machine.handle(.inflightReceived(.remove(id: "1")))
        machine.handle(.inflightReceived(.upsert(makeRequest(id: "2"))))

        #expect(machine.activeRequestAnchor != nil)
        #expect(machine.activeRequestAnchor != firstAnchor)
    }

    @Test("anchor clears when leaving active state")
    func anchorClearsWhenLeavingActive() {
        let machine = StateMachine()
        machine.handle(.inflightReceived(.upsert(makeRequest(id: "1"))))
        #expect(machine.activeRequestAnchor != nil)

        machine.handle(.inflightReceived(.remove(id: "1")))
        #expect(machine.activeRequestAnchor == nil)
    }

    @Test("anchor clears on disconnect")
    func anchorClearsOnDisconnect() {
        let machine = StateMachine()
        machine.handle(.inflightReceived(.upsert(makeRequest(id: "1"))))
        #expect(machine.activeRequestAnchor != nil)

        machine.handle(.disconnected(at: .now))
        #expect(machine.activeRequestAnchor == nil)
    }
}

// MARK: - StateMachine class — rampStopReached progression

@Suite("StateMachine — rampStopReached progression")
@MainActor
struct StateMachineRampTests {

    @Test("starts at the first stop immediately on becoming active")
    func startsAtFirstStop() {
        let machine = StateMachine(rampStops: [0, 0.05, 0.1])
        machine.handle(.inflightReceived(.upsert(makeRequest(id: "1"))))
        #expect(machine.rampStopReached == 0)
    }

    @Test("advances through stops over time, owned by StateMachine not the view")
    func advancesOverTime() async throws {
        let machine = StateMachine(rampStops: [0, 0.05, 0.1])
        machine.handle(.inflightReceived(.upsert(makeRequest(id: "1"))))

        try await Task.sleep(for: .milliseconds(80))
        #expect(machine.rampStopReached == 0.05)

        try await Task.sleep(for: .milliseconds(80))
        #expect(machine.rampStopReached == 0.1)
    }

    @Test("resets to 0 when leaving active state")
    func resetsWhenLeavingActive() {
        let machine = StateMachine(rampStops: [0, 0.05, 0.1])
        machine.handle(.inflightReceived(.upsert(makeRequest(id: "1"))))
        machine.handle(.inflightReceived(.remove(id: "1")))
        #expect(machine.rampStopReached == 0)
    }

    @Test("restarts from the first stop for a new active request")
    func restartsForNewRequest() async throws {
        let machine = StateMachine(rampStops: [0, 0.05, 0.1])
        machine.handle(.inflightReceived(.upsert(makeRequest(id: "1"))))
        try await Task.sleep(for: .milliseconds(80))
        #expect(machine.rampStopReached == 0.05)

        machine.handle(.inflightReceived(.remove(id: "1")))
        machine.handle(.inflightReceived(.upsert(makeRequest(id: "2"))))
        #expect(machine.rampStopReached == 0)
    }
}

// MARK: - StateMachine class — publish suppression during streaming

@Suite("StateMachine — redundant publish suppression")
@MainActor
struct StateMachinePublishSuppressionTests {

    @Test("repeated upserts for the same active request do not change the published state instance")
    func sameRequestDoesNotRepublish() {
        // Confirmed live: a streaming chat completion fires an upsert roughly every 250ms
        // for its entire duration, ticking elapsed_ms/resp_bytes — fields nothing in the UI
        // renders. A long response could mean hundreds of these; none should force a publish.
        let machine = StateMachine()
        machine.handle(.inflightReceived(.upsert(makeRequest(id: "60", elapsedMs: 0))))
        guard case .active(_, let firstPublished) = machine.state else {
            Issue.record("expected .active")
            return
        }

        for elapsed in stride(from: 250, through: 5000, by: 250) {
            machine.handle(.inflightReceived(.upsert(makeRequest(id: "60", elapsedMs: elapsed))))
        }

        guard case .active(_, let laterPublished) = machine.state else {
            Issue.record("expected still .active")
            return
        }
        // The published request is still the FIRST one seen — later ticks for the same
        // id were suppressed rather than republished.
        #expect(laterPublished.elapsedMs == firstPublished.elapsedMs)
    }

    @Test("transition to a different active request still publishes")
    func differentRequestStillPublishes() {
        let machine = StateMachine()
        machine.handle(.inflightReceived(.upsert(makeRequest(id: "1"))))
        machine.handle(.inflightReceived(.remove(id: "1")))
        machine.handle(.inflightReceived(.upsert(makeRequest(id: "2"))))

        guard case .active(_, let published) = machine.state else {
            Issue.record("expected .active for the new request")
            return
        }
        #expect(published.id == "2")
    }

    @Test("completion upsert for the active request is suppressed, but removal still publishes")
    func completionSuppressedButRemovalPublishes() {
        let machine = StateMachine()
        machine.handle(.inflightReceived(.upsert(makeRequest(id: "1"))))

        // Completion upsert: same id, so per the suppression rule this doesn't force a
        // republish — the color ramp doesn't need it, only the eventual .loaded transition does.
        machine.handle(.inflightReceived(.upsert(makeRequest(
            id: "1", elapsedMs: 5000, respHeaders: ["Content-Type": "application/json"]
        ))))
        guard case .active = machine.state else {
            Issue.record("expected still .active immediately after completion upsert")
            return
        }

        machine.handle(.inflightReceived(.remove(id: "1")))
        #expect(machine.state == .idle)
    }
}
