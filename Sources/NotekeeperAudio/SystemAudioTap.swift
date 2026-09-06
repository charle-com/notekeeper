import Foundation
import AVFoundation
import AudioToolbox
import CoreAudio

/// Réglages du montage. Les valeurs par défaut sont celles validées sur le terrain (docs/audio.md).
public struct SystemTapOptions {
    /// Exclure notre propre process du mixage (sinon on s'enregistre soi-même).
    public var excludeOwnProcess = true
    /// `kAudioAggregateDeviceTapAutoStartKey` : l'agrégat attend le premier son d'un process
    /// tapé avant de démarrer (aucun callback tant que rien ne joue). À false, les callbacks
    /// arrivent tout de suite, remplis de silence si rien ne joue.
    public var autoStart = false
    /// Mettre la sortie par défaut en sous-device de l'agrégat (elle fournit l'horloge).
    /// À false, l'agrégat ne contient que le tap.
    public var includeOutputSubDevice = true
    public init() {}
    /// Surcharge par variables d'environnement (NOTEKEEPER_TAP_AUTOSTART=1,
    /// NOTEKEEPER_TAP_SUBDEVICE=0), pour les essais de terrain.
    public static func fromEnvironment(_ base: SystemTapOptions = SystemTapOptions()) -> SystemTapOptions {
        var o = base
        let env = ProcessInfo.processInfo.environment
        if let v = env["NOTEKEEPER_TAP_AUTOSTART"] { o.autoStart = v == "1" }
        if let v = env["NOTEKEEPER_TAP_SUBDEVICE"] { o.includeOutputSubDevice = v == "1" }
        return o
    }
}

/// Capture de l'audio système (tout ce que le Mac joue : Zoom, Meet dans Chrome, Teams, FaceTime,
/// WhatsApp…) par Core Audio process tap (macOS 14.2+).
///
/// Montage : `CATapDescription(stereoGlobalTapButExcludeProcesses: [notre process])`, tap non
/// muté (`.unmuted` : l'utilisateur continue d'entendre), puis un aggregate device PRIVÉ dont le
/// sous-device est la sortie par défaut (il fournit l'horloge) et dont la liste de taps contient
/// notre tap avec compensation de dérive. SANS `kAudioAggregateDeviceTapAutoStartKey` : validé
/// sur le terrain, cette clé bloque la file IO du HAL du process (`_StartIO` en attente), ce qui
/// gèle aussi la capture micro. Un IOProc lit l'entrée de l'agrégat : les premiers
/// buffers de l'AudioBufferList sont les flux d'entrée éventuels du sous-device (un casque avec
/// micro en a), les suivants sont les taps. Le format du tap est lu par `kAudioTapPropertyFormat`.
///
/// Un écouteur sur `kAudioHardwarePropertyDefaultOutputDevice` recrée tap et agrégat quand la
/// sortie change (AirPods qui se connectent) ; le premier bloc qui suit porte `discontinuity`
/// pour que la session recale la piste sur l'horloge commune sans la perdre.
///
/// Autorisation : « Enregistrement audio système » (Réglages > Confidentialité). Sans elle,
/// selon la version de macOS, la création échoue ou le tap ne livre que du silence.
@available(macOS 14.2, *)
public final class SystemAudioTap: @unchecked Sendable {

    /// Reçoit chaque bloc converti 16 kHz mono, depuis la file de traitement.
    public var onChunk: ((AudioChunk) -> Void)? {
        get { sync { _onChunk } }
        set { sync { _onChunk = newValue } }
    }
    /// Avertissements non bloquants (sortie changée, tap recréé, échec de recréation).
    public var onWarning: ((String) -> Void)? {
        get { sync { _onWarning } }
        set { sync { _onWarning = newValue } }
    }

    public var outputDeviceName: String { sync { _outputName } }
    public var isRunning: Bool { sync { running } }
    public var tapFormatDescription: String { sync { tapFormat.map(CoreAudioProps.describe) ?? "aucun" } }
    /// Nombre de callbacks IO reçus et d'échantillons non nuls (pour le diagnostic d'autorisation).
    public var stats: (callbacks: Int, nonZeroSamples: Int) {
        sync { (io?.callbacks ?? 0, io?.nonZero ?? 0) }
    }

