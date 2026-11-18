import Foundation

// MARK: - CSV

enum CSV {
    static func escape(_ s: String) -> String {
        s.contains(where: { ",\"\n\r".contains($0) })
            ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
    }

    static func write(header: [String], rows: [[String]]) -> String {
        ([header] + rows).map { $0.map(escape).joined(separator: ",") }.joined(separator: "\n") + "\n"
    }

    /// RFC 4180 parser; returns rows as header → value dictionaries.
    static func parse(_ text: String) -> [[String: String]] {
        var rows: [[String]] = [], row: [String] = [], field = ""
        var quoted = false
        var chars = Array(text)
        if chars.first == "\u{FEFF}" { chars.removeFirst() }
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if quoted {
                if c == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" { field.append("\""); i += 1 } else { quoted = false }
                } else { field.append(c) }
            } else if c == "\"" { quoted = true }
            else if c == "," { row.append(field); field = "" }
            else if c == "\n" || c == "\r" {
                if c == "\r" && i + 1 < chars.count && chars[i + 1] == "\n" { i += 1 }
                row.append(field); rows.append(row); row = []; field = ""
            } else { field.append(c) }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        guard let header = rows.first else { return [] }
        return rows.dropFirst().filter { $0.count > 1 || $0.first?.isEmpty == false }.map { r in
            Dictionary(uniqueKeysWithValues: header.enumerated().map { ($1, $0 < r.count ? r[$0] : "") })
        }
    }
}

private func fmt(_ v: Double?, _ digits: Int = 2) -> String {
    guard let v else { return "" }
    let s = String(format: "%.\(digits)f", v)
    var t = s
    while t.contains(".") && (t.hasSuffix("0") || t.hasSuffix(".")) { t.removeLast() }
    return t
}

private func fmtDuration(_ secs: Double?) -> String {
    guard let secs, secs > 0 else { return "" }
    let s = Int(secs.rounded())
    return "\(s / 60):" + String(format: "%02d", s % 60)
}

extension MixProject {
    /// Every track in mix order with key/BPM and the transition to the next one.
    public func csv() -> String {
        let header = ["position", "locked", "title", "artist", "filename", "path", "duration",
                      "key_detected", "key_used", "key_name", "bpm_detected", "bpm_used",
                      "overridden", "transition_to_next", "transition_colour",
                      "bpm_delta_to_next", "cost_to_next"]
        let inc = included
        let ts = Dictionary(uniqueKeysWithValues: transitions().map { ($0.from, $0) })
        let rows = inc.enumerated().map { i, t -> [String] in
            let tr = ts[t.id]
            let locked = t.id == settings.lockFirst ? "first" : t.id == settings.lockLast ? "last" : ""
            return ["\(i + 1)", locked, t.title, t.artist, t.filename, t.path, fmtDuration(t.duration),
                    t.detectedKey?.description ?? "", t.key?.description ?? "", t.key?.name ?? "",
                    fmt(t.detectedBpm), fmt(t.bpm), t.isOverridden ? "yes" : "no",
                    tr?.label.label ?? "", tr?.label.colour.rawValue ?? "",
                    tr.map { fmt($0.bpmDelta) } ?? "", tr.map { fmt($0.cost, 3) } ?? ""]
        }
        return CSV.write(header: header, rows: rows)
    }

    /// Extended M3U playlist in mix order (absolute paths).
    public func m3u8() -> String {
        (["#EXTM3U"] + included.flatMap { ["#EXTINF:\(Int($0.duration ?? -1)),\($0.displayName)", $0.path] })
            .joined(separator: "\n") + "\n"
    }
}

// MARK: - Importing a run from the old web Harmonizer

public enum ImportError: Error, LocalizedError {
    case notARun(URL)
    public var errorDescription: String? {
        switch self {
        case let .notARun(url): "\(url.lastPathComponent) has no reordered.csv: pick a Harmonize run folder."
        }
    }
}

extension MixProject {
    /// Build a project from an old `<set>/harmonized/<run>/` folder: its order,
    /// key/BPM overrides, settings, and the set's transition tweaks.
    public static func importRun(_ runFolder: URL) throws -> MixProject {
        let csvURL = runFolder.appendingPathComponent("reordered.csv")
        guard let text = try? String(contentsOf: csvURL, encoding: .utf8) else {
            throw ImportError.notARun(runFolder)
        }
        var project = MixProject()
        for row in CSV.parse(text) {
            guard let path = row["path"], !path.isEmpty else { continue }
            var t = FileManager.default.fileExists(atPath: path)
                ? ProjectTrack.from(URL(fileURLWithPath: path))
                : ProjectTrack(path: path, title: row["title"] ?? "", artist: row["artist"] ?? "")
            let detectedKey = parseKey(row["key_detected"])
            let usedKey = parseKey(row["key_used"])
            let detectedBpm = Double(row["bpm_detected"] ?? "")
            let usedBpm = Double(row["bpm_used"] ?? "")
            if t.tagKey == nil { t.tagKey = detectedKey }
            if t.tagBpm == nil { t.tagBpm = detectedBpm }
            if let usedKey, usedKey != detectedKey { t.keyOverride = usedKey }
            if let usedBpm, let detectedBpm, abs(usedBpm - detectedBpm) > 0.005 { t.bpmOverride = usedBpm }
            if row["locked"] == "first" { project.settings.lockFirst = t.id }
            if row["locked"] == "last" { project.settings.lockLast = t.id }
            project.tracks.append(t)
        }
        if let data = try? Data(contentsOf: runFolder.appendingPathComponent("settings.json")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let s = json["settings"] as? [String: Any] {
            if let m = s["mode"] as? String, let mode = MixMode(rawValue: m) { project.settings.mode = mode }
            if let v = s["key_bpm_slider"] as? Double { project.settings.keyBpmSlider = v }
            if let v = s["bpm_tolerance"] as? Double { project.settings.bpmTolerance = v }
            if let d = s["tempo_direction"] as? String, let dir = TempoDirection(rawValue: d) {
                project.settings.tempoDirection = dir
            }
            if let v = s["half_double"] as? Bool { project.settings.halfDouble = v }
            if let v = s["time_budget_s"] as? Double { project.settings.timeBudget = v }
            if let v = s["seed"] as? Int { project.settings.seed = UInt64(max(v, 0)) }
        }
        // Transition tweaks live one level up, in <set>/harmonized/transitions.json.
        let tweaks = runFolder.deletingLastPathComponent().appendingPathComponent("transitions.json")
        if let data = try? Data(contentsOf: tweaks),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for (key, value) in json {
                if let d = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
                   let s = String(data: d, encoding: .utf8) {
                    project.importedTransitions[key] = s
                }
            }
        }
        return project
    }
}
