import AVFoundation
import Foundation

/// Separated stems on disk, by the file's content hash:
/// Application Support/Pregame/Stems/<hash>/{drums,bass,vocals}.m4a
/// (AAC, 44.1 kHz). Melody isn't stored: it is the track minus the other three,
/// so the four always add up to the original exactly. The least recently used
/// tracks are removed when the cache grows past its cap.
public final class StemCache: @unchecked Sendable {
    public static let shared = StemCache()

    /// Stored stems (melody is derived).
    public static let stored: [StemKind] = [.drums, .bass, .vocals]
    public static let defaultCapBytes: Int64 = 10 * 1024 * 1024 * 1024
    public static let capKey = "stemCacheCapBytes"

    public let directory: URL
    private let lock = NSLock()

    public struct Entry: Codable, Sendable {
        public var bytes: Int64
        public var lastUsed: Date
        public var title: String?
    }

    public init(directory: URL? = nil) {
        self.directory = directory ?? DataFolders.applicationSupport
            .appendingPathComponent("Stems", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    public var capBytes: Int64 {
        get {
            let v = UserDefaults.standard.object(forKey: StemCache.capKey) as? Int64
            return v ?? StemCache.defaultCapBytes
        }
        set { UserDefaults.standard.set(newValue, forKey: StemCache.capKey); enforceCap() }
    }

    private var indexURL: URL { directory.appendingPathComponent("index.json") }

    public func index() -> [String: Entry] {
        lock.lock(); defer { lock.unlock() }
        return readIndex()
    }

    private func readIndex() -> [String: Entry] {
        guard let d = try? Data(contentsOf: indexURL) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([String: Entry].self, from: d)) ?? [:]
    }

    private func writeIndex(_ idx: [String: Entry]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(idx).write(to: indexURL, options: .atomic)
    }

    public func folder(_ hash: String) -> URL { directory.appendingPathComponent(hash, isDirectory: true) }

    public func url(_ hash: String, _ stem: StemKind) -> URL {
        folder(hash).appendingPathComponent("\(stem.fileName).m4a")
    }

    public func has(_ hash: String) -> Bool {
        StemCache.stored.allSatisfy { FileManager.default.fileExists(atPath: url(hash, $0).path) }
    }

    public var totalBytes: Int64 { index().values.reduce(0) { $0 + $1.bytes } }

    /// Mark as used now (keeps it from being evicted first).
    public func touch(_ hash: String) {
        lock.lock(); defer { lock.unlock() }
        var idx = readIndex()
        guard idx[hash] != nil else { return }
        idx[hash]?.lastUsed = Date()
        writeIndex(idx)
    }

    /// Store separated stems (44.1 kHz, [stem][channel][frame], model order).
    public func store(_ hash: String, stems: [[[Float]]], title: String? = nil) throws {
        let dir = folder(hash)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var bytes: Int64 = 0
        for kind in StemCache.stored {
            let u = url(hash, kind)
            try StemCache.writeAAC(u, left: stems[kind.rawValue][0], right: stems[kind.rawValue][1])
            bytes += (try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? Int64) ?? 0
        }
        lock.lock()
        var idx = readIndex()
        idx[hash] = Entry(bytes: bytes, lastUsed: Date(), title: title)
        writeIndex(idx)
        lock.unlock()
        enforceCap(keeping: hash)
    }

    public func remove(_ hash: String) {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: folder(hash))
        var idx = readIndex()
        idx[hash] = nil
        writeIndex(idx)
    }

    public func removeAll() {
        for h in index().keys { remove(h) }
    }

    /// Drop least recently used tracks until under the cap (never `keeping`).
    public func enforceCap(keeping: String? = nil) {
        let cap = capBytes
        var idx = index()
        var total = idx.values.reduce(0) { $0 + $1.bytes }
        for (h, _) in idx.sorted(by: { $0.value.lastUsed < $1.value.lastUsed }) where total > cap && h != keeping {
            total -= idx[h]?.bytes ?? 0
            idx[h] = nil
            remove(h)
        }
    }

    static func writeAAC(_ url: URL, left: [Float], right: [Float]) throws {
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: StemSeparator.sampleRate,
                                       AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000]
        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        let block = 1 << 16
        var pos = 0
        while pos < left.count {
            let n = min(block, left.count - pos)
            let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
            buf.frameLength = AVAudioFrameCount(n)
            left.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress! + pos, count: n) }
            right.withUnsafeBufferPointer { buf.floatChannelData![1].update(from: $0.baseAddress! + pos, count: n) }
            try file.write(from: buf)
            pos += n
        }
    }
}

extension StemCache {
    /// A song's full mix and its four stems at 44.1 kHz, for a STEM file:
    /// melody is the mix minus the other three, so they always add up.
    public func stemFileAudio(source url: URL, hash: String) throws -> (mix: [[Float]], stems: [[[Float]]]) {
        let mix = try decodeAudio(url, sampleRate: StemSeparator.sampleRate)
        let n = mix.frames
        func fit(_ x: [Float]) -> [Float] { x.count >= n ? Array(x[0..<n]) : x + [Float](repeating: 0, count: n - x.count) }
        let stored = try StemCache.stored.map { kind -> [[Float]] in
            let a = try decodeAudio(self.url(hash, kind), sampleRate: StemSeparator.sampleRate)
            return [fit(a.left), fit(a.right)]
        }
        let (drums, bass, vocals) = (stored[0], stored[1], stored[2])
        let melody = (0..<2).map { c in
            let full = c == 0 ? mix.left : mix.right
            return (0..<n).map { full[$0] - drums[c][$0] - bass[c][$0] - vocals[c][$0] }
        }
        return ([mix.left, mix.right], [drums, bass, melody, vocals])
    }

    /// File name for a song's STEM file ("Artist - Title.stem.mp4").
    public static func stemFileName(title: String, artist: String) -> String {
        let base = artist.isEmpty ? title : "\(artist) - \(title)"
        let clean = base.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return clean + ".stem.mp4"
    }
}

extension StemCache {
    /// 32-bit float WAV (tests, debugging).
    static func writeWAV(_ url: URL, left: [Float], right: [Float], sampleRate: Double) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(left.count))!
        buf.frameLength = AVAudioFrameCount(left.count)
        left.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: left.count) }
        right.withUnsafeBufferPointer { buf.floatChannelData![1].update(from: $0.baseAddress!, count: right.count) }
        try file.write(from: buf)
    }
}
