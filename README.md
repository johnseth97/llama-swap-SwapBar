# SwapBar

A native macOS menu bar client for [llama-swap](https://github.com/mostlygeek/llama-swap). Glance at the menu bar to see whether a model is loaded, watch the icon shift color while a request is in flight, and manage models without opening a browser tab.

## Requirements

- macOS 14.0 or later
- A running [llama-swap](https://github.com/mostlygeek/llama-swap) instance. Built and verified live against a running instance (August 2026) — relies on its `/api/events` SSE stream and a handful of documented REST endpoints. The exact API surface this was built and tested against, including a few behaviors not documented upstream (e.g. streaming completions emit progress `upsert` events roughly every 250ms; unloading a model briefly reports a `stopping` state), is written up in [`.agents/SwapBar-spec.md`](.agents/SwapBar-spec.md).

## Install

Not yet on Homebrew. For now, build from source:

```sh
git clone git@github.com:johnseth97/llama-swap-SwapBar.git
cd llama-swap-SwapBar
open SwapBar.xcodeproj
```

Build and run with ⌘R. SwapBar defaults to `http://localhost:8090` — change the address from the dropdown if your instance runs elsewhere.

## What it does (v0.1)

- Menu bar icon reflects llama-swap's state at a glance: unreachable, idle, loading, models loaded, or a request in flight
- The icon shifts white → green → yellow → red the longer a request runs, so a glance tells you whether something's taking unusually long
- Click the icon to see every configured model with a green/grey dot for loaded/unloaded — click any row to load or unload it
- One click to open llama-swap's own web UI
- Point SwapBar at a different llama-swap instance without restarting

## What's not here yet

- Preferences window / persisted settings (the address change in the dropdown is session-only right now — it resets on relaunch)
- Multiple simultaneous instances (the architecture is built for it — `SwapClient` owns exactly one instance with no single-host assumptions — but there's no UI for a list of them yet)
- Memory/CPU/GPU reporting in the dropdown
- Launch at login
- A Quit menu item (stop it from Activity Monitor or Xcode for now)
- Code signing, notarization, and a Homebrew cask

See [`.agents/SwapBar-spec.md`](.agents/SwapBar-spec.md) for the full build plan, the live-verification findings behind it, and what's still ahead.

## Development notes

A few decisions worth knowing about before changing this code:

- **`StateMachine` is a pure reducer** — no networking, no timers — and is fully unit tested independent of a running server.
- **The menu bar icon is managed directly via `NSStatusItem`, not SwiftUI's `MenuBarExtra`.** Three separate, serious bugs were found in `MenuBarExtra`'s label rendering on the macOS version this was built against: applying `.symbolEffect(.variableColor.iterative)` leaked memory into double digits of GB within a single session; `TimelineView`-driven ticking pegged the CPU and leaked memory under sustained real load at every frequency tried; and even once both of those were fixed, changing an `@Observable` property read by the label — without also touching a `state`-typed property specifically — silently failed to refresh the icon at all. See the spec doc if you're tempted to move icon rendering back to `MenuBarExtra`.
- **The color ramp is a discrete 4-step animation with a `CATransition` crossfade between steps, not continuous interpolation**, for the same reason above — a real per-frame animation reliably froze the app or leaked memory under a genuine long-running chat completion, not just in synthetic testing.

## Testing

```sh
xcodebuild test -project SwapBar.xcodeproj -scheme SwapBar -destination 'platform=macOS' -only-testing:SwapBarTests
```

60 unit tests cover the state machine, color ramp, SSE parsing/reconnect logic, and the HTTP client — all runnable without a live llama-swap instance (a stubbed `URLProtocol` stands in for the network). UI tests exist but are excluded from the default run; see the spec doc for why.

## License

MIT — matching llama-swap's own license.
