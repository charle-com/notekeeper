import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox

/// Briques partagées par les deux sources de capture (micro et audio système) : erreurs, horloge
/// hôte, lecture de propriétés CoreAudio, verrou léger, pool de buffers, conversion 16 kHz mono.

// MARK: - Erreur

/// Erreur du module audio. Message lisible en français, OSStatus joint quand il existe.
public struct AudioCaptureError: LocalizedError, CustomStringConvertible {
    public let code: Int
    public let message: String
    public let status: OSStatus?

    init(_ code: Int, _ message: String, status: OSStatus? = nil) {
        self.code = code
        self.message = message
        self.status = status
    }

    public var errorDescription: String? {
        status.map { "\(message) (OSStatus \($0))" } ?? message
    }
    public var description: String { errorDescription ?? message }
}

// MARK: - Bloc converti

/// Un bloc 16 kHz mono Float32 produit par une source, avec le temps hôte (mach) du premier
/// échantillon source. `discontinuity` est vrai sur le premier bloc qui suit un (re)démarrage de
/// la source : la session s'en sert pour recaler la piste sur l'horloge commune.
public struct AudioChunk {
    public let samples: [Float]
    public let hostTime: UInt64
    public let discontinuity: Bool
}

/// Format cible commun à tout le module.
public enum TargetFormat {
    public static let sampleRate: Double = 16_000
    public static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                             channels: 1, interleaved: false)!
}

// MARK: - Horloge hôte

/// Temps hôte mach converti en secondes par CoreAudio (même base que les `AudioTimeStamp`).
public enum HostClock {
    public static func now() -> UInt64 { mach_absolute_time() }

    /// Secondes signées entre deux temps hôte.
    public static func seconds(from a: UInt64, to b: UInt64) -> Double {
        if b >= a {
            return Double(AudioConvertHostTimeToNanos(b - a)) / 1e9
        }
        return -Double(AudioConvertHostTimeToNanos(a - b)) / 1e9
    }

    /// Temps hôte d'un horodatage HAL, ou l'instant présent s'il n'est pas renseigné.
    static func hostTime(of ts: UnsafePointer<AudioTimeStamp>) -> UInt64 {
        if ts.pointee.mFlags.contains(.hostTimeValid), ts.pointee.mHostTime > 0 {
            return ts.pointee.mHostTime
        }
        return mach_absolute_time()
    }
}

// MARK: - Propriétés CoreAudio

enum CoreAudioProps {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        var addr = address(selector, scope: scope)
        guard AudioObjectHasProperty(object, &addr) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    static func int32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Int32? {
        var addr = address(selector)
        guard AudioObjectHasProperty(object, &addr) else { return nil }
        var value: Int32 = 0
        var size = UInt32(MemoryLayout<Int32>.size)
        let status = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        guard AudioObjectHasProperty(object, &addr) else { return nil }
        var value: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0)
        }
        guard status == noErr else { return nil }
        return value as String?
    }

    static func objectID(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> AudioObjectID? {
        var addr = address(selector)
        var value = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value)
        return (status == noErr && value != kAudioObjectUnknown) ? value : nil
    }

    static func objectIDs(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                          scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var addr = address(selector, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func streamFormat(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                             scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioStreamBasicDescription? {
        var addr = address(selector, scope: scope)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &asbd)
        return status == noErr ? asbd : nil
    }

    static func defaultInputDevice() -> AudioDeviceID? { objectID(system, kAudioHardwarePropertyDefaultInputDevice) }
    static func defaultOutputDevice() -> AudioDeviceID? { objectID(system, kAudioHardwarePropertyDefaultOutputDevice) }

    static func deviceUID(_ device: AudioDeviceID) -> String? { string(device, kAudioDevicePropertyDeviceUID) }
    static func deviceName(_ device: AudioDeviceID) -> String? { string(device, kAudioObjectPropertyName) }

    static func isAlive(_ device: AudioDeviceID) -> Bool {
        guard device != kAudioObjectUnknown else { return false }
        return (uint32(device, kAudioDevicePropertyDeviceIsAlive) ?? 1) != 0
    }

    /// Nombre de canaux d'un device dans un scope (entrée ou sortie).
    static func channelCount(_ device: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let abl = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, abl) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(abl).reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    /// Nombre de flux d'un device dans un scope : c'est le nombre de buffers que ce device occupe
    /// dans l'AudioBufferList d'un agrégat.
    static func streamCount(_ device: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        objectIDs(device, kAudioDevicePropertyStreams, scope: scope).count
    }

    /// Objet process CoreAudio d'un pid (kAudioObjectUnknown si le HAL ne le connaît pas).
    static func processObject(forPID pid: pid_t) -> AudioObjectID? {
        var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var qualifier = pid
        var value = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(system, &addr, UInt32(MemoryLayout<pid_t>.size), &qualifier, &size, &value)
        return (status == noErr && value != kAudioObjectUnknown) ? value : nil
    }

    static func floatASBD(sampleRate: Float64, channels: UInt32) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0)
    }

    static func describe(_ f: AVAudioFormat) -> String {
        "\(Int(f.sampleRate)) Hz / \(f.channelCount) ch\(f.isInterleaved ? " entrelacé" : "")"
    }
}

