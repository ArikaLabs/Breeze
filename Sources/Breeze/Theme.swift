import SwiftUI
import AppKit

/// Arika Labs house style. Travertine by day (beige stone, black accents), Basalt by night
/// (warm black stone, beige accents). No neutral greys: every neutral leans toward beige.
/// Colours follow the system appearance; each token carries both values.
enum Theme {
    // Surfaces
    static let surface = dynamic("#e7ded4", "#130f0a")          // page ground; carries the stone
    static let surfaceRaised = dynamic("#f1ebe2", "#1e1812")    // tiles, cards, keys: things that sit on the ground
    static let surfaceSunken = dynamic("#dcd3c9", "#0b0805")    // slider track, wells: pressed into the stone
    static let surfaceSelected = dynamic("#d4cbc0", "#2f261b")  // hover and selected states
    static let line = dynamic("#cfc6bb", "#352c22")             // hairlines
    static let lineStrong = dynamic("#7c7368", "#83715b")       // control borders, inactive dots
    // Ink
    static let ink = dynamic("#1c1916", "#e6d9c5")
    static let inkMuted = dynamic("#5b5046", "#b7a58c")
    static let primary = dynamic("#1c1916", "#e6d9c5")          // the one accent: black on Travertine, beige on Basalt
    static let onPrimary = dynamic("#f1ebe2", "#130f0a")
    // Status, always paired with a word or icon
    static let success = dynamic("#355e41", "#93c3a1")          // moss
    static let warning = dynamic("#6f510b", "#d9b266")          // ochre
    static let danger = dynamic("#93361f", "#e8907c")           // rust
    // Air: the only other hues, and only for what the unit is doing
    static let cool = dynamic("#5f88a8", "#a9c4da")
    static let heat = dynamic("#b5593b", "#e8907c")
    // Light catching an object's edge, and the warm shadow it casts
    static let edge = dynamic("#fffdf89e", "#fff0dc12")
    static let popoverEdge = dynamic("#4a3a2824", "#fff0dc38")  // the hairline that keeps the panel off a desktop of the same stone
    static let shadow = dynamic("#4a3a2838", "#00000099")

    static let corner: CGFloat = 14      // radius-lg: cards, tiles, panels
    static let width: CGFloat = 372

    /// A colour that resolves against the current appearance.
    private static func dynamic(_ light: String, _ dark: String) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }

    /// The honed limestone behind every Arika Labs surface, re-coloured for each theme. Shipped in
    /// the app bundle; when absent (a bare binary) the ground is plain `surface`.
    static func stone(dark: Bool) -> NSImage? { dark ? stoneDark : stoneLight }
    private static let stoneLight = loadStone("stone-light")
    private static let stoneDark = loadStone("stone-dark")
    private static func loadStone(_ name: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "jpg"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.size = NSSize(width: 960, height: 960)   // tile pitch in points; the 2048 px scan stays sharp on Retina
        return image
    }
}

extension NSColor {
    /// "#rrggbb" or "#rrggbbaa".
    convenience init(hex: String) {
        var s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        if s.count == 6 { s += "ff" }
        let v = UInt32(s, radix: 16) ?? 0
        self.init(srgbRed: CGFloat((v >> 24) & 0xff) / 255, green: CGFloat((v >> 16) & 0xff) / 255,
                  blue: CGFloat((v >> 8) & 0xff) / 255, alpha: CGFloat(v & 0xff) / 255)
    }
}

/// The page ground: stone, never a flat grey.
struct StoneGround: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            Theme.surface
            if let stone = Theme.stone(dark: scheme == .dark) {
                // The scan at full strength reads as dirt; at four tenths it reads as stone.
                Image(nsImage: stone).resizable(resizingMode: .tile).opacity(0.4)
            }
        }
        .ignoresSafeArea()
    }
}

/// A stone key or card standing off the ground: a light edge and a short warm shadow, no border.
struct Raised<S: InsettableShape>: ViewModifier {
    let shape: S
    let fill: Color

    func body(content: Content) -> some View {
        content
            .background(fill, in: shape)
            .overlay(shape.strokeBorder(Theme.edge, lineWidth: 1))
            .shadow(color: Theme.shadow, radius: 5, y: 2)
    }
}

extension View {
    func raised<S: InsettableShape>(_ shape: S, fill: Color = Theme.surfaceRaised) -> some View {
        modifier(Raised(shape: shape, fill: fill))
    }
}

struct RootView: View {
    @EnvironmentObject var store: DeviceStore

    var body: some View {
        Group {
            if store.isConfigured && !store.showSetup {
                ControlPanelView()
            } else {
                SetupFlowView()
            }
        }
        .frame(width: Theme.width)
        .background(StoneGround())
    }
}
