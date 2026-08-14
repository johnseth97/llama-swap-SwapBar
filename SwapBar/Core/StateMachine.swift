import Foundation
import Observation

// MARK: - Public State

nonisolated enum SwapState: Equatable, Sendable {
    case unreachable(since: Date)
    case idle
    case loading(model: String, progress: Double?)
    case loaded(models: [LoadedModel])
    case active(models: [LoadedModel], request: InFlightRequest)

    var isReachable: Bool {
        if case .unreachable = self { return false }
        return true
    }
}

// MARK: - Input Events

nonisolated enum SwapStateEvent: Sendable {
    case connected
    case disconnected(at: Date)
    case modelStatusReceived([ModelStatus])
    case inflightReceived(InflightEvent)
}

// MARK: - Internal Reducer State

/// Full reducer state — includes the swap state visible to UI plus the inflight
/// request dictionary needed to maintain consistency across remove/upsert ordering.
nonisolated struct MachineState: Equatable, Sendable {
    var swap: SwapState
    var inflight: [String: InFlightRequest]

    init(swap: SwapState = .unreachable(since: .distantPast), inflight: [String: InFlightRequest] = [:]) {
        self.swap     = swap
        self.inflight = inflight
    }
}

// MARK: - Pure Reducer

/// Pure state function — no networking, no timers, no SwiftUI dependencies.
/// All observable side effects belong in `StateMachine` (the @Observable wrapper), not here.
nonisolated func reduce(state: MachineState, event: SwapStateEvent) -> MachineState {
    var next = state

    switch event {
    case .disconnected(let at):
        next.swap     = .unreachable(since: at)
        next.inflight = [:]

    case .connected:
        // Only leave unreachable on a successful connection.
        // modelStatus will immediately follow and establish the real state.
        if case .unreachable = next.swap { next.swap = .idle }

    case .modelStatusReceived(let models):
        let ready = models.filter { $0.state == "ready" }.map { LoadedModel($0) }
        // "stopping" is a real, observed teardown transition (unload in progress) — it must
        // NOT trigger `.loading`, which is specifically for the model-loads direction (§2).
        let loading = models.first { $0.state != "ready" && $0.state != "stopped" && $0.state != "stopping" }

        if !next.inflight.isEmpty, let req = oldestRequest(in: next.inflight) {
            // Stay active with updated model list.
            next.swap = .active(models: ready, request: req)
        } else if !ready.isEmpty {
            next.swap = .loaded(models: ready)
        } else if let m = loading {
            next.swap = .loading(model: m.id, progress: nil)
        } else {
            next.swap = .idle
        }

    case .inflightReceived(let event):
        switch event {
        case .snapshot(let requests):
            // Replace the entire inflight dict; snapshot is authoritative initial state.
            next.inflight = Dictionary(uniqueKeysWithValues: requests.map { ($0.id, $0) })
        case .upsert(let req):
            next.inflight[req.id] = req
        case .remove(let id):
            next.inflight.removeValue(forKey: id)
        }
        next.swap = derivedSwapState(from: next.swap, inflight: next.inflight)
    }

    return next
}

// MARK: - Helpers

nonisolated private func derivedSwapState(from current: SwapState, inflight: [String: InFlightRequest]) -> SwapState {
    if let req = oldestRequest(in: inflight) {
        return .active(models: currentModels(from: current), request: req)
    }
    switch current {
    case .active(let models, _):
        return models.isEmpty ? .idle : .loaded(models: models)
    default:
        return current
    }
}

/// Returns the request with the lexicographically smallest ID (monotonic, so smallest = oldest).
nonisolated private func oldestRequest(in dict: [String: InFlightRequest]) -> InFlightRequest? {
    dict.values.min { $0.id < $1.id }
}

nonisolated private func currentModels(from state: SwapState) -> [LoadedModel] {
    switch state {
    case .loaded(let m):       return m
    case .active(let m, _):    return m
    default:                   return []
    }
}

// MARK: - Observable Wrapper

/// Drives the UI. Receives raw `SwapStateEvent`s from `SwapClient`
/// and publishes the derived `SwapState` for SwiftUI observation.
@Observable
@MainActor
final class StateMachine {
    private(set) var state: SwapState = .unreachable(since: .distantPast)

