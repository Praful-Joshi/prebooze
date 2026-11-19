import Foundation

/// A Camelot key: number 1–12, letter "A" (minor) or "B" (major).
public struct CamelotKey: Hashable, Codable, Sendable, CustomStringConvertible {
    public let number: Int
    public let letter: Character

    public init(_ number: Int, _ letter: Character) {
        self.number = number
        self.letter = letter
    }

    public var description: String { "\(number)\(letter)" }
    public var isMinor: Bool { letter == "A" }

    /// Pitch class of the tonic (C = 0).
    public var tonicPitchClass: Int {
        let majorPC = mod((number - 8) * 7, 12)  // 8B = C, each step = a fifth
        return isMinor ? mod(majorPC - 3, 12) : majorPC
    }

    private static let majorNames = ["C", "Db", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]
    private static let minorNames = ["C", "C#", "D", "Eb", "E", "F", "F#", "G", "G#", "A", "Bb", "B"]

    /// Traditional name, e.g. "Am", "F#m", "Db".
    public var name: String {
        isMinor ? Self.minorNames[tonicPitchClass] + "m" : Self.majorNames[tonicPitchClass]
    }

    public static func fromPitchClass(_ pc: Int, minor: Bool) -> CamelotKey {
        let majorPC = minor ? mod(pc + 3, 12) : mod(pc, 12)
        let n = mod(8 + 7 * majorPC, 12)
        return CamelotKey(n == 0 ? 12 : n, minor ? "A" : "B")
    }

    /// From a Mixxx/Queen Mary ChromaticKey: 1–12 = C..B major, 13–24 = C..B minor.
    public static func fromChromatic(_ value: Int) -> CamelotKey? {
        switch value {
        case 1...12: return fromPitchClass(value - 1, minor: false)
        case 13...24: return fromPitchClass(value - 13, minor: true)
        default: return nil
        }
    }

    /// Shifted by `semitones` (keeps major/minor).
    public func transposed(_ semitones: Int) -> CamelotKey {
        CamelotKey.fromPitchClass(tonicPitchClass + semitones, minor: isMinor)
    }

    // Codable as "8A".
    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let k = parseKey(s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Bad key \(s)"))
        }
        self = k
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }
}

@inline(__always) func mod(_ a: Int, _ n: Int) -> Int { ((a % n) + n) % n }

private let notePC: [Character: Int] = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11]

/// Parse a key in Camelot/Lancelot ("8A"), Open Key ("1m"/"1d") or traditional
/// notation ("Am", "A minor", "C#m", "Dbmin", "F♯", "Ebmaj"). Nil if unrecognised.
public func parseKey(_ text: String?) -> CamelotKey? {
    guard let text, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
    // Taggers sometimes write two notations ("8A/Am", "Am - 8A").
    let normalised = text.replacingOccurrences(of: " - ", with: "/")
    for part in normalised.split(whereSeparator: { "/|,".contains($0) }) {
        if let k = parseSingle(part.trimmingCharacters(in: .whitespaces)) { return k }
    }
    return nil
}

private func parseSingle(_ s: String) -> CamelotKey? {
    guard !s.isEmpty else { return nil }
    let compact = s.replacingOccurrences(of: " ", with: "")
    // Camelot / Open Key: number followed by A/B or m/d.
    if let last = compact.last, let n = Int(compact.dropLast()), (1...12).contains(n) {
        switch last {
        case "A", "a": return CamelotKey(n, "A")
        case "B", "b": return CamelotKey(n, "B")
        case "m", "M": return CamelotKey(mod(n + 6, 12) + 1, "A")
        case "d", "D": return CamelotKey(mod(n + 6, 12) + 1, "B")
        default: break
        }
    }
    // Traditional notation.
    var chars = Array(s)
    guard let first = chars.first, let base = notePC[Character(first.uppercased())] else { return nil }
    chars.removeFirst()
    while chars.first == " " { chars.removeFirst() }
    var pc = base
    if let a = chars.first, "#♯b♭".contains(a) {
        pc += (a == "#" || a == "♯") ? 1 : -1
        chars.removeFirst()
    }
    while chars.first == " " { chars.removeFirst() }
    let qual = String(chars)
    let q = qual.lowercased()
    let minorWords = ["m", "min", "minor", "moll"]
    let majorWords = ["", "maj", "major", "dur"]
    guard minorWords.contains(q) || majorWords.contains(q) else { return nil }
    let minor = minorWords.contains(q) && qual != "M"
    return CamelotKey.fromPitchClass(mod(pc, 12), minor: minor)
}
