import AppKit
import PregameCore
import SwiftUI

/// Every colour in the app. Surfaces and text are macOS semantic colours; the
/// brand accent and the domain palette are ours, each with a Light and a Dark value.
/// Nothing outside `Design/` names a colour (enforced by DesignTokenTests).
enum Palette {
    // MARK: Brand

    /// "Afterglow". Chrome only (buttons, selection, toggles, focus, progress, coach
    /// marks, the countdown ring); never used for data.
    static let accent = dynamic(light: 0xC8217A, dark: 0xFF4FA8)
    static let onAccent = NSColor.white

    // MARK: Surfaces and ink

    static let window = NSColor.windowBackgroundColor
    /// Timeline and editor canvases. Not underPageBackgroundColor: that is mid-grey
    /// in Light mode, where neither lanes nor waveforms read on it.
    static let canvas = dynamic(light: 0xF2F2F4, dark: 0x282828)
    /// A Track's block on the timeline.
    static let block = dynamic(light: 0xD9D9DE, dark: 0x333336)
    /// Strong foreground on a canvas: block titles, outlines and overlays (used at opacities).
    static let onCanvas = dynamic(light: 0x1A1A1A, dark: 0xFFFFFF)
    /// Darkens what isn't playing (used at opacities).
    static let shade = dynamic(light: 0xFFFFFF, dark: 0x000000)
    static let playhead = NSColor.labelColor
    static let shadow = NSColor.shadowColor
    /// Floating labels on a canvas (beat readouts, the bar tooltip).
    static let badge = dynamic(light: 0x1E1E1E, dark: 0x0A0A0A)
    static let onBadge = NSColor.white

    // MARK: Match

    // Tuned to stay readable on both macOS 15's window colour (#ECECEC / #323232)
    // and macOS 26's (#FFFFFF / #1E1E1E); CI checks both.

    static func match(_ m: Match) -> NSColor {
        switch m {
        case .smooth: dynamic(light: 0x116B2C, dark: 0x34D36B)
        case .energyUp: dynamic(light: 0x954400, dark: 0xFF9F0A)
        case .energyDown: dynamic(light: 0x075F79, dark: 0x45C9E2)
        case .keyChange: dynamic(light: 0x463DC9, dark: 0xADA9FF)
        case .clash: dynamic(light: 0xB20017, dark: 0xFF938D)
        }
    }

    static func symbol(_ m: Match) -> String {
        switch m {
        case .smooth: "checkmark"
        case .energyUp: "arrow.up.right"
        case .energyDown: "arrow.down.right"
        case .keyChange: "music.note"
        case .clash: "exclamationmark.triangle.fill"
        }
    }

    /// The old harmonic colour, shown until Match labels replace it (#16).
    static func legacyMatch(_ c: TransitionColour) -> NSColor {
        switch c {
        case .green: match(.smooth)
        case .yellow: match(.energyUp)
        case .blue: match(.keyChange)
        case .red: match(.clash)
        }
    }

    // MARK: Transition lanes and cues

    static let outgoing = dynamic(light: 0xB85400, dark: 0xFF9330)
    static let incoming = dynamic(light: 0x1A62CC, dark: 0x5AA8FF)
    static let cue = dynamic(light: 0x9C7F00, dark: 0xFFD60A)   // deep gold in Light: plain yellow vanishes on white
    static let onCue = NSColor(hex: 0x1D1600)

    // MARK: Sections

    static func section(_ s: SectionLabel) -> NSColor {
        switch s {
        case .intro: NSColor(hex: 0x3E9E97)
        case .build: NSColor(hex: 0xE0B13C)
        case .drop: NSColor(hex: 0xE5606F)
        case .breakdown: NSColor(hex: 0x7F8AEB)
        case .outro: NSColor(hex: 0x86AB78)
        }
    }

    static let onSection = NSColor(hex: 0x141414)

    // MARK: Keys

