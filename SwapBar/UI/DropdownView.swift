import SwiftUI

/// The MenuBarExtra window content (§6). Minimal for now — header, model list, Open Web UI.
/// Memory reporting and the activity row land in later build-order steps.
struct DropdownView: View {
    let client: SwapClient
    let onChangeAddress: (URL) -> Void

    @State private var isEditingAddress = false
    @State private var addressInput = ""
    @State private var isHoveringWebUIButton = false

    private static let width: CGFloat = 240

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(client.stateMachine.state.isReachable ? Color.green : Color.gray.opacity(0.3))
                        .frame(width: 8, height: 8)
                    Text(client.name)
                        .fontWeight(.semibold)
                }

                if isEditingAddress {
                    HStack(spacing: 6) {
                        TextField("http://localhost:8090", text: $addressInput)
                            .textFieldStyle(.plain)
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.primary.opacity(0.08))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 4)
                                            .stroke(Color.primary.opacity(0.25), lineWidth: 1)
                                    )
                            )
                            .onSubmit { commitAddressChange() }
                        Button("Save") { commitAddressChange() }
                            .font(.caption)
                            .focusEffectDisabled()
                    }
                } else {
                    HStack(spacing: 6) {
                        Button("Click to change address") {
                            addressInput = client.baseURL.absoluteString
                            isEditingAddress = true
                        }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .underline()

                        Text(client.displayAddress)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            let models = client.stateMachine.allModels
            if models.isEmpty {
                Text("No models configured")
                    .foregroundStyle(.secondary)
                    .padding()
            } else {
                ForEach(models, id: \.id) { model in
                    ModelRow(model: model) {
                        Task {
                            do {
                                try await client.toggleLoad(for: model)
                            } catch {
                                print("[DropdownView] toggle failed for \(model.id): \(error)")
                            }
                        }
                    }
                }
            }

            Divider()

            HStack {
                Spacer()
                Button("Open Web UI") {
                    NSWorkspace.shared.open(client.webUIURL)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(isHoveringWebUIButton ? Color.accentColor : Color.primary.opacity(0.08))
                .foregroundStyle(isHoveringWebUIButton ? Color.white : Color.primary)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .onHover { isHoveringWebUIButton = $0 }
                Spacer()
            }
            .padding(8)
        }
        .padding(.vertical, 8)
        .frame(width: Self.width)
    }

    private func commitAddressChange() {
        guard let url = URL(string: addressInput), url.scheme != nil, url.host != nil else { return }
        onChangeAddress(url)
        isEditingAddress = false
    }
}

#Preview {
    let client = SwapClient(name: "llama-swap", baseURL: URL(string: "http://localhost:8090")!)
    client.stateMachine.handle(.connected)
    client.stateMachine.handle(.modelStatusReceived([
        ModelStatus(id: "embed", name: "", description: "", state: "ready", unlisted: false, peerID: "", aliases: nil),
        ModelStatus(id: "coder-flash", name: "", description: "", state: "stopped", unlisted: false, peerID: "", aliases: nil),
    ]))
    return DropdownView(client: client, onChangeAddress: { _ in })
}
