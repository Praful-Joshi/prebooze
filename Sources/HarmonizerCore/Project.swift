import Foundation

/// One track in a mix project: a reference to an audio file plus per-project edits.
public struct ProjectTrack: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var path: String
    public var contentHash: String?
    public var title: String
    public var artist: String
    public var duration: Double?
    /// From the file's tags (e.g. written by Mixxx or Rekordbox), if any.
    public var tagKey: CamelotKey?
    public var tagBpm: Double?
    /// From Harmonizer's own analysis.
    public var analysedKey: CamelotKey?
    public var analysedBpm: Double?
    public var keyOverride: CamelotKey?
    public var bpmOverride: Double?
    public var include = true
    /// Loudness trim on top of automatic level matching.
    public var trimDb: Double?
    /// Pitch shift in semitones (−6…+6), stored only when set.
    public var pitchShift: Int?
    /// Repeats of the first bars (intro) / of the outro's first bars.
    public var introLoop: TrackLoop?
    public var outroLoop: TrackLoop?

    public init(path: String, title: String, artist: String) {
        self.path = path
        self.title = title
        self.artist = artist
    }

    public var url: URL { URL(fileURLWithPath: path) }
    public var filename: String { (path as NSString).lastPathComponent }
    public var displayName: String { artist.isEmpty ? title : "\(artist) - \(title)" }

    /// What the detectors found: own analysis first, then tags.
    public var detectedKey: CamelotKey? { analysedKey ?? tagKey }
    public var detectedBpm: Double? { analysedBpm ?? tagBpm }
    /// The file's key: override, else detected.
    public var baseKey: CamelotKey? { keyOverride ?? detectedKey }
    /// What ordering and mixing use: the base key moved by the key shift.
    public var key: CamelotKey? { baseKey?.transposed(keyShift) }
    public var keyShift: Int {
        get { pitchShift ?? 0 }
        set { pitchShift = newValue == 0 ? nil : max(-6, min(6, newValue)) }
    }
    public var bpm: Double? { bpmOverride ?? detectedBpm }
    public var isOverridden: Bool { keyOverride != nil || bpmOverride != nil }
}

/// A loop: `bars` bars played `repeats` extra times.
public struct TrackLoop: Codable, Hashable, Sendable {
    public var bars: Int
    public var repeats: Int

    public init(bars: Int, repeats: Int = 1) {
        self.bars = bars
        self.repeats = repeats
    }

    public static let barChoices = [1, 2, 4, 8, 16]
    public var extraBars: Int { bars * repeats }
}

public struct HarmonizeRunInfo: Codable, Equatable, Sendable {
    public var date: Date
    public var method: String
    public var cost: Double
    public var hitTimeLimit: Bool
}

/// A mix project (.hmix): track list in mix order, settings, and later the
/// transitions. Audio files are referenced, never copied.
public struct MixProject: Codable, Equatable, Sendable {
    public var formatVersion = 1
    public var tracks: [ProjectTrack] = []
    public var settings = HarmonizeSettings.defaults()
    public var lastRun: HarmonizeRunInfo?
    /// Transition tweaks imported from the old web Harmonizer (per pair key
    /// "outPath → inPath"), converted on first use.
    public var importedTransitions: [String: String] = [:]
    /// Edited transitions, per pair ("fromID>toID"); unedited pairs use the automatic preset.
    public var transitions: [String: TransitionSpec] = [:]
    public var transitionDefaults = TransitionDefaults()

    public init() {}

    enum CodingKeys: String, CodingKey {
        case formatVersion, tracks, settings, lastRun, importedTransitions, transitions, transitionDefaults
    }

    // Newer fields are optional on disk so older .hmix files still open.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try c.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
        tracks = try c.decodeIfPresent([ProjectTrack].self, forKey: .tracks) ?? []
        settings = try c.decodeIfPresent(HarmonizeSettings.self, forKey: .settings) ?? .defaults()
        lastRun = try c.decodeIfPresent(HarmonizeRunInfo.self, forKey: .lastRun)
        importedTransitions = try c.decodeIfPresent([String: String].self, forKey: .importedTransitions) ?? [:]
        transitions = try c.decodeIfPresent([String: TransitionSpec].self, forKey: .transitions) ?? [:]
        transitionDefaults = try c.decodeIfPresent(TransitionDefaults.self, forKey: .transitionDefaults)
            ?? TransitionDefaults()
        // Saved before mix-on modes: transitions placed by hand keep mixing on bars.
        struct Probe: Decodable { let mixOn: MixOnMode? }
        if (try? c.decodeIfPresent(Probe.self, forKey: .transitionDefaults))??.mixOn == nil {
            for (k, t) in transitions where t.mixOn == nil && (t.outNudge != 0 || t.inNudge != 0) {
                transitions[k]?.mixOn = .bars
            }
        }
    }

    public var included: [ProjectTrack] { tracks.filter(\.include) }

    public func index(of id: UUID?) -> Int? {
        guard let id else { return nil }
        return tracks.firstIndex { $0.id == id }
    }
}

// MARK: - Adding & analysing tracks

extension ProjectTrack {
    /// Track from a file: tags are read immediately, analysis comes later.
    public static func from(_ url: URL) -> ProjectTrack {
        let tags = readTags(url)
        var t = ProjectTrack(path: url.path,
                             title: tags?.title ?? url.deletingPathExtension().lastPathComponent,
                             artist: tags?.artist ?? "")
        t.duration = tags?.duration
        t.tagKey = parseKey(tags?.keyText)
        t.tagBpm = tags?.bpm
        return t
    }

    public mutating func apply(_ analysis: TrackAnalysis, hash: String) {
        contentHash = hash
        analysedKey = analysis.key
        analysedBpm = analysis.bpm
        duration = analysis.duration
    }
}

// MARK: - .hmix file format

extension MixProject {
    /// The project as written to a .hmix file (pretty JSON, ISO-8601 dates).
    public func fileData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    /// Read a .hmix file (also accepts numeric dates from early builds).
    public static func fromFileData(_ data: Data) throws -> MixProject {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { d in
            let c = try d.singleValueContainer()
            if let s = try? c.decode(String.self), let date = ISO8601DateFormatter().date(from: s) { return date }
            return Date(timeIntervalSinceReferenceDate: try c.decode(Double.self))
        }
        return try decoder.decode(MixProject.self, from: data)
    }
}
