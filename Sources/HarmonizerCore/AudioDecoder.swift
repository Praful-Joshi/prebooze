import AVFoundation
import Foundation

public struct DecodedAudio: Sendable {
    public let sampleRate: Double
    public let left: [Float]
    public let right: [Float]
    public var frames: Int { left.count }

    /// (L + R) / 2, as Mixxx's analyzers downmix.
    public var mono: [Float] {
        var out = [Float](repeating: 0, count: frames)
        for i in 0..<frames { out[i] = (left[i] + right[i]) * 0.5 }
        return out
    }
}

public enum AudioDecodeError: Error, LocalizedError {
    case unreadable(URL, String)
    public var errorDescription: String? {
        switch self {
        case let .unreadable(url, why): "Can't decode \(url.lastPathComponent): \(why)"
        }
    }
}

/// Decode a whole file to float32 stereo at its native sample rate.
public func decodeAudio(_ url: URL) throws -> DecodedAudio {
    let file: AVAudioFile
    do {
        file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
    } catch {
        throw AudioDecodeError.unreadable(url, error.localizedDescription)
    }
    let format = file.processingFormat
    let total = AVAudioFrameCount(file.length)
    guard total > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: total) else {
        throw AudioDecodeError.unreadable(url, "empty file")
    }
    do {
        try file.read(into: buffer)
    } catch {
        throw AudioDecodeError.unreadable(url, error.localizedDescription)
    }
    let n = Int(buffer.frameLength)
    guard let data = buffer.floatChannelData else {
        throw AudioDecodeError.unreadable(url, "no float data")
    }
    let left = Array(UnsafeBufferPointer(start: data[0], count: n))
    let right = format.channelCount > 1
        ? Array(UnsafeBufferPointer(start: data[1], count: n)) : left
    return DecodedAudio(sampleRate: format.sampleRate, left: left, right: right)
}

/// The mixer's working rate. Tracks at other rates are resampled on load.
public let mixSampleRate = 48000.0

/// Decode and, if needed, resample to `rate` (high-quality AVAudioConverter).
public func decodeAudio(_ url: URL, sampleRate rate: Double) throws -> DecodedAudio {
    let native = try decodeAudio(url)
    guard native.sampleRate != rate else { return native }
    let inFormat = AVAudioFormat(standardFormatWithSampleRate: native.sampleRate, channels: 2)!
    let outFormat = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
    guard let converter = AVAudioConverter(from: inFormat, to: outFormat),
          let input = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(native.frames)) else {
        throw AudioDecodeError.unreadable(url, "can't resample")
    }
    converter.sampleRateConverterQuality = .max
    input.frameLength = AVAudioFrameCount(native.frames)
    native.left.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: native.frames) }
    native.right.withUnsafeBufferPointer { input.floatChannelData![1].update(from: $0.baseAddress!, count: native.frames) }
    let capacity = AVAudioFrameCount(Double(native.frames) * rate / native.sampleRate) + 4096
    guard let output = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else {
        throw AudioDecodeError.unreadable(url, "can't resample")
    }
    var fed = false
    var error: NSError?
    converter.convert(to: output, error: &error) { _, status in
        if fed { status.pointee = .endOfStream; return nil }
        fed = true
        status.pointee = .haveData
        return input
    }
    if let error { throw AudioDecodeError.unreadable(url, error.localizedDescription) }
    let n = Int(output.frameLength)
    return DecodedAudio(sampleRate: rate,
                        left: Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: n)),
                        right: Array(UnsafeBufferPointer(start: output.floatChannelData![1], count: n)))
}

/// Small in-memory cache of decoded tracks at the mix rate (the editor keeps
/// jumping between neighbouring transitions).
public final class AudioStore: @unchecked Sendable {
    public static let shared = AudioStore()
    private let lock = NSLock()
    private var items: [(String, DecodedAudio)] = []
    private let capacity = 6

    public func audio(_ url: URL) throws -> DecodedAudio {
        try audio(url, variant: AudioVariant(), nativeRate: mixSampleRate)
    }

    /// Decoded at the mix rate, with the variant (key shift, loops) applied.
    /// `nativeRate` is the file's rate, which the variant's frames refer to.
    public func audio(_ url: URL, variant: AudioVariant, nativeRate: Double) throws -> DecodedAudio {
        let key = url.path + variant.signature
        if let hit = lookup(key) { return hit }
        let plain: DecodedAudio
        if variant.isIdentity {
            plain = try decodeAudio(url, sampleRate: mixSampleRate)
        } else {
            plain = try audio(url)
        }
        let a = variant.apply(to: plain, nativeRate: nativeRate)
        lock.lock()
        items.append((key, a))
        if items.count > capacity { items.removeFirst() }
        lock.unlock()
        return a
    }

    private func lookup(_ key: String) -> DecodedAudio? {
        lock.lock()
        defer { lock.unlock() }
        guard let i = items.firstIndex(where: { $0.0 == key }) else { return nil }
        let hit = items.remove(at: i)
        items.append(hit)
        return hit.1
    }
}
