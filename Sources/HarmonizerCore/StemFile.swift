import AVFoundation
import Foundation

/// Native Instruments STEM files (`.stem.mp4`), as Mixxx 2.6+ and Traktor read
/// them: five stereo AAC tracks — the full mix first, then drums, bass,
/// melody, vocals — plus a JSON manifest in `moov/udta/stem` naming and
/// colouring the stems. Only the full mix is marked enabled, so ordinary
/// players play just that.
public enum StemFile {
    public static let names = ["Drums", "Bass", "Melody", "Vocals"]
    public static let colours = ["#fd4a4a", "#ffff00", "#00e8e8", "#ad65ff"]

    public struct Tags: Sendable {
        public var title: String
        public var artist: String
        public init(title: String, artist: String) { self.title = title; self.artist = artist }
    }

    /// The manifest Mixxx/Traktor read (mastering DSP off: the mix plays as is).
    static func manifest() -> Data {
        let stems = zip(names, colours).map { ["name": $0, "color": $1] }
        let json: [String: Any] = [
            "version": 1,
            "stems": stems,
            "mastering_dsp": [
                "compressor": ["enabled": false, "ratio": 3, "output_gain": 0.5, "threshold": 0, "attack": 0.003,
                               "input_gain": 0.5, "release": 0.3, "hp_cutoff": 300, "dry_wet": 50],
                "limiter": ["enabled": false, "release": 0.05, "threshold": 0, "ceiling": -0.35],
            ],
        ]
        return try! JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
    }

    /// Write a STEM file. `mix` and each of the four `stems` are [left, right]
    /// at `sampleRate`, all the same length.
    public static func write(_ url: URL, mix: [[Float]], stems: [[[Float]]], sampleRate: Double,
                             tags: Tags? = nil, bitRate: Int = 256_000) throws {
        precondition(stems.count == 4)
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate,
                                       AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: bitRate]
        let tracks = [mix] + stems
        let inputs = tracks.indices.map { i -> AVAssetWriterInput in
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            input.expectsMediaDataInRealTime = false
            input.marksOutputTrackAsEnabled = i == 0
            writer.add(input)
            return input
        }
        if let tags {
            writer.metadata = [(AVMetadataKey.commonKeyTitle, tags.title), (.commonKeyArtist, tags.artist)].map { k, v in
                let item = AVMutableMetadataItem()
                item.keySpace = .common
                item.key = k as NSString
                item.value = v as NSString
                return item
            }
        }
        guard writer.startWriting() else { throw writer.error ?? StemError.engine("can't write \(url.lastPathComponent)") }
        writer.startSession(atSourceTime: .zero)