    public typealias Options = SystemTapOptions

    public init(options: SystemTapOptions = SystemTapOptions()) {
        self.excludeOwnProcess = options.excludeOwnProcess
        self.autoStart = options.autoStart
        self.includeOutputSubDevice = options.includeOutputSubDevice
        queueKey = DispatchSpecificKey<Void>()
        stateQueue.setSpecific(key: queueKey, value: ())
    }

    deinit {
        removeListener()
        teardownUnsafe()
    }

    public func start() throws {
        try sync {
            guard !running else { return }
            try buildUnsafe()
            running = true
            installListener()
            AudioLog.log("tap système démarré : sortie \(_outputName), format \(tapFormat.map(CoreAudioProps.describe) ?? "?"), buffer tap n°\(tapBufferIndex), autostart \(autoStart), sous-device \(includeOutputSubDevice)")
        }
    }

    /// Arrête et détruit tout (IOProc, agrégat, tap). Au retour, plus aucun bloc ne sera livré.
    public func stop() {
        sync {
            guard running else { return }
            running = false
            removeListener()
            teardownUnsafe()
            AudioLog.log("tap système arrêté")
        }
    }

    // MARK: État interne (sur stateQueue)

    private let excludeOwnProcess: Bool
    private let autoStart: Bool
    private let includeOutputSubDevice: Bool
    private let stateQueue = DispatchQueue(label: "fr.charlesneveu.notekeeper.tap.state")
    private let processQueue = DispatchQueue(label: "fr.charlesneveu.notekeeper.tap.process", qos: .userInitiated)
    private let queueKey: DispatchSpecificKey<Void>

    private var _onChunk: ((AudioChunk) -> Void)?
    private var _onWarning: ((String) -> Void)?
    private var _outputName = "Sortie"
    private var running = false

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var outputDeviceID = AudioDeviceID(kAudioObjectUnknown)
    private var tapFormat: AVAudioFormat?
    private var tapBufferIndex = 0
    private var io: TapIO?

    private var listener: (AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)?
    private var rebuildWork: DispatchWorkItem?

    private static let poolSize = 16
    private static let poolFrames: AVAudioFrameCount = 8192

    private func sync<T>(_ work: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil { return try work() }
        return try stateQueue.sync(execute: work)
    }

    // MARK: Construction (sur stateQueue)

    private func buildUnsafe() throws {
        do {
            try createTapUnsafe()
            try createAggregateUnsafe()
            try startIOUnsafe()
        } catch {
            teardownUnsafe()
            throw error
        }
    }

    private func createTapUnsafe() throws {
        var excluded: [AudioObjectID] = []
        if excludeOwnProcess, let me = CoreAudioProps.processObject(forPID: getpid()) {
            excluded.append(me)
        }
        // Cet init pose `exclusive = true` (tout SAUF les process listés) : ne pas y toucher,
        // à false le tap ne mixerait plus que notre propre process, donc du silence.
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        desc.name = "Notekeeper"
        desc.muteBehavior = .unmuted
        desc.isPrivate = true

        var id = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(desc, &id)
        guard status == noErr, id != kAudioObjectUnknown else {
            throw AudioCaptureError(60, "Création du tap audio système refusée (autorisation « Enregistrement audio système » ?)", status: status)
        }
        tapID = id

        guard var asbd = CoreAudioProps.streamFormat(id, kAudioTapPropertyFormat),
              asbd.mSampleRate > 0, asbd.mChannelsPerFrame > 0,
              let fmt = AVAudioFormat(streamDescription: &asbd) else {
            throw AudioCaptureError(61, "Format du tap illisible")
        }
        tapFormat = fmt
    }

