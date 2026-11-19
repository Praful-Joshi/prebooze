import AppKit
import PregameCore
import XCTest
@testable import PregameApp

/// The look is defined in one place (Sources/PregameApp/Design). These tests
/// keep colour out of every other file and keep the domain palette readable in
/// both appearances.
final class DesignTokenTests: XCTestCase {
    private static let appSources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/PregameApp")

    /// Colour literals, named SwiftUI/AppKit colours and system colours used directly.
    private static let forbidden: [NSRegularExpression] = [
        #"Color\((red|hue|white|nsColor|cgColor):"#,
        #"Color\(\.(sRGB|displayP3|sRGBLinear)"#,
        #"Color\(""#,
        #"NSColor\("#,
        #"NSColor\.\w+"#,
        #"CGColor\("#,
        #"#colorLiteral"#,
        #"Color\.(red|orange|yellow|green|mint|teal|cyan|blue|indigo|purple|pink|brown|gray|grey|white|black|accentColor)\b"#,
        #"(?<![\w)\]])\.(red|orange|yellow|green|mint|teal|cyan|blue|indigo|purple|pink|brown|gray|grey|white|black|accentColor)\b"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    func testNoColourOutsideTheDesignFolder() throws {
        let files = FileManager.default.enumerator(at: Self.appSources, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" && !$0.path.contains("/Design/") }
        XCTAssertFalse(files.isEmpty, "no app sources found at \(Self.appSources.path)")
        var hits: [String] = []
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (n, raw) in lines.enumerated() {
                let line = raw.components(separatedBy: "//").first ?? raw
                let range = NSRange(line.startIndex..., in: line)
                if Self.forbidden.contains(where: { $0.firstMatch(in: line, range: range) != nil }) {
                    hits.append("\(file.lastPathComponent):\(n + 1): \(raw.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        XCTAssert(hits.isEmpty, "Use Palette instead of colour literals:\n" + hits.joined(separator: "\n"))
    }

    // MARK: - Readability

    private let appearances: [NSAppearance.Name] = [.aqua, .darkAqua]

    /// Match words sit on a 15 % tint of their own colour over the window.
    func testMatchWordsAreReadableInBothAppearances() {
        for match in Match.allCases {
            for name in appearances {
                let fg = rgb(Palette.match(match), name)
                let bg = mix(fg, over: rgb(Palette.window, name), 0.15)
                XCTAssertGreaterThanOrEqual(contrast(fg, bg), 4.5, "\(match) in \(name.rawValue)")
            }
        }
    }

    /// Section names are drawn in dark text on the section fill.
    func testSectionNamesAreReadable() {
        for section in SectionLabel.allCases {
            for name in appearances {
                let fill = rgb(Palette.section(section), name)
                XCTAssertGreaterThanOrEqual(contrast(rgb(Palette.onSection, name), fill), 4.5, "\(section) in \(name.rawValue)")
            }
        }
    }

    /// Cue numerals on the flag, and lane lines on the editor canvas (3:1 for graphics).
    func testCuesAndLaneLinesStandOut() {
        for name in appearances {
            XCTAssertGreaterThanOrEqual(contrast(rgb(Palette.onCue, name), rgb(Palette.cue, name)), 4.5, "cue in \(name.rawValue)")
            let canvas = rgb(Palette.canvas, name)
            XCTAssertGreaterThanOrEqual(contrast(rgb(Palette.cue, name), canvas), 3, "cue line in \(name.rawValue)")
            XCTAssertGreaterThanOrEqual(contrast(rgb(Palette.block, name), canvas), 1.15, "block vs canvas in \(name.rawValue)")
            XCTAssertGreaterThanOrEqual(contrast(rgb(Palette.outgoing, name), canvas), 3, "outgoing in \(name.rawValue)")
            XCTAssertGreaterThanOrEqual(contrast(rgb(Palette.incoming, name), canvas), 3, "incoming in \(name.rawValue)")
            XCTAssertGreaterThanOrEqual(contrast(rgb(Palette.playhead, name), canvas), 4.5, "playhead in \(name.rawValue)")
        }
    }

    /// Cues used to share orange with the outgoing track; they must stay apart.
    func testCueIsNotTheOutgoingColour() {
        for name in appearances {
            XCTAssertGreaterThan(hueDistance(rgb(Palette.cue, name), rgb(Palette.outgoing, name)), 20, name.rawValue)
        }
    }

    func testAccentIsNotYellow() {
        for name in appearances {
            let h = hue(rgb(Palette.accent, name))
            XCTAssertFalse((40...70).contains(h), "accent hue \(h) in \(name.rawValue)")
        }
    }

    /// The key pill's colour edge shows up (3:1 for graphics) against the window for all 24 keys.
    func testEveryKeyEdgeIsVisible() {
        for name in appearances {
            let bg = rgb(Palette.window, name)
            for n in 1...12 {
                for letter: Character in ["A", "B"] {
                    let k = CamelotKey(n, letter)
                    XCTAssertGreaterThanOrEqual(contrast(rgb(Palette.key(k), name), bg), 3, "\(k) in \(name.rawValue)")
                }
            }
        }
    }

    // MARK: - Colour maths

    private typealias RGB = (r: Double, g: Double, b: Double)

    private func rgb(_ colour: NSColor, _ name: NSAppearance.Name) -> RGB {
        var out: RGB = (0, 0, 0)
        NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
            let c = colour.usingColorSpace(.sRGB)!
            out = (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
        }
        return out
    }

    private func mix(_ a: RGB, over b: RGB, _ t: Double) -> RGB {
        (a.r * t + b.r * (1 - t), a.g * t + b.g * (1 - t), a.b * t + b.b * (1 - t))
    }

    private func luminance(_ c: RGB) -> Double {
        func lin(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
    }

    private func contrast(_ a: RGB, _ b: RGB) -> Double {
        let (l1, l2) = (luminance(a), luminance(b))
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    private func hue(_ c: RGB) -> Double {
        var h: CGFloat = 0
        NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1).getHue(&h, saturation: nil, brightness: nil, alpha: nil)
        return Double(h) * 360
    }

    private func hueDistance(_ a: RGB, _ b: RGB) -> Double {
        let d = abs(hue(a) - hue(b)).truncatingRemainder(dividingBy: 360)
        return min(d, 360 - d)
    }
}
