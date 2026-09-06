import Foundation

/// Écriture d'un WAV PCM 16 bits mono au fil de l'eau. L'en-tête (tailles RIFF et data) est
/// réécrit toutes les 10 s d'audio et à la fermeture : un crash laisse un fichier lisible à
/// 10 s près. Non thread-safe : à n'utiliser que depuis une seule file.
public final class WAVWriter {
    public let url: URL
    public let sampleRate: Int
    public private(set) var framesWritten: Int64 = 0
    public var duration: TimeInterval { Double(framesWritten) / Double(sampleRate) }

    private let handle: FileHandle
    private var framesSinceHeader: Int64 = 0
    private var closed = false
    private let headerInterval: Int64

    private static let headerSize = 44

    public init(url: URL, sampleRate: Int = Int(TargetFormat.sampleRate)) throws {
        self.url = url
        self.sampleRate = sampleRate
        self.headerInterval = Int64(sampleRate) * 10
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard fm.createFile(atPath: url.path, contents: nil) else {
            throw AudioCaptureError(70, "Création du fichier \(url.lastPathComponent) impossible")
        }
        handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: Self.header(frames: 0, sampleRate: sampleRate))
    }

    deinit {
        if !closed { try? close() }
    }

    /// Ajoute des échantillons Float32 (-1…1), convertis en PCM 16 bits avec écrêtage.
    public func append(_ samples: [Float]) throws {
        guard !closed, !samples.isEmpty else { return }
        var pcm = [Int16](repeating: 0, count: samples.count)
        for i in 0..<samples.count {
            let v = max(-1, min(1, samples[i]))
            pcm[i] = Int16(v * 32767)
        }
        try pcm.withUnsafeBytes { try handle.write(contentsOf: Data($0)) }
        try noteFrames(Int64(samples.count))
    }

    /// Ajoute `frames` échantillons de silence (recalage sur l'horloge commune).
    public func appendSilence(frames: Int) throws {
        guard !closed, frames > 0 else { return }
        var remaining = frames
        let zeros = Data(count: min(remaining, 16_000) * 2)
        while remaining > 0 {
            let n = min(remaining, 16_000)
            try handle.write(contentsOf: n == 16_000 ? zeros : zeros.prefix(n * 2))
            remaining -= n
        }
        try noteFrames(Int64(frames))
    }

    /// Réécrit l'en-tête et ferme le fichier. Idempotent.
    public func close() throws {
        guard !closed else { return }
        closed = true
        try writeHeader()
        try handle.close()
    }

    private func noteFrames(_ n: Int64) throws {
        framesWritten += n
        framesSinceHeader += n
        if framesSinceHeader >= headerInterval {
            framesSinceHeader = 0
            try writeHeader()
        }
    }

    private func writeHeader() throws {
        let end = try handle.offset()
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Self.header(frames: framesWritten, sampleRate: sampleRate))
        try handle.seek(toOffset: end)
    }

    private static func header(frames: Int64, sampleRate: Int) -> Data {
        let dataBytes = UInt32(clamping: frames * 2)
        var d = Data(capacity: headerSize)
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append(contentsOf: Array("RIFF".utf8))
        u32(36 + dataBytes)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8))
        u32(16)                          // taille du chunk fmt
        u16(1)                           // PCM
        u16(1)                           // mono
        u32(UInt32(sampleRate))
        u32(UInt32(sampleRate * 2))      // octets par seconde
        u16(2)                           // octets par frame
        u16(16)                          // bits par échantillon
        d.append(contentsOf: Array("data".utf8))
        u32(dataBytes)
        return d
    }

    /// Durée d'un WAV 16 bits mono écrit par cette classe, lue dans l'en-tête.
    public static func duration(of url: URL) -> TimeInterval? {
        guard let h = try? FileHandle(forReadingFrom: url), let head = try? h.read(upToCount: headerSize),
              head.count == headerSize else { return nil }
        let rate = head.subdata(in: 24..<28).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
        let dataBytes = head.subdata(in: 40..<44).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
        guard rate > 0 else { return nil }
        return Double(dataBytes / 2) / Double(rate)
    }
}