        var format = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8, mFramesPerPacket: 1,
            mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var desc: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &format, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                       magicCookie: nil, extensions: nil, formatDescriptionOut: &desc)
        let n = mix[0].count, chunk = 16384
        var pos = 0
        while pos < n {
            let count = min(chunk, n - pos)
            for (t, input) in inputs.enumerated() {
                while !input.isReadyForMoreMediaData {
                    if writer.status == .failed { throw writer.error ?? StemError.engine("writer failed") }
                    usleep(500)
                }
                let buffer = try sampleBuffer(tracks[t], from: pos, count: count, format: desc!, sampleRate: sampleRate)
                guard input.append(buffer) else { throw writer.error ?? StemError.engine("can't append audio") }
            }
            pos += count
        }
        inputs.forEach { $0.markAsFinished() }
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else { throw writer.error ?? StemError.engine("can't finish \(url.lastPathComponent)") }
        try insertManifest(url, manifest())
    }

    private static func sampleBuffer(_ ch: [[Float]], from pos: Int, count: Int, format: CMAudioFormatDescription,
                                     sampleRate: Double) throws -> CMSampleBuffer {
        var interleaved = [Float](repeating: 0, count: count * 2)
        for i in 0..<count {
            interleaved[2 * i] = ch[0][pos + i]
            interleaved[2 * i + 1] = ch[1][pos + i]
        }
        let bytes = count * 8
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                           customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: 0,
                                           blockBufferOut: &block)
        guard let block else { throw StemError.engine("out of memory") }
        interleaved.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                                                                     offsetIntoDestination: 0, dataLength: bytes) }
        var sample: CMSampleBuffer?
        let status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: count,
            presentationTimeStamp: CMTime(value: CMTimeValue(pos), timescale: CMTimeScale(sampleRate)),
            packetDescriptions: nil, sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw StemError.engine("can't build audio buffer (\(status))") }
        return sample
    }

    // MARK: MP4 boxes

    /// Add `moov/udta/stem` (the manifest). Chunk offsets are fixed up if the
    /// movie box sits before the media data.
    static func insertManifest(_ url: URL, _ json: Data) throws {
        var file = Data(Array(try Data(contentsOf: url)))
        guard let moov = box(file, "moov", in: 0..<file.count) else { throw StemError.engine("no moov box") }
        let stem = makeBox("stem", json)
        var newMoovBody: Data
        let body = moov.body
        func bytes(_ r: Range<Int>) -> Data { Data(Array(file[r])) }
        if let udta = box(file, "udta", in: body) {
            let newUdta = makeBox("udta", bytes(udta.body) + stem)
            newMoovBody = bytes(body.lowerBound..<udta.range.lowerBound) + newUdta + bytes(udta.range.upperBound..<body.upperBound)
        } else {
            newMoovBody = bytes(body) + makeBox("udta", stem)
        }
        let delta = newMoovBody.count - body.count
        // Media after the movie box moves by `delta`: shift its chunk offsets.
        if let mdat = box(file, "mdat", in: 0..<file.count), mdat.range.lowerBound > moov.range.lowerBound {
            newMoovBody = shiftChunkOffsets(newMoovBody, by: delta)
        }
        let newMoov = makeBox("moov", newMoovBody)
        file.replaceSubrange(moov.range, with: newMoov)
        compactMediaHeader(&file)
        try file.write(to: url, options: .atomic)
    }

    /// AVAssetWriter writes `mdat` with a 64-bit size (16-byte header), and
    /// Mixxx 2.6 misreads those (it never byte-swaps the 64-bit size), so it
    /// skips past `moov` and finds no manifest. Rewrite the header in place as
    /// an 8-byte `free` box plus a 32-bit `mdat` header: nothing moves, so
    /// chunk offsets stay valid. Returns whether it changed anything.
    @discardableResult
    static func compactMediaHeader(_ file: inout Data) -> Bool {
        guard let mdat = box(file, "mdat", in: 0..<file.count), mdat.body.lowerBound - mdat.range.lowerBound == 16,
              mdat.range.count - 8 <= Int(UInt32.max) else { return false }
        var header = makeBox("free", Data())
        header.appendUInt32(UInt32(mdat.range.count - 8))
        header.append(contentsOf: Array("mdat".utf8))
        file.replaceSubrange((file.startIndex + mdat.range.lowerBound)..<(file.startIndex + mdat.body.lowerBound), with: header)
        return true
    }

    /// Fix a STEM file exported before `compactMediaHeader` existed, in place.
    public static func repair(_ url: URL) throws -> Bool {
        var file = try Data(contentsOf: url)
        guard compactMediaHeader(&file) else { return false }
        try file.write(to: url, options: .atomic)
        return true
    }

    struct Box { let range: Range<Int>; let body: Range<Int> }

    static func box(_ d: Data, _ type: String, in range: Range<Int>) -> Box? {
        var o = range.lowerBound
        while o + 8 <= range.upperBound {
            var size = Int(d.readUInt32(o)), header = 8
            if size == 1 { size = Int(d.readUInt64(o + 8)); header = 16 }
            if size == 0 { size = range.upperBound - o }
            guard size >= header, o + size <= range.upperBound else { return nil }
            if String(decoding: d[(o + 4)..<(o + 8)], as: UTF8.self) == type {
                return Box(range: o..<(o + size), body: (o + header)..<(o + size))
            }
            o += size
        }
        return nil
    }

    static func makeBox(_ type: String, _ body: Data) -> Data {
        var d = Data()
        d.appendUInt32(UInt32(8 + body.count))
        d.append(contentsOf: Array(type.utf8))
        d.append(body)
        return d
    }

    /// Add `delta` to every stco/co64 entry inside a moov body.
    static func shiftChunkOffsets(_ moovBody: Data, by delta: Int) -> Data {
        var d = Data(Array(moovBody))      // fresh buffer: offsets from 0
        func walk(_ range: Range<Int>) {
            var o = range.lowerBound
            while o + 8 <= range.upperBound {
                let size = Int(d.readUInt32(o))
                guard size >= 8, o + size <= range.upperBound else { return }
                let type = String(decoding: d[(o + 4)..<(o + 8)], as: UTF8.self)
                if ["trak", "mdia", "minf", "stbl"].contains(type) { walk((o + 8)..<(o + size)) }
                if type == "stco" || type == "co64" {
                    let count = Int(d.readUInt32(o + 12))
                    for k in 0..<count {
                        if type == "stco" {
                            let p = o + 16 + 4 * k
                            d.writeUInt32(UInt32(Int(d.readUInt32(p)) + delta), at: p)
                        } else {
                            let p = o + 16 + 8 * k
                            d.writeUInt64(UInt64(Int(d.readUInt64(p)) + delta), at: p)
                        }
                    }
                }
                o += size
            }
        }
        walk(0..<d.count)
        return d
    }
}

extension Data {
    func readUInt32(_ o: Int) -> UInt32 {
        self[(startIndex + o)..<(startIndex + o + 4)].reduce(0) { $0 << 8 | UInt32($1) }
    }
    func readUInt64(_ o: Int) -> UInt64 {
        self[(startIndex + o)..<(startIndex + o + 8)].reduce(0) { $0 << 8 | UInt64($1) }
    }
    mutating func appendUInt32(_ v: UInt32) { append(contentsOf: (0..<4).map { UInt8(truncatingIfNeeded: v >> (24 - 8 * $0)) }) }
    mutating func writeUInt32(_ v: UInt32, at o: Int) {
        for k in 0..<4 { self[startIndex + o + k] = UInt8(truncatingIfNeeded: v >> (24 - 8 * k)) }
    }
    mutating func writeUInt64(_ v: UInt64, at o: Int) {
        for k in 0..<8 { self[startIndex + o + k] = UInt8(truncatingIfNeeded: v >> (56 - 8 * k)) }
    }
}