    private func createAggregateUnsafe() throws {
        guard let output = CoreAudioProps.defaultOutputDevice(),
              let outputUID = CoreAudioProps.deviceUID(output) else {
            throw AudioCaptureError(62, "Aucun périphérique de sortie par défaut")
        }
        outputDeviceID = output
        _outputName = CoreAudioProps.deviceName(output) ?? "Sortie"
        // UID du tap : propriété du tap, à défaut l'UUID de la description.
        let tapUID = CoreAudioProps.string(tapID, kAudioTapPropertyUID) ?? ""
        guard !tapUID.isEmpty else { throw AudioCaptureError(63, "UID du tap illisible") }

        var description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Notekeeper Tap",
            kAudioAggregateDeviceUIDKey: "fr.charlesneveu.notekeeper.tap.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: autoStart,
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: true],
            ],
        ]
        if includeOutputSubDevice {
            description[kAudioAggregateDeviceMainSubDeviceKey] = outputUID
            description[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: outputUID]]
        }
        var id = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &id)
        guard status == noErr, id != kAudioObjectUnknown else {
            throw AudioCaptureError(64, "Création de l'agrégat de capture a échoué", status: status)
        }
        aggregateID = id
        // Les flux d'entrée du sous-device précèdent ceux des taps dans l'AudioBufferList.
        tapBufferIndex = includeOutputSubDevice ? CoreAudioProps.streamCount(output, scope: kAudioDevicePropertyScopeInput) : 0
    }

    private func startIOUnsafe() throws {
        guard let fmt = tapFormat else { throw AudioCaptureError(61, "Format du tap illisible") }
        guard let resampler = Resampler(from: fmt) else {
            throw AudioCaptureError(65, "Conversion \(CoreAudioProps.describe(fmt)) vers 16 kHz mono impossible")
        }
        guard let pool = BufferPool(format: fmt, frameCapacity: Self.poolFrames, count: Self.poolSize) else {
            throw AudioCaptureError(66, "Allocation des buffers du tap impossible")
        }
        let io = TapIO(format: fmt, pool: pool, resampler: resampler, queue: processQueue, bufferIndex: tapBufferIndex)
        io.deliver = _onChunk
        self.io = io

        var procID: AudioDeviceIOProcID?
        // File nil : le bloc tourne sur le thread IO du HAL, sans allocation (copie dans le pool
        // puis dispatch vers la file de traitement).
        var status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { _, inputData, inputTime, _, _ in
            io.ioCallback(inputData, inputTime)
        }
        guard status == noErr, let procID else {
            throw AudioCaptureError(67, "Création de l'IOProc a échoué", status: status)
        }
        ioProcID = procID
        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else {
            throw AudioCaptureError(68, "AudioDeviceStart a échoué", status: status)
        }
    }

    /// Ordre inverse de la construction. Idempotent.
    private func teardownUnsafe() {
        if aggregateID != kAudioObjectUnknown, let procID = ioProcID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        ioProcID = nil
        // Barrière : plus aucun callback en vol, les blocs en file voient `closed`.
        if let io {
            processQueue.sync { io.closed = true }
            if io.starved > 0 { AudioLog.log("tap : \(io.starved) buffer(s) perdus, traitement en retard") }
        }
        io = nil
        if aggregateID != kAudioObjectUnknown {
            let s = AudioHardwareDestroyAggregateDevice(aggregateID)
            if s != noErr { AudioLog.log("tap : destruction de l'agrégat status=\(s)") }
            aggregateID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            let s = AudioHardwareDestroyProcessTap(tapID)
            if s != noErr { AudioLog.log("tap : destruction du tap status=\(s)") }
            tapID = kAudioObjectUnknown
        }
        tapFormat = nil
        outputDeviceID = kAudioObjectUnknown
    }

    // MARK: Changement de sortie par défaut

    private func installListener() {
        guard listener == nil else { return }
        var addr = CoreAudioProps.address(kAudioHardwarePropertyDefaultOutputDevice)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.outputChangedUnsafe()
        }
        if AudioObjectAddPropertyListenerBlock(CoreAudioProps.system, &addr, stateQueue, block) == noErr {
            listener = (addr, block)
        }
    }

    private func removeListener() {
        if let (address, block) = listener {
            var addr = address
            AudioObjectRemovePropertyListenerBlock(CoreAudioProps.system, &addr, stateQueue, block)
        }
        listener = nil
        rebuildWork?.cancel()
        rebuildWork = nil
    }

    private func outputChangedUnsafe() {
        guard running else { return }
        guard let current = CoreAudioProps.defaultOutputDevice(), current != outputDeviceID else { return }
        // Rafale possible (déconnexion puis nouveau défaut) : on laisse le HAL se poser.
        rebuildWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.rebuildUnsafe() }
        rebuildWork = work
        stateQueue.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func rebuildUnsafe() {
        guard running else { return }
        teardownUnsafe()
        do {
            try buildUnsafe()
            AudioLog.log("tap recréé sur \(_outputName)")
            _onWarning?("Audio système basculé sur \(_outputName)")
        } catch {
            AudioLog.log("tap : recréation impossible : \(error)")
            _onWarning?("Audio système indisponible : \(error.localizedDescription)")
        }
    }
}

