import SwiftUI

/// One row in the dropdown's model list (§6). Green dot when `ready`, grey/transparent
/// otherwise — covers `stopped`, the transient `stopping` teardown state (§0), and any
/// future state string without needing to special-case each one. Tapping the row toggles
/// load/unload.
struct ModelRow: View {
    let model: ModelStatus
    let onToggle: () -> Void

    @State private var isHovering = false

    private var isReady: Bool { model.state == "ready" }

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 8) {
                Circle()
                    .fill(isReady ? Color.green : Color.gray.opacity(0.3))
                    .frame(width: 8, height: 8)
                    .accessibilityLabel(isReady ? "Loaded" : "Not loaded")
                Text(model.name.isEmpty ? model.id : model.name)
                    .foregroundStyle(isHovering ? Color.white : Color.primary)
                Spacer(minLength: 8)
                Text(isReady ? "Click To Stop" : "Click To Start")
                    .font(.caption)
                    .foregroundStyle(isHovering ? Color.white.opacity(0.9) : Color.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(isHovering ? Color.white.opacity(0.25) : Color.primary.opacity(0.08)))
            }
            .padding(.horizontal)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .background(isHovering ? Color.accentColor : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .onHover { isHovering = $0 }
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 0) {
        ModelRow(model: ModelStatus(id: "embed", name: "", description: "", state: "ready", unlisted: false, peerID: "", aliases: nil), onToggle: {})
        ModelRow(model: ModelStatus(id: "coder-flash", name: "", description: "", state: "stopped", unlisted: false, peerID: "", aliases: nil), onToggle: {})
    }
}
