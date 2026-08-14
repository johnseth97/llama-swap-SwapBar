import AppKit
import SwiftUI
import Observation

/// Owns the menu bar icon directly via AppKit, bypassing SwiftUI's `MenuBarExtra` label
/// rendering entirely. This is a deliberate architectural pivot — see §3/§4 in the spec.
///
/// Three separate, serious bugs were found in `MenuBarExtra`'s label on this AppKit version:
/// applying `.symbolEffect(.variableColor.iterative)` leaked to 12GB in one session;
/// `TimelineView`-driven ticking (at every tested frequency, and even bounded to stop after
/// a fixed window) pegged the CPU and leaked memory under real sustained load; and even once
/// both of those were fixed, changing an `@Observable` property read by the label — without
/// also touching `state` itself — silently failed to refresh the icon at all. Mature menu bar
/// apps with frequently-updating icons (system monitors, etc.) generally manage `NSStatusItem`
/// directly rather than through `MenuBarExtra`, and doing the same here sidesteps all three
/// issues at once: no SwiftUI symbol-effect/animation machinery, no polling loop, and a plain
/// `statusItem.button?.image` assignment that's unambiguous about when it takes effect.
///
/// SwiftUI is still used for the dropdown content (`DropdownView`), hosted via
/// `NSHostingController` inside an `NSPopover` — that part of `MenuBarExtra` never had any
/// of these problems.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var client: SwapClient!
    private let ramp = ColorRamp.defaults

    func applicationDidFinishLaunching(_ notification: Notification) {
        let client = SwapClient(name: "llama-swap", baseURL: URL(string: "http://localhost:8090")!)
        client.start()
        self.client = client

        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        self.statusItem = statusItem

        let popover = NSPopover()
        popover.behavior = .transient
        self.popover = popover
        rebuildPopoverContent()

        updateIcon()
        observeStateMachine()
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    /// `SwapClient.baseURL` is immutable by design (§4: no single-host assumption) —
    /// "changing the address" means stopping the old client and starting a fresh one.
    private func changeAddress(to url: URL) {
        client.stop()
        let newClient = SwapClient(name: client.name, baseURL: url)
        newClient.start()
        client = newClient
        rebuildPopoverContent()
        updateIcon()
        observeStateMachine()
    }

    private func rebuildPopoverContent() {
        popover.contentViewController = NSHostingController(
            rootView: DropdownView(client: client, onChangeAddress: { [weak self] url in
                self?.changeAddress(to: url)
            })
        )
    }

    /// Manual Observation tracking — `withObservationTracking`'s `onChange` fires once per
    /// registration, so this re-subscribes after every fire to keep observing indefinitely.
    private func observeStateMachine() {
        withObservationTracking {
            _ = client.stateMachine.state
            _ = client.stateMachine.rampStopReached
        } onChange: { [self] in
            Task { @MainActor [weak self] in
                self?.updateIcon()
                self?.observeStateMachine()
            }
        }
    }

    private func updateIcon() {
        let state = client.stateMachine.state
        let symbolName: String
        let color: NSColor
        var fadeDuration: TimeInterval = 0

        switch state {
        case .unreachable:
            symbolName = "exclamationmark.triangle"
            color = .secondaryLabelColor
        case .idle:
            symbolName = "moon.zzz"
            color = .labelColor
        case .loading:
            symbolName = "arrow.down.circle"
            color = .secondaryLabelColor
        case .loaded:
            symbolName = "server.rack"
            color = .labelColor
        case .active:
            symbolName = "server.rack"
            let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            let stopReached = client.stateMachine.rampStopReached
            color = NSColor(ramp.color(at: stopReached, reduceMotion: reduceMotion))
            // We only ever get `ramp.stops.count` discrete data points (§3 — continuous
            // per-event updates aren't safe on this AppKit version), not a real per-frame
            // signal. Rather than snap instantly at each one, fade toward it over the gap
            // until the NEXT checkpoint, so it reads as a continuous sweep even though
            // nothing is actually re-rendering in between — Core Animation interpolates the
            // crossfade on its own compositor, so this doesn't reintroduce the update-cost
            // problem that caused the original leak/freeze.
            if !reduceMotion,
               let currentIndex = ramp.stops.firstIndex(where: { $0.t == stopReached }),
               currentIndex + 1 < ramp.stops.count {
                fadeDuration = ramp.stops[currentIndex + 1].t - stopReached
            }
        }

        guard let baseImage = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) else { return }
        let sizeConfig = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium, scale: .medium)
        let colorConfig = NSImage.SymbolConfiguration(paletteColors: [color])
        let config = sizeConfig.applying(colorConfig)

        guard let button = statusItem.button else { return }
        if fadeDuration > 0 {
            button.wantsLayer = true
            let transition = CATransition()
            transition.type = .fade
            transition.duration = fadeDuration
            transition.timingFunction = CAMediaTimingFunction(name: .linear)
            button.layer?.add(transition, forKey: "iconColorFade")
        }
        button.image = baseImage.withSymbolConfiguration(config)
    }
}