// MARK: - IO du tap

/// Ce que voit le thread IO : format, pool, index du buffer du tap dans l'AudioBufferList.
/// Copie sans allocation puis dispatch vers `queue` (série) où tournent conversion et livraison.
@available(macOS 14.2, *)
private final class TapIO {
    let format: AVAudioFormat
    let pool: BufferPool
    let resampler: Resampler
    let queue: DispatchQueue
    let bufferIndex: Int
    let bytesPerFrame: Int
    var deliver: ((AudioChunk) -> Void)?
    var closed = false
    private var first = true

    private let statsLock = UnfairLock()
    private var _callbacks = 0
    private var _starved = 0
    private var _nonZero = 0
    var callbacks: Int { statsLock.withLock { _callbacks } }
    var starved: Int { statsLock.withLock { _starved } }
    var nonZero: Int { statsLock.withLock { _nonZero } }

    init(format: AVAudioFormat, pool: BufferPool, resampler: Resampler, queue: DispatchQueue, bufferIndex: Int) {
        self.format = format; self.pool = pool; self.resampler = resampler
        self.queue = queue; self.bufferIndex = bufferIndex
        self.bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
    }

    /// Thread IO : copie du buffer du tap dans un buffer du pool.
    func ioCallback(_ inputData: UnsafePointer<AudioBufferList>, _ inputTime: UnsafePointer<AudioTimeStamp>) {
        statsLock.withLock { _callbacks += 1 }
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        let count = abl.count
        guard count > 0 else { return }
        // Index prévu, sinon le dernier buffer (les taps ferment la liste).
        let index = bufferIndex < count ? bufferIndex : count - 1
        let src = abl[index]
        guard let data = src.mData, bytesPerFrame > 0 else { return }
        let frames = Int(src.mDataByteSize) / bytesPerFrame
        guard frames > 0, let buf = pool.acquire() else {
            statsLock.withLock { _starved += 1 }
            return
        }
        let n = min(frames, Int(buf.frameCapacity))
        buf.frameLength = AVAudioFrameCount(n)
        let dst = UnsafeMutableAudioBufferListPointer(buf.mutableAudioBufferList)
        if format.isInterleaved {
            dst[0].mData?.copyMemory(from: data, byteCount: n * bytesPerFrame)
            dst[0].mDataByteSize = UInt32(n * bytesPerFrame)
        } else {
            // Format non entrelacé : un buffer par canal, copiés dans l'ordre.
            for c in 0..<min(dst.count, count - index) {
                if let s = abl[index + c].mData, let d = dst[c].mData {
                    d.copyMemory(from: s, byteCount: n * bytesPerFrame)
                    dst[c].mDataByteSize = UInt32(n * bytesPerFrame)
                }
            }
        }
        let host = HostClock.hostTime(of: inputTime)
        queue.async { self.process(buf, hostTime: host) }
    }

    func process(_ buffer: AVAudioPCMBuffer, hostTime: UInt64) {
        defer { pool.release(buffer) }
        guard !closed else { return }
        let samples = resampler.convert(buffer)
        guard !samples.isEmpty else { return }
        var nz = 0
        for s in samples where s != 0 { nz += 1 }
        if nz > 0 { statsLock.withLock { _nonZero += nz } }
        let chunk = AudioChunk(samples: samples, hostTime: hostTime, discontinuity: first)
        first = false
        deliver?(chunk)
    }
}
