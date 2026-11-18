import CTagLib
import Foundation

public let audioExtensions: Set<String> = ["mp3", "flac", "m4a", "mp4", "aac", "wav", "aif", "aiff",
                                           "ogg", "opus"]

public struct FileTags: Sendable {
    public var title: String
    public var artist: String
    public var keyText: String?
    public var bpm: Double?
    public var duration: Double?
}

private func field<T>(_ tuple: T) -> String {
    withUnsafeBytes(of: tuple) { raw in
        let bytes = raw.bindMemory(to: CChar.self)
        return String(cString: bytes.baseAddress!).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Title, artist, key and BPM from the file's tags. Nil if the file can't be read.
public func readTags(_ url: URL) -> FileTags? {
    let info = ctag_read(url.path)
    guard info.ok != 0 else { return nil }
    let title = field(info.title)
    let key = field(info.key)
    return FileTags(title: title.isEmpty ? url.deletingPathExtension().lastPathComponent : title,
                    artist: field(info.artist),
                    keyText: key.isEmpty ? nil : key,
                    bpm: info.bpm > 0 ? info.bpm : nil,
                    duration: info.duration > 0 ? info.duration : nil)
}

/// Write key (traditional notation, e.g. "Am") and/or BPM into the file.
@discardableResult
public func writeTags(_ url: URL, key: CamelotKey?, bpm: Double?) -> Bool {
    ctag_write(url.path, key?.name, bpm ?? 0) != 0
}

/// Audio files in a folder (optionally recursive), sorted by path.
public func scanFolder(_ folder: URL, recursive: Bool = false) -> [URL] {
    let fm = FileManager.default
    let keys: [URLResourceKey] = [.isRegularFileKey]
    var urls: [URL] = []
    if recursive {
        let e = fm.enumerator(at: folder, includingPropertiesForKeys: keys,
                              options: [.skipsHiddenFiles])
        while let u = e?.nextObject() as? URL { urls.append(u) }
    } else {
        urls = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                            options: [.skipsHiddenFiles])) ?? []
    }
    return urls
        .filter { audioExtensions.contains($0.pathExtension.lowercased()) }
        .filter { !$0.pathComponents.contains("harmonized") }
        .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
}