    /// Client-observed start time of the current `.active` request, for `ColorRamp` (§3).
    /// Per §3, this must be *client*-received time, not server data — captured the moment
    /// this request id is first observed as active (whether via a true start `upsert` or a
    /// catch-up `snapshot`), and held steady across subsequent updates to the same request.
    private(set) var activeRequestAnchor: Date?

    /// Full model list from the last `modelStatus` event, including non-`ready` models —
    /// `SwapState` only retains `ready` models (§2's `.loaded`/`.active` cases), but the
    /// dropdown (§6) needs to list every configured model regardless of state.
    private(set) var allModels: [ModelStatus] = []

    /// Highest ramp stop (in elapsed seconds) reached so far for the current `.active`
    /// request — `AppDelegate` maps this through `ColorRamp` to get a color for the menu bar
    /// icon (managed directly via `NSStatusItem`, not SwiftUI — see `AppDelegate` for why).
    /// Owned here, not by any view: `MenuBarExtra` labels were confirmed live not to reliably
    /// persist or progress view-local `@State`/`.task` (the color never advanced past its
    /// initial value), which is part of why the icon moved off `MenuBarExtra` entirely. This
    /// property, like `activeRequestAnchor` above, is driven by a task this class owns
    /// directly, whose lifecycle is tied to the request rather than to any view.
    private(set) var rampStopReached: Double = 0

    private let rampStops: [Double]
    private var machineState = MachineState()
    private var lastActiveRequestID: String?
    private var rampTask: Task<Void, Never>?

    init(rampStops: [Double]? = nil) {
        self.rampStops = rampStops ?? ColorRamp.defaults.stops.map(\.t)
    }

    func handle(_ event: SwapStateEvent) {
        machineState = reduce(state: machineState, event: event)
        let newSwapState = machineState.swap

        if case .modelStatusReceived(let models) = event {
            allModels = models
        }

        // Anchor tracking reads the true reducer output, not the (possibly suppressed
        // below) published `state` — this must stay accurate regardless of publish throttling.
        if case .active(_, let request) = newSwapState {
            if request.id != lastActiveRequestID {
                let anchor = Date()
                activeRequestAnchor = anchor
                lastActiveRequestID = request.id
                startRampTask(from: anchor)
            }
        } else {
            activeRequestAnchor = nil
            lastActiveRequestID = nil
            rampTask?.cancel()
            rampTask = nil
            rampStopReached = 0
        }

        // Suppress redundant publishes while the same request stays active. Confirmed live:
        // a streaming chat completion fires an `upsert` roughly every 250ms for its entire
        // duration (elapsed_ms/resp_bytes ticking up) — fields the UI doesn't render (the
        // color ramp derives elapsed time from `activeRequestAnchor` + wall clock, not from
        // the request object). Publishing every one of those anyway forces a full SwiftUI
        // re-render — and NSStatusBarButton.setImage: has real, measured per-call cost on
        // this AppKit version — for a response that can run hundreds of ticks long with zero
        // visible benefit. Only publish when something UI-relevant actually changed.
        if case .active(let models, let request) = newSwapState,
           case .active(let prevModels, let prevRequest) = state,
           models == prevModels, request.id == prevRequest.id {
            return
        }

        state = newSwapState
    }

    /// Advances `rampStopReached` once per stop, at most `rampStops.count` times total for
    /// the request's entire lifetime — same bounded-cost reasoning as the rest of §3's
    /// ramp handling, just owned here instead of in the view.
    private func startRampTask(from start: Date) {
        rampTask?.cancel()
        rampStopReached = rampStops.first ?? 0
        rampTask = Task { [weak self] in
            guard let self else { return }
            for stop in rampStops {
                let delay = stop - Date().timeIntervalSince(start)
                if delay > 0 {
                    try? await Task.sleep(for: .seconds(delay))
                }
                if Task.isCancelled { return }
                self.rampStopReached = stop
                // Confirmed live: a bare `rampStopReached` change, with `state` held constant
                // (which the publish-suppression above deliberately does while active), was NOT
                // enough to refresh the MenuBarExtra label — only `state` reassignment reliably
                // has. Re-touching it here (still bounded to `rampStops.count` times total, same
                // as the rampStopReached update itself) piggybacks on that already-proven path.
                self.state = self.machineState.swap
            }
        }
    }
}
