import SwiftUI
import MideaKit

struct SetupFlowView: View {
    @EnvironmentObject var store: DeviceStore
    @State private var step = 0
    @State private var selected: DiscoveredDevice?
    @State private var manualHost = ""
    @State private var name = ""
    @State private var account = ""
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "air.conditioner.horizontal").font(.system(size: 22)).foregroundStyle(Theme.inkMuted)
                Text("Set up Breeze").font(.system(size: 22, weight: .medium, design: .serif))
                Spacer()
                if store.isConfigured {
                    Button("Cancel") { store.showSetup = false }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.inkMuted)
                }
            }
            if step == 0 { findStep } else { linkStep }
        }
        .padding(20)
        .foregroundStyle(Theme.ink)
        .onAppear {
            name = store.sessions.isEmpty ? "Office" : ""
            if store.discovered.isEmpty { store.scan() }
        }
    }

    private var findStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("1 · Find your air conditioner").font(.headline)
            Text("Breeze looks for Midea units on this Wi-Fi network.")
                .font(.system(size: 12)).foregroundStyle(Theme.inkMuted)

            if store.isScanning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Scanning…").foregroundStyle(Theme.inkMuted)
                }
            }

            ForEach(store.discovered) { device in
                Button { selected = device } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "air.conditioner.horizontal").font(.system(size: 18))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Midea AC · \(device.shortTag)").fontWeight(.medium)
                            Text("\(device.ip)  ·  id \(String(device.deviceId))" + (store.isAlreadyConfigured(device) ? "  ·  already added" : ""))
                                .font(.system(size: 11)).foregroundStyle(Theme.inkMuted)
                        }
                        Spacer()
                        if selected == device {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.primary)
                        }
                    }
                    .padding(12)
                    .background(selected == device ? Theme.surfaceSelected : Theme.surfaceRaised,
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if let error = store.scanError {
                Text(error).font(.system(size: 12)).foregroundStyle(Theme.danger)
            }

            HStack(spacing: 8) {
                TextField("IP address", text: $manualHost)
                    .textFieldStyle(.roundedBorder)
                Button("Probe") { store.scan(host: manualHost) }
                    .disabled(manualHost.isEmpty || store.isScanning)
                Button("Rescan") { store.scan() }
                    .disabled(store.isScanning)
            }

            if store.discovered.count > 1 {
                Text("Several units answered. After linking, use “Identify” in Settings to blink a unit's display and confirm which one it is.")
                    .font(.system(size: 11)).foregroundStyle(Theme.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Next") { step = 1 }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.primary)
                    .foregroundStyle(.black)
                    .disabled(selected == nil)
            }
        }
    }

    private var linkStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("2 · Link your Midea account").font(.headline)
            Text("Newer Midea units only accept local commands with a token issued by Midea's cloud for the account the unit is paired with. Breeze fetches that token once using your MSmartHome login, keeps it on this Mac, and controls the unit over Wi-Fi from then on. Your password is not stored.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.inkMuted)
                .fixedSize(horizontal: false, vertical: true)

            if let device = selected {
                Text("Unit: Midea AC · \(device.shortTag) at \(device.ip)")
                    .font(.system(size: 12)).foregroundStyle(Theme.inkMuted)
            }

            TextField("Name (e.g. Office)", text: $name).textFieldStyle(.roundedBorder)
            TextField("MSmartHome email", text: $account)
                .textFieldStyle(.roundedBorder)
                .textContentType(.username)
                .autocorrectionDisabled()
            SecureField("Password", text: $password).textFieldStyle(.roundedBorder)

            if let error = store.linkError {
                Text(error).font(.system(size: 12)).foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Back") { step = 0 }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.inkMuted)
                Spacer()
                if store.isLinking { ProgressView().controlSize(.small) }
                Button("Link & connect") {
                    if let device = selected {
                        store.link(device: device, name: name, account: account, password: password)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.primary)
                .foregroundStyle(.black)
                .disabled(selected == nil || account.isEmpty || password.isEmpty || store.isLinking)
            }
        }
    }
}
