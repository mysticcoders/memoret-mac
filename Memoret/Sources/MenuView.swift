import SwiftUI

struct MenuView: View {
    @ObservedObject var model: ReceiverModel
    @State private var showQR = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Circle()
                    .fill(model.running ? Color.green : Color.orange)
                    .frame(width: 9, height: 9)
                Text(model.running ? "Receiving" : "Not receiving")
                    .font(.headline)
                Spacer()
            }
            Text(model.statusDetail)
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Saving to")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Text(model.vaultPath)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Change…") { model.chooseVaultFolder() }
                        .controlSize(.small)
                }
            }

            Divider()

            if showQR {
                VStack(spacing: 8) {
                    if let qr = PairingQR.image(for: model.pairingJSON) {
                        Image(nsImage: qr)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 240, height: 240)
                    }
                    Text("Scan with the Memoret app on your iPhone. This QR shares only the public key and delivery token — it cannot decrypt your notes.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    HStack {
                        Button("Copy pairing JSON") { model.copyPairingJSON() }
                            .controlSize(.small)
                        Button("Hide") { showQR = false }
                            .controlSize(.small)
                    }
                }
                .frame(maxWidth: .infinity)
            } else {
                Button {
                    showQR = true
                } label: {
                    Label("Pair a device", systemImage: "qrcode")
                        .frame(maxWidth: .infinity)
                }
            }

            if !model.recentCaptures.isEmpty {
                Divider()
                Text("Recent captures")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(model.recentCaptures.prefix(5)) { capture in
                    HStack {
                        Image(systemName: "waveform")
                            .foregroundStyle(.green)
                            .font(.caption)
                        Text(capture.notePath)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text(capture.receivedAt, style: .time)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Divider()

            HStack {
                Text("Activity")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let ping = model.lastPing {
                    Text("Last ping \(ping, style: .time)")
                        .font(.caption2)
                        .foregroundStyle(.green)
                } else {
                    Text("No pings yet")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if model.events.isEmpty {
                Text("Waiting for connections — pings and deliveries will appear here.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(model.events.prefix(6)) { event in
                        HStack(alignment: .firstTextBaseline) {
                            Text(event.date, style: .time)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .monospacedDigit()
                            Text(event.text)
                                .font(.caption2)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
            }

            Divider()

            Toggle("Show Dock icon", isOn: $model.showDockIcon)
                .toggleStyle(.checkbox)
                .font(.caption)

            HStack {
                Text("Fingerprint \(model.fingerprint)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .controlSize(.small)
            }
        }
        .padding(14)
        .frame(width: 320)
    }
}