// MARK: - Verrou léger

/// `os_unfair_lock` avec stockage stable, utilisable depuis le thread IO (héritage de priorité).
final class UnfairLock {
    private let storage: UnsafeMutablePointer<os_unfair_lock>

    init() {
        storage = .allocate(capacity: 1)
        storage.initialize(to: os_unfair_lock())
    }

    deinit {
        storage.deinitialize(count: 1)
        storage.deallocate()
    }

    func withLock<T>(_ body: () -> T) -> T {
        os_unfair_lock_lock(storage)
        defer { os_unfair_lock_unlock(storage) }
        return body()
    }
}

// MARK: - Pool de buffers

/// Buffers préalloués au format natif de la source : le thread IO n'alloue jamais, et le nombre
/// de tranches en vol vers la file de traitement est borné (si le traitement décroche, on perd des
/// frames au lieu de laisser la mémoire enfler).
final class BufferPool {
    private let lock = UnfairLock()
    private var free: [AVAudioPCMBuffer]

    init?(format: AVAudioFormat, frameCapacity: AVAudioFrameCount, count: Int) {
        guard frameCapacity > 0, count > 0 else { return nil }
        var buffers: [AVAudioPCMBuffer] = []
        buffers.reserveCapacity(count)
        for _ in 0..<count {
            guard let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else { return nil }
            buffers.append(b)
        }
        // La capacité réservée n'est jamais dépassée : `append` ne réalloue donc jamais.
        free = buffers
    }

    func acquire() -> AVAudioPCMBuffer? { lock.withLock { free.popLast() } }
    func release(_ buffer: AVAudioPCMBuffer) { lock.withLock { free.append(buffer) } }
}

// MARK: - Conversion 16 kHz mono

/// Convertit des buffers au format natif d'une source vers 16 kHz mono Float32. À n'utiliser que
/// depuis une seule file (AVAudioConverter n'est pas thread-safe).
final class Resampler {
    let inFormat: AVAudioFormat
    let outFormat = TargetFormat.format
    private let converter: AVAudioConverter
    private var errorLogged = false

    init?(from inFormat: AVAudioFormat) {
        guard let c = AVAudioConverter(from: inFormat, to: TargetFormat.format) else { return nil }
        self.inFormat = inFormat
        self.converter = c
    }

    /// Renvoie les échantillons convertis (vide en cas d'erreur).
    func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard buffer.frameLength > 0 else { return [] }
        let ratio = outFormat.sampleRate / inFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 32)
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return [] }

        var error: NSError?
        var supplied = false
        // `.noDataNow` et non `.endOfStream` : endOfStream met le converter dans un état terminal
        // et jette tous les buffers suivants.
        let status = converter.convert(to: out, error: &error) { _, ioStatus in
            if supplied { ioStatus.pointee = .noDataNow; return nil }
            supplied = true
            ioStatus.pointee = .haveData
            return buffer
        }
        if status == .error {
            if !errorLogged {
                errorLogged = true
                AudioLog.log("conversion impossible : \(error?.localizedDescription ?? "erreur inconnue")")
            }
            return []
        }
        guard out.frameLength > 0, let ch = out.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: ch, count: Int(out.frameLength)))
    }
}

// MARK: - Journal

/// Journal minimal du module (stderr), horodaté. Remplaçable par l'app via `sink`.
public enum AudioLog {
    public static var sink: ((String) -> Void)? = nil
    private static let lock = NSLock()

    public static func log(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        if let sink { sink(message); return }
        let ts = ISO8601DateFormatter().string(from: Date())
        FileHandle.standardError.write(Data("[\(ts)] audio: \(message)\n".utf8))
    }
}