    /// Camelot wheel: number → hue. Minor (A) deeper, major (B) lighter; Light mode
    /// darkens each hue so the thin pill edge still shows against a light sidebar.
    static func key(_ k: CamelotKey) -> NSColor {
        let h = CGFloat((k.number - 1) % 12) / 12, minor = k.isMinor
        return NSColor(name: nil) { ap in
            isDark(ap)
                ? NSColor(hue: h, saturation: minor ? 0.55 : 0.45, brightness: minor ? 0.95 : 1, alpha: 1)
                : NSColor(hue: h, saturation: minor ? 0.85 : 0.7, brightness: minor ? 0.52 : 0.54, alpha: 1)
        }
    }

    // MARK: Status

    /// A value the host set by hand (key or BPM override).
    static let overridden = match(.energyUp)
    static let missing = match(.clash)
    static let warning = match(.energyUp)
    static let success = match(.smooth)
    static let error = match(.clash)

    // MARK: Waveform

    /// Three-band colouring: low → red, mid → green, high → blue, mixed by energy.
    /// Light mode darkens the result to keep contrast on a light block. Called per
    /// pixel column, so it returns a plain colour: pass the canvas's appearance
    /// (`ctx.environment.colorScheme == .dark`) instead of resolving one per column.
    static func waveform(low: Double, mid: Double, high: Double, dark: Bool) -> Color {
        let total = max(low + mid + high, 1e-9)
        let k = dark ? 1 : 0.72
        return Color(.sRGB, red: min(1, low / total * 1.6) * k, green: min(1, mid / total * 1.4) * k,
                     blue: min(1, high / total * 2.2) * k)
    }

    // MARK: - Helpers

    static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { isDark($0) ? NSColor(hex: dark) : NSColor(hex: light) }
    }

    private static func isDark(_ ap: NSAppearance) -> Bool {
        ap.bestMatch(from: [.darkAqua, .aqua, .accessibilityHighContrastDarkAqua, .accessibilityHighContrastAqua])
            .map { $0 == .darkAqua || $0 == .accessibilityHighContrastDarkAqua } ?? false
    }
}

extension NSColor {
    fileprivate convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// SwiftUI access: `.foregroundStyle(Ink.accent)`, `ctx.fill(…, with: .color(Ink.cue))`.
enum Ink {
    static let accent = Color(nsColor: Palette.accent)
    static let onAccent = Color(nsColor: Palette.onAccent)
    static let canvas = Color(nsColor: Palette.canvas)
    static let block = Color(nsColor: Palette.block)
    static let onCanvas = Color(nsColor: Palette.onCanvas)
    static let shade = Color(nsColor: Palette.shade)
    static let playhead = Color(nsColor: Palette.playhead)
    static let shadow = Color(nsColor: Palette.shadow)
    static let badge = Color(nsColor: Palette.badge)
    static let onBadge = Color(nsColor: Palette.onBadge)
    static let outgoing = Color(nsColor: Palette.outgoing)
    static let incoming = Color(nsColor: Palette.incoming)
    static let cue = Color(nsColor: Palette.cue)
    static let onCue = Color(nsColor: Palette.onCue)
    static let onSection = Color(nsColor: Palette.onSection)
    static let overridden = Color(nsColor: Palette.overridden)
    static let missing = Color(nsColor: Palette.missing)
    static let warning = Color(nsColor: Palette.warning)
    static let success = Color(nsColor: Palette.success)
    static let error = Color(nsColor: Palette.error)

    static func match(_ m: Match) -> Color { Color(nsColor: Palette.match(m)) }
    static func legacyMatch(_ c: TransitionColour) -> Color { Color(nsColor: Palette.legacyMatch(c)) }
    static func section(_ s: SectionLabel) -> Color { Color(nsColor: Palette.section(s)) }
    static func key(_ k: CamelotKey?) -> Color {
        guard let k else { return Color(nsColor: .tertiaryLabelColor) }
        return Color(nsColor: Palette.key(k))
    }
}
