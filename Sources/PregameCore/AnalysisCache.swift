import CryptoKit
import Foundation

/// Shared, content-addressed analysis cache in
/// ~/Library/Application Support/Harmonizer/Analysis/<sha256>.{json,wave}.
/// A track analysed once is instant in every project, even after a move/rename.
public final class AnalysisCache: @unchecked Sendable {
    public static let shared = AnalysisCache()

    public let directory: URL
    private let lock = NSLock()
    private var memory: [String: TrackAnalysis] = [:]
    private var editsMemory: [String: TrackEdits] = [:]

    public init(directory: URL? = nil) {
        let base = directory ?? DataFolders.applicationSupport
            .appendingPathComponent("Analysis", isDirectory: true)
        self.directory = base
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    /// SHA-256 of the file's bytes (streamed).
    public static func contentHash(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public func cached(_ hash: String) -> TrackAnalysis? {
        lock.lock()
        if let hit = memory[hash] { lock.unlock(); return hit }
        lock.unlock()
        let url = directory.appendingPathComponent("\(hash).json")
        guard let data = try? Data(contentsOf: url),
              let a = try? JSONDecoder().decode(TrackAnalysis.self, from: data),
              a.version == analysisVersion else { return nil }
        lock.lock(); memory[hash] = a; lock.unlock()
        return a
    }

    public func waveform(_ hash: String) -> WaveformSummary? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("\(hash).wave")),
              data.count % 4 == 0 else { return nil }
        let n = data.count / 4
        let bytes = [UInt8](data)
        return WaveformSummary(peak: Array(bytes[0..<n]), low: Array(bytes[n..<(2 * n)]),
                               mid: Array(bytes[(2 * n)..<(3 * n)]), high: Array(bytes[(3 * n)...]))
    }

    public func store(_ hash: String, _ analysis: TrackAnalysis, _ wave: WaveformSummary) {
        lock.lock(); memory[hash] = analysis; lock.unlock()
        if let data = try? JSONEncoder().encode(analysis) {
            try? data.write(to: directory.appendingPathComponent("\(hash).json"), options: .atomic)
        }
        let blob = Data(wave.peak + wave.low + wave.mid + wave.high)
        try? blob.write(to: directory.appendingPathComponent("\(hash).wave"), options: .atomic)
    }

    // MARK: User edits (structure corrections, hot cues, bar 1)

    /// Edits survive re-analysis (they're not tied to `analysisVersion`).
    public func edits(_ hash: String) -> TrackEdits {
        lock.lock()
        if let hit = editsMemory[hash] { lock.unlock(); return hit }
        lock.unlock()
        let e = (try? Data(contentsOf: directory.appendingPathComponent("\(hash).edits.json")))
            .flatMap { try? JSONDecoder().decode(TrackEdits.self, from: $0) } ?? TrackEdits()
        lock.lock(); editsMemory[hash] = e; lock.unlock()
        return e
    }

    public func setEdits(_ hash: String, _ edits: TrackEdits) {
        lock.lock(); editsMemory[hash] = edits; lock.unlock()
        let url = directory.appendingPathComponent("\(hash).edits.json")
        if edits == TrackEdits() {
            try? FileManager.default.removeItem(at: url)
        } else if let data = try? JSONEncoder().encode(edits) {
            try? data.write(to: url, options: .atomic)
        }
        NotificationCenter.default.post(name: AnalysisCache.editsChanged, object: hash)
    }

    public static let editsChanged = Notification.Name("PregameEditsChanged")

    /// Cached result, or decode + analyse + store.
    public func analysis(for url: URL, hash: String) throws -> TrackAnalysis {
        if let hit = cached(hash) { return hit }
        let (a, w) = analyse(try decodeAudio(url))
        store(hash, a, w)
        return a
    }
}
