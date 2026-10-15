import SwiftUI
import MideaKit

struct PowerButton: View {
    let isOn: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "power")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(isOn ? Theme.onPrimary : Theme.ink)
                .frame(width: 46, height: 46)
                .raised(Circle(), fill: isOn ? Theme.primary : (hover ? Theme.surfaceSelected : Theme.surfaceRaised))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeInOut(duration: 0.15), value: isOn)
        .help(isOn ? "Turn off" : "Turn on")
    }
}

struct RoundIconButton: View {
    let symbol: String
    let action: () -> Void
    @State private var hover = false

    init(_ symbol: String, action: @escaping () -> Void) {
        self.symbol = symbol
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .frame(width: 46, height: 46)
                .raised(Circle(), fill: hover ? Theme.surfaceSelected : Theme.surfaceRaised)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct TemperatureSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height
            let knobWidth: CGFloat = 30
            let span = max(range.upperBound - range.lowerBound, 0.5)
            let fraction = CGFloat(min(max((value - range.lowerBound) / span, 0), 1))
            let knobCenter = knobWidth / 2 + fraction * (width - knobWidth)

            ZStack(alignment: .leading) {
                // The track is a well pressed into the stone; the fill is the accent; the knob a stone key.
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.surfaceSunken)
                RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.line, lineWidth: 1)
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(LinearGradient(colors: [Theme.primary.opacity(0.45), Theme.primary.opacity(0.95)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(knobWidth, knobCenter + knobWidth / 2))
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Theme.surfaceRaised)
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.edge, lineWidth: 1))
                    .frame(width: knobWidth, height: height - 12)
                    .shadow(color: Theme.shadow, radius: 4, y: 2)
                    .offset(x: knobCenter - knobWidth / 2)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let f = min(max((g.location.x - knobWidth / 2) / (width - knobWidth), 0), 1)
                        let raw = range.lowerBound + Double(f) * span
                        let snapped = (raw / step).rounded() * step
                        if snapped != value { value = snapped }
                    }
            )
        }
        .frame(height: 46)
        .animation(.interactiveSpring(duration: 0.15), value: value)
    }
}

struct TileBody<Trailing: View>: View {
    let icon: String
    let label: String
    let value: String
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .regular))
                Spacer(minLength: 0)
                trailing()
            }
            .frame(height: 24)
            Spacer(minLength: 6)
            Text(label).font(.system(size: 12)).foregroundStyle(Theme.inkMuted)
            Text(value)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .padding(.top, 2)
        }
        .padding(13)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

struct TileMenu<Items: View>: View {
    let icon: String
    let label: String
    let value: String
    @ViewBuilder let items: () -> Items
    @State private var hover = false

    var body: some View {
        Menu {
            items()
        } label: {
            TileBody(icon: icon, label: label, value: value) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.inkMuted)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .frame(maxWidth: .infinity)
        .frame(height: 108)
        .raised(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous), fill: hover ? Theme.surfaceSelected : Theme.surfaceRaised)
        .onHover { hover = $0 }
    }
}

struct TileToggle: View {
    let icon: String
    let label: String
    let isOn: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            TileBody(icon: icon, label: label, value: isOn ? "On" : "Off") {
                Circle()
                    .fill(isOn ? Theme.success : Theme.lineStrong)
                    .frame(width: 7, height: 7)
                    .shadow(color: isOn ? Theme.success.opacity(0.8) : .clear, radius: 4)
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .frame(height: 108)
        .raised(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous), fill: hover ? Theme.surfaceSelected : Theme.surfaceRaised)
        .onHover { hover = $0 }
    }
}

struct EcoCard: View {
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "leaf")
                .font(.system(size: 17))
                .foregroundStyle(isOn ? Theme.success : Theme.ink)
            Text(label).font(.system(size: 15, weight: .medium))
            StoneSwitch(isOn: $isOn)
                .accessibilityLabel(label)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .raised(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
    }
}

struct StatusLabel: View {
    let status: ConnectionStatus

    var body: some View {
        HStack(spacing: 8) {
            switch status {
            case .connected:
                Image(systemName: "checkmark.shield")
                Text("Connected")
            case .syncing:
                ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 14, height: 14)
                Text("Syncing…")
            case .connecting:
                ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 14, height: 14)
                Text("Connecting…")
            case .offline(let message):
                Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.danger)
                Text(message).lineLimit(1).truncationMode(.tail)
            case .notConfigured:
                Image(systemName: "questionmark.circle")
                Text("Not set up")
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(Theme.inkMuted)
    }
}

/// A switch cut from the same stone: a sunken track that fills with the accent when on, and a raised key.
/// Pure SwiftUI (no AppKit control), so it also renders in offscreen images.
struct StoneSwitch: View {
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule().fill(isOn ? Theme.primary : Theme.surfaceSunken)
                Capsule().strokeBorder(isOn ? Theme.edge : Theme.line, lineWidth: 1)
                Circle()
                    .fill(isOn ? Theme.onPrimary : Theme.surfaceRaised)
                    .overlay(Circle().strokeBorder(Theme.edge, lineWidth: 1))
                    .shadow(color: Theme.shadow, radius: 2, y: 1)
                    .padding(2)
            }
            .frame(width: 40, height: 24)
            .contentShape(Capsule())
            .animation(.easeInOut(duration: 0.15), value: isOn)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}
