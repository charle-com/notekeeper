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
    /// Recréer le tap quand la sortie change de cadence nominale (sinon seule la garde mesurée corrige).
    public var rebuildOnRateChange = true
    public init() {}
    /// Surcharge par variables d'environnement (NOTEKEEPER_TAP_AUTOSTART=1,
    /// NOTEKEEPER_TAP_SUBDEVICE=0), pour les essais de terrain.
    public static func fromEnvironment(_ base: SystemTapOptions = SystemTapOptions()) -> SystemTapOptions {
        var o = base
        let env = ProcessInfo.processInfo.environment
        if let v = env["NOTEKEEPER_TAP_AUTOSTART"] { o.autoStart = v == "1" }
        if let v = env["NOTEKEEPER_TAP_SUBDEVICE"] { o.includeOutputSubDevice = v == "1" }
        if let v = env["NOTEKEEPER_TAP_RATE_LISTENER"] { o.rebuildOnRateChange = v == "1" }
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
        self.rebuildOnRateChange = options.rebuildOnRateChange
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
    private let rebuildOnRateChange: Bool
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
    /// Cadence nominale de la sortie : un changement (casque qui passe en mode appel) recrée le tap.
    private var rateListener: (AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)?
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
        guard var fmt = tapFormat else { throw AudioCaptureError(61, "Format du tap illisible") }
        // Le tap annonce parfois une cadence périmée (sortie qui vient de changer de cadence) :
        // c'est l'agrégat qui cadence les buffers livrés, sa cadence nominale fait foi.
        if let rate = CoreAudioProps.nominalSampleRate(aggregateID), rate > 0, abs(rate - fmt.sampleRate) > 1 {
            var asbd = fmt.streamDescription.pointee
            asbd.mSampleRate = rate
            if let fixed = AVAudioFormat(streamDescription: &asbd) {
                AudioLog.log(String(format: "tap : l'agrégat tourne à %.0f Hz, le tap annonçait %.0f Hz, format aligné", rate, fmt.sampleRate))
                fmt = fixed
                tapFormat = fixed
            }
        }
        guard let resampler = Resampler(from: fmt) else {
            throw AudioCaptureError(65, "Conversion \(CoreAudioProps.describe(fmt)) vers 16 kHz mono impossible")
        }
        guard let pool = BufferPool(format: fmt, frameCapacity: Self.poolFrames, count: Self.poolSize) else {
            throw AudioCaptureError(66, "Allocation des buffers du tap impossible")
        }
        let io = TapIO(format: fmt, pool: pool, resampler: resampler, queue: processQueue, bufferIndex: tapBufferIndex)
        io.deliver = _onChunk
        io.warn = { [weak self] m in self?.stateQueue.async { self?._onWarning?(m) } }
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
        installRateListener()
    }

    private func installRateListener() {
        removeRateListener()
        guard rebuildOnRateChange, outputDeviceID != kAudioObjectUnknown else { return }
        var addr = CoreAudioProps.address(kAudioDevicePropertyNominalSampleRate)
        let device = outputDeviceID
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.rateChangedUnsafe(device: device)
        }
        if AudioObjectAddPropertyListenerBlock(device, &addr, stateQueue, block) == noErr {
            rateListener = (device, addr, block)
        }
    }

    private func removeRateListener() {
        if let (device, address, block) = rateListener {
            var addr = address
            AudioObjectRemovePropertyListenerBlock(device, &addr, stateQueue, block)
        }
        rateListener = nil
    }

    private func removeListener() {
        if let (address, block) = listener {
            var addr = address
            AudioObjectRemovePropertyListenerBlock(CoreAudioProps.system, &addr, stateQueue, block)
        }
        listener = nil
        removeRateListener()
        rebuildWork?.cancel()
        rebuildWork = nil
    }

    private func rateChangedUnsafe(device: AudioDeviceID) {
        guard running, device == outputDeviceID else { return }
        let rate = CoreAudioProps.nominalSampleRate(device) ?? 0
        AudioLog.log(String(format: "tap : la sortie %@ passe à %.0f Hz, recréation", _outputName, rate))
        rebuildWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.rebuildUnsafe() }
        rebuildWork = work
        stateQueue.asyncAfter(deadline: .now() + 0.4, execute: work)
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
            installRateListener()
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
    private(set) var format: AVAudioFormat
    let pool: BufferPool
    private(set) var resampler: Resampler
    let queue: DispatchQueue
    let bufferIndex: Int
    private var _bytesPerFrame: Int
    var bytesPerFrame: Int { statsLock.withLock { _bytesPerFrame } }
    var deliver: ((AudioChunk) -> Void)?
    var warn: ((String) -> Void)?
    var closed = false
    private var first = true

    // Garde de cadence : le format annoncé par le tap peut ne pas être celui que l'agrégat livre
    // (sortie qui change de cadence en cours d'appel, casque Bluetooth qui passe en mode appel à
    // 24 kHz, flux mono derrière un format stéréo). Sans correction, l'audio est lu trop vite ou trop
    // lentement et l'horloge commune bourre de silence. On mesure sur les horodatages du HAL et on
    // reconstruit le convertisseur dès que la mesure s'écarte de plus de 3 % du format annoncé.
    private struct RateWindow {
        var firstHost: UInt64 = 0, lastHost: UInt64 = 0
        var firstSample: Double = 0, lastSample: Double = 0, sampleValid = true
        var frames = 0, callbacks = 0
        mutating func reset() { self = RateWindow() }
    }
    private var window = RateWindow()
    private var corrections = 0
    /// Format des buffers du pool (celui de la construction). Après une correction, `format` diffère
    /// et chaque buffer est recopié dans un buffer au format corrigé avant conversion.
    private let poolFormat: AVAudioFormat
    private static let standardRates: [Double] = [8_000, 11_025, 16_000, 22_050, 24_000, 32_000, 44_100, 48_000, 88_200, 96_000, 176_400, 192_000]

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
        self.poolFormat = format
        self._bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
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
        let bytesPerFrame = self.bytesPerFrame
        guard let data = src.mData, bytesPerFrame > 0 else { return }
        let frames = Int(src.mDataByteSize) / bytesPerFrame
        guard frames > 0, let buf = pool.acquire() else {
            statsLock.withLock { _starved += 1 }
            return
        }
        let ts = inputTime.pointee
        let sampleValid = ts.mFlags.contains(.sampleTimeValid)
        let sampleTime = ts.mSampleTime
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
        queue.async { self.process(buf, hostTime: host, frames: frames, sampleTime: sampleTime, sampleValid: sampleValid) }
    }

    func process(_ buffer: AVAudioPCMBuffer, hostTime: UInt64, frames: Int, sampleTime: Double, sampleValid: Bool) {
        defer { pool.release(buffer) }
        guard !closed else { return }
        checkRate(hostTime: hostTime, frames: frames, sampleTime: sampleTime, sampleValid: sampleValid)
        let samples = resampler.convert(format == poolFormat ? buffer : rebuffer(buffer))
        guard !samples.isEmpty else { return }
        var nz = 0
        for s in samples where s != 0 { nz += 1 }
        if nz > 0 { statsLock.withLock { _nonZero += nz } }
        let chunk = AudioChunk(samples: samples, hostTime: hostTime, discontinuity: first)
        first = false
        deliver?(chunk)
    }

    /// Copie un buffer du pool dans un buffer au format corrigé (mêmes octets, nouvelle description).
    private func rebuffer(_ src: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        let n = src.frameLength
        guard n > 0, let dst = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n) else { return src }
        dst.frameLength = n
        let s = UnsafeMutableAudioBufferListPointer(src.mutableAudioBufferList)
        let d = UnsafeMutableAudioBufferListPointer(dst.mutableAudioBufferList)
        for c in 0..<min(s.count, d.count) {
            let bytes = min(Int(s[c].mDataByteSize), Int(d[c].mDataByteSize))
            if let sp = s[c].mData, let dp = d[c].mData, bytes > 0 { dp.copyMemory(from: sp, byteCount: bytes) }
            d[c].mDataByteSize = UInt32(bytes)
        }
        return dst
    }

    /// Fenêtres d'une seconde : cadence réelle = trames livrées par seconde d'horloge hôte
    /// (ou progression de `mSampleTime`, qui suit la cadence de l'agrégat quand elle est valide).
    private func checkRate(hostTime: UInt64, frames: Int, sampleTime: Double, sampleValid: Bool) {
        if window.callbacks == 0 {
            window.firstHost = hostTime; window.firstSample = sampleTime
        }
        window.lastHost = hostTime; window.lastSample = sampleTime
        window.sampleValid = window.sampleValid && sampleValid
        window.callbacks += 1
        // Le dernier bloc n'est pas encore écoulé : on compte les trames des blocs précédents.
        let seconds = HostClock.seconds(from: window.firstHost, to: window.lastHost)
        guard seconds >= 1.0, window.callbacks >= 4 else { window.frames += frames; return }
        let counted = Double(window.frames)
        let byHost = counted / seconds
        let sampleDelta = window.lastSample - window.firstSample
        // Horloge d'échantillons repartie de zéro (agrégat recréé, cadence changée) : fenêtre invalide.
        let sampleUsable = window.sampleValid && sampleDelta > 0
        let bySample = sampleUsable ? sampleDelta / seconds : byHost
        let sampleRatio = counted > 0 && sampleUsable ? sampleDelta / counted : 1
        window.reset()
        window.frames = frames
        guard bySample >= 4_000, bySample <= 400_000 else { return }

        let announced = format.sampleRate
        var channels = format.channelCount
        // Deux fois plus d'échantillons de temps que de trames comptées : les octets par trame sont
        // deux fois trop grands, le flux est mono derrière un format stéréo (ou l'inverse).
        if sampleRatio > 1.9, sampleRatio < 2.1, channels == 2 { channels = 1 }
        else if sampleRatio > 0.45, sampleRatio < 0.55, channels == 1 { channels = 2 }
        let measured = bySample
        let snapped = Self.standardRates.first(where: { abs($0 - measured) / $0 < 0.02 }) ?? measured
        let rateOK = abs(snapped - announced) / announced <= 0.03
        guard !rateOK || channels != format.channelCount else { return }
        guard corrections < 8 else { return }
        corrections += 1

        var asbd = format.streamDescription.pointee
        asbd.mSampleRate = snapped
        if channels != format.channelCount {
            let bytesPerChannel = asbd.mBytesPerFrame / max(1, asbd.mChannelsPerFrame)
            asbd.mChannelsPerFrame = channels
            if asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0 {
                asbd.mBytesPerFrame = bytesPerChannel * channels
                asbd.mBytesPerPacket = asbd.mBytesPerFrame * asbd.mFramesPerPacket
            }
        }
        guard let corrected = AVAudioFormat(streamDescription: &asbd), let r = Resampler(from: corrected) else {
            AudioLog.log(String(format: "tap : cadence mesurée %.0f Hz (annoncée %.0f), correction impossible", measured, announced))
            return
        }
        let before = CoreAudioProps.describe(format)
        format = corrected
        resampler = r
        statsLock.withLock { _bytesPerFrame = Int(asbd.mBytesPerFrame) }
        AudioLog.log(String(format: "tap : cadence réelle %.0f Hz (mesure hôte %.0f, ratio trames %.2f), format corrigé %@ -> %@",
                            measured, byHost, sampleRatio, before, CoreAudioProps.describe(corrected)))
        warn?("Cadence de l'audio système corrigée (\(Int(snapped)) Hz au lieu de \(Int(announced)))")
    }
}
