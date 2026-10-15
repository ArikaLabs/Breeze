import SwiftUI
import MideaKit

struct HeroView: View {
    let isOn: Bool
    let mode: OperationalMode
    var swing: SwingMode = .off
    var fanSpeed: Int = FanSpeed.auto.rawValue

    private var tint: Color { mode == .heat ? Theme.heat : Theme.cool }

    var body: some View {
        ZStack(alignment: .top) {
            if isOn {
                AirflowView(tint: tint, swing: swing, fanSpeed: fanSpeed)
                    .frame(width: 300, height: 76)
                    .padding(.top, 56)
                    .transition(.opacity)
            }
            UnitBody(isOn: isOn, tint: tint)
        }
        .frame(maxWidth: .infinity)
        .animation(.easeInOut(duration: 0.5), value: isOn)
    }
}

struct UnitBody: View {
    let isOn: Bool
    let tint: Color

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(LinearGradient(colors: [Color(nsColor: NSColor(hex: "#fbf8f2")), Color(nsColor: NSColor(hex: "#d8d1c6"))], startPoint: .top, endPoint: .bottom))
                .frame(width: 212, height: 56)
                .shadow(color: Theme.shadow, radius: 14, y: 10)
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.black.opacity(0.07), lineWidth: 1)
                .frame(width: 198, height: 44)
                .offset(y: -2)
            Capsule()
                .fill(Color(nsColor: NSColor(hex: "#2a2420")))
                .frame(width: 184, height: 6)
                .offset(y: 20)
            Text("Midea")
                .font(.system(size: 7, weight: .semibold))
                .foregroundStyle(Color.black.opacity(0.35))
                .offset(x: -86, y: -16)
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Theme.success.opacity(0.7))
                .frame(width: 14, height: 4)
                .offset(x: 72, y: 6)
            Circle()
                .fill(isOn ? tint : Color.black.opacity(0.12))
                .frame(width: 4, height: 4)
                .shadow(color: isOn ? tint : .clear, radius: 3)
                .offset(x: 92, y: 6)
        }
        .padding(.top, 18)
    }
}

/// Flowing streaks beneath the unit. Fan speed sets pace and density; the swing setting
/// sweeps the whole field side to side (horizontal) and changes its reach and spread (vertical).
struct AirflowView: View {
    let tint: Color
    let swing: SwingMode
    let fanSpeed: Int

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            Canvas { g, size in
                let t = context.date.timeIntervalSinceReferenceDate
                let speed: CGFloat = fanSpeed == FanSpeed.auto.rawValue ? 0.6 : CGFloat(min(max(fanSpeed, 20), 100)) / 100
                let horizontal = swing == .horizontal || swing == .both
                let vertical = swing == .vertical || swing == .both

                // Horizontal swing: the louvers pan, so the whole stream drifts left and right.
                let sweep: CGFloat = horizontal ? CGFloat(sin(t * 0.8)) * 42 : 0
                // Vertical swing: the louvers tilt, so the stream alternately drops straight and reaches out.
                let tilt: CGFloat = vertical ? CGFloat(0.5 + 0.5 * sin(t * 0.65)) : 0.55
                let reach: CGFloat = size.height * (0.6 + 0.4 * tilt)
                let spreadScale: CGFloat = 0.45 + 0.9 * tilt

                let lines = 9
                let fieldWidth: CGFloat = 186
                let left: CGFloat = (size.width - fieldWidth) / 2
                let alpha: Double = 0.3 + 0.3 * Double(speed)
                let dashOn: CGFloat = 14 + 10 * speed
                let dashOff: CGFloat = 11 - 4 * speed
                let lineWidth: CGFloat = 3.5 + 2.5 * speed
                let flowRate: Double = 28 + 50 * Double(speed)

                for i in 0..<lines {
                    let fi: CGFloat = CGFloat(i) / CGFloat(lines - 1)
                    let x0: CGFloat = left + fi * fieldWidth
                    let swayPhase: Double = t * 1.5 * (0.6 + Double(speed)) + Double(i) * 0.9
                    let sway: CGFloat = CGFloat(sin(swayPhase)) * 5
                    let spread: CGFloat = (fi - 0.5) * 44 * spreadScale
                    let endX: CGFloat = x0 + spread + sway + sweep
                    let c1x: CGFloat = x0 + sweep * 0.25 + sway * 0.5
                    let c2x: CGFloat = x0 + spread * 0.7 + sweep * 0.7 - sway
                    var path = Path()
                    path.move(to: CGPoint(x: x0, y: 0))
                    path.addCurve(to: CGPoint(x: endX, y: reach),
                                  control1: CGPoint(x: c1x, y: reach * 0.35),
                                  control2: CGPoint(x: c2x, y: reach * 0.7))
                    let colors: [Color] = [tint.opacity(alpha), tint.opacity(alpha * 0.4), .clear]
                    let shading = GraphicsContext.Shading.linearGradient(
                        Gradient(colors: colors),
                        startPoint: .zero, endPoint: CGPoint(x: 0, y: reach))
                    let phase: CGFloat = CGFloat(-t * flowRate) + CGFloat(i) * 7
                    let style = StrokeStyle(lineWidth: lineWidth, lineCap: .round, dash: [dashOn, dashOff], dashPhase: phase)
                    g.stroke(path, with: shading, style: style)
                }
            }
        }
        .blur(radius: 1.4)
        .allowsHitTesting(false)
    }
}
