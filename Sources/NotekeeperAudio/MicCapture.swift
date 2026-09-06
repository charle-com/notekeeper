import Foundation
import AVFoundation
import AudioToolbox
import CoreAudio

/// Capture du micro par une unité CoreAudio `kAudioUnitSubType_HALOutput` en ENTRÉE SEULE.
///
/// Pourquoi pas `AVAudioEngine` : sur macOS, dès que l'engine touche `inputNode`, il accroche les
/// périphériques d'entrée ET de sortie par défaut. Avec des AirPods en sortie, le casque bascule
/// en profil mains-libres (24 kHz, son dégradé) dès le lancement. Ici l'AUHAL n'a que son bus
/// d'entrée activé, le device d'entrée est fixé explicitement AVANT `AudioUnitInitialize`, et le
/// device de sortie n'est jamais touché.
///
/// Pipeline : callback d'entrée HAL (thread IO, zéro allocation : pool de buffers) ->
/// `AudioUnitRender` dans un buffer préalloué -> file série de traitement -> `AVAudioConverter`
/// vers 16 kHz mono -> `onChunk`.
///
/// Suit le device d'entrée par défaut du système : s'il change (AirPods qui se connectent) ou
/// disparaît pendant la capture, l'unité est recréée sur le nouveau défaut. Le premier bloc qui
/// suit porte `discontinuity = true` pour que la session recale la piste sur l'horloge commune.
public final class MicCapture: @unchecked Sendable {

    /// Reçoit chaque bloc converti, depuis la file de traitement (jamais le main thread, jamais
    /// le thread IO).
    public var onChunk: ((AudioChunk) -> Void)? {
        get { sync { _onChunk } }
        set { sync { _onChunk = newValue } }
    }
    /// Avertissements non bloquants (device perdu, unité recréée…), depuis la file d'état.
    public var onWarning: ((String) -> Void)? {
        get { sync { _onWarning } }
        set { sync { _onWarning = newValue } }
    }

    public var deviceName: String { sync { _deviceName } }
    public var isRunning: Bool { sync { running } }
    public var nativeFormatDescription: String { sync { unitFormat.map(CoreAudioProps.describe) ?? "aucun" } }

    public init() {
        queueKey = DispatchSpecificKey<Void>()
        stateQueue.setSpecific(key: queueKey, value: ())
    }

    deinit {
        removeHardwareListeners()
        renderLock.withLock { renderContext = nil }
        disposeUnitUnsafe()
    }

    /// Crée l'unité sur le device d'entrée par défaut et démarre la capture.
    public func start() throws {
        try sync {
            guard !running else { return }
            do {
                try startUnsafe()
            } catch {
                // Une seule relance : une erreur HAL transitoire se résout en recréant l'unité.
                AudioLog.log("micro : premier démarrage raté (\(error)), nouvel essai")
                disposeUnitUnsafe()
                try startUnsafe()
            }
            installHardwareListeners()
            AudioLog.log("micro démarré : \(_deviceName), \(nativeFormatDescriptionUnsafe)")
        }
    }

    /// Arrête la capture. Au retour, plus aucun bloc ne sera livré.
    public func stop() {
        sync {
            guard running else { return }
            running = false
            removeHardwareListeners()
            stopUnitUnsafe()
            disposeUnitUnsafe()
            AudioLog.log("micro arrêté")
        }
    }

    // MARK: État interne (accès uniquement sur `stateQueue`)

    private let stateQueue = DispatchQueue(label: "fr.charlesneveu.notekeeper.mic.state")
    private let processQueue = DispatchQueue(label: "fr.charlesneveu.notekeeper.mic.process", qos: .userInitiated)
    private let queueKey: DispatchSpecificKey<Void>

    private var _onChunk: ((AudioChunk) -> Void)?
    private var _onWarning: ((String) -> Void)?
    private var _deviceName = "Micro"
    private var running = false

    private var unit: AudioUnit?
    private var unitDeviceID: AudioDeviceID = 0
    private var unitDeviceUID = ""
    private var unitFormat: AVAudioFormat?
    private var unitMaxFrames: AVAudioFrameCount = 4096

    /// Contexte lu par le callback HAL (thread IO), protégé par un verrou léger.
    private let renderLock = UnfairLock()
    private var renderContext: RenderContext?

    private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var rebuildWork: DispatchWorkItem?

    /// 16 buffers de 4096 frames = ~1,3 s de marge à 48 kHz.
    private static let poolSize = 16

    private var nativeFormatDescriptionUnsafe: String { unitFormat.map(CoreAudioProps.describe) ?? "aucun" }

    private func sync<T>(_ work: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil { return try work() }
        return try stateQueue.sync(execute: work)
    }

    // MARK: Démarrage / arrêt (sur stateQueue)

    private func startUnsafe() throws {
        try prepareUnit()
        guard let u = unit, let inFormat = unitFormat else {
            throw AudioCaptureError(37, "Unité audio non initialisée")
        }
        guard let resampler = Resampler(from: inFormat) else {
            throw AudioCaptureError(51, "Conversion \(CoreAudioProps.describe(inFormat)) vers 16 kHz mono impossible")
        }
        guard let pool = BufferPool(format: inFormat, frameCapacity: unitMaxFrames, count: Self.poolSize) else {
            throw AudioCaptureError(52, "Allocation des buffers de capture impossible")
        }
        let ctx = RenderContext(unit: u, pool: pool, resampler: resampler, queue: processQueue)
        // Handler snapshoté au démarrage : pas de lecture croisée entre les deux files (la
        // barrière de stop() fait déjà stateQueue -> processQueue, l'inverse bloquerait).
        ctx.deliver = _onChunk
        renderLock.withLock { renderContext = ctx }
        let status = AudioOutputUnitStart(u)
        guard status == noErr else {
            renderLock.withLock { renderContext = nil }
            disposeUnitUnsafe()
            throw AudioCaptureError(38, "AudioOutputUnitStart a échoué", status: status)
        }
        running = true
    }

    /// Stoppe l'unité et pose la barrière de traitement : au retour, plus aucun callback en vol.
    private func stopUnitUnsafe() {
        if let u = unit {
            let status = AudioOutputUnitStop(u)
            if status != noErr { AudioLog.log("micro : AudioOutputUnitStop status=\(status)") }
        }
        let ctx = renderLock.withLock { () -> RenderContext? in
            let c = renderContext
            renderContext = nil
            return c
        }
        processQueue.sync { ctx?.closed = true }
        if let ctx, ctx.starved > 0 {
            AudioLog.log("micro : \(ctx.starved) buffer(s) perdus, traitement en retard sur la capture")
        }
    }

    /// Device changé ou perdu pendant la capture : on recrée l'unité sur le nouveau défaut.
    private func rebuildUnsafe(reason: String) {
        guard running else { return }
        stopUnitUnsafe()
        disposeUnitUnsafe()
        do {
            try startUnsafe()
            AudioLog.log("micro recréé (\(reason)) : \(_deviceName), \(nativeFormatDescriptionUnsafe)")
            _onWarning?("Micro basculé sur \(_deviceName)")
        } catch {
            running = true   // on reste « en capture » pour retenter au prochain changement matériel
            AudioLog.log("micro : recréation impossible (\(reason)) : \(error)")
            _onWarning?("Micro indisponible : \(error.localizedDescription)")
        }
    }

    // MARK: Cycle de vie de l'unité AUHAL (sur stateQueue)

    private func prepareUnit() throws {
        guard let deviceID = CoreAudioProps.defaultInputDevice(), CoreAudioProps.isAlive(deviceID),
              CoreAudioProps.channelCount(deviceID, scope: kAudioDevicePropertyScopeInput) > 0 else {
            throw AudioCaptureError(40, "Aucun périphérique d'entrée disponible")
        }
        let uid = CoreAudioProps.deviceUID(deviceID) ?? ""
        let name = CoreAudioProps.deviceName(deviceID) ?? "Micro"
        if unit != nil, unitDeviceID == deviceID, unitDeviceUID == uid {
            _deviceName = name
            return
        }
        disposeUnitUnsafe()
        try createUnit(device: deviceID)
        unitDeviceID = deviceID
        unitDeviceUID = uid
        _deviceName = name
    }

    private func createUnit(device: AudioDeviceID) throws {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else {
            throw AudioCaptureError(30, "Composant AUHAL introuvable")
        }
        var newUnit: AudioUnit?
        var status = AudioComponentInstanceNew(comp, &newUnit)
        guard status == noErr, let u = newUnit else {
            throw AudioCaptureError(31, "AudioComponentInstanceNew a échoué", status: status)
        }

        var initialized = false
        do {
            let u32 = UInt32(MemoryLayout<UInt32>.size)
            var one: UInt32 = 1
            var zero: UInt32 = 0
            // Entrée activée sur le bus 1, sortie DÉSACTIVÉE sur le bus 0 : l'unité ne touchera
            // jamais le device de sortie. L'ordre EnableIO puis CurrentDevice est imposé par l'AUHAL.
            status = AudioUnitSetProperty(u, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &one, u32)
            guard status == noErr else { throw AudioCaptureError(32, "EnableIO entrée (bus 1) a échoué", status: status) }
            status = AudioUnitSetProperty(u, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &zero, u32)
            guard status == noErr else { throw AudioCaptureError(32, "EnableIO sortie (bus 0) a échoué", status: status) }

            // CurrentDevice AVANT AudioUnitInitialize : posé après, l'unité aurait déjà accroché le
            // device d'entrée par défaut.
            var dev = device
            status = AudioUnitSetProperty(u, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                          &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
            guard status == noErr else { throw AudioCaptureError(33, "CurrentDevice a échoué", status: status) }

            // Format du device côté entrée : on garde son sample rate, l'AUHAL ne resample pas.
            var deviceASBD = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            status = AudioUnitGetProperty(u, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &deviceASBD, &size)
            guard status == noErr else { throw AudioCaptureError(34, "Lecture du format device a échoué", status: status) }
            guard deviceASBD.mSampleRate > 0, deviceASBD.mChannelsPerFrame > 0 else {
                throw AudioCaptureError(10, "Format d'entrée invalide (\(deviceASBD.mSampleRate) Hz / \(deviceASBD.mChannelsPerFrame) ch)")
            }

            let asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            var clientASBD = CoreAudioProps.floatASBD(sampleRate: deviceASBD.mSampleRate, channels: 1)
            status = AudioUnitSetProperty(u, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &clientASBD, asbdSize)
            if status != noErr, deviceASBD.mChannelsPerFrame > 1 {
                // Quelques devices refusent le downmix mono côté AUHAL : on prend leur nombre de
                // canaux natif, c'est le Resampler qui ramènera le flux en mono.
                clientASBD = CoreAudioProps.floatASBD(sampleRate: deviceASBD.mSampleRate, channels: deviceASBD.mChannelsPerFrame)
                status = AudioUnitSetProperty(u, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &clientASBD, asbdSize)
            }
            guard status == noErr else { throw AudioCaptureError(35, "Format client (bus 1) refusé", status: status) }

            // Marge sur la taille de tranche : un device avec un gros buffer IO ferait échouer
            // AudioUnitRender avec la valeur par défaut.
            let deviceFrames = CoreAudioProps.uint32(device, kAudioDevicePropertyBufferFrameSize) ?? 0
            var maxFrames = max(UInt32(4096), deviceFrames)
            status = AudioUnitSetProperty(u, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, u32)
            guard status == noErr else { throw AudioCaptureError(36, "MaximumFramesPerSlice refusé", status: status) }

            var cb = AURenderCallbackStruct(inputProc: micCaptureInputCallback,
                                            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
            status = AudioUnitSetProperty(u, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
                                          &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
            guard status == noErr else { throw AudioCaptureError(39, "SetInputCallback a échoué", status: status) }

            status = AudioUnitInitialize(u)
            guard status == noErr else { throw AudioCaptureError(37, "AudioUnitInitialize a échoué", status: status) }
            initialized = true

            guard let fmt = AVAudioFormat(streamDescription: &clientASBD) else {
                throw AudioCaptureError(35, "AVAudioFormat invalide")
            }
            unit = u
            unitFormat = fmt
            unitMaxFrames = AVAudioFrameCount(maxFrames)
        } catch {
            if initialized { AudioUnitUninitialize(u) }
            AudioComponentInstanceDispose(u)
            throw error
        }
    }

    private func disposeUnitUnsafe() {
        guard let u = unit else { return }
        unit = nil
        unitFormat = nil
        unitDeviceID = 0
        unitDeviceUID = ""
        unitMaxFrames = 4096
        AudioOutputUnitStop(u)
        AudioUnitUninitialize(u)
        AudioComponentInstanceDispose(u)
    }

    // MARK: Callback HAL (thread IO temps réel)

    /// Rend les frames dans un buffer préalloué et les passe à la file de traitement. Aucune
    /// allocation audio ici : ni conversion, ni `try`.
    fileprivate func render(flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                            timestamp: UnsafePointer<AudioTimeStamp>,
                            bus: UInt32, frames: UInt32) -> OSStatus {
        guard frames > 0, let ctx = renderLock.withLock({ renderContext }) else { return noErr }
        guard let buf = ctx.pool.acquire() else {
            ctx.noteStarved()
            return noErr
        }
        guard frames <= buf.frameCapacity else {
            ctx.pool.release(buf)
            return noErr
        }
        buf.frameLength = frames
        let status = AudioUnitRender(ctx.unit, flags, timestamp, bus, frames, buf.mutableAudioBufferList)
        guard status == noErr else {
            ctx.pool.release(buf)
            return noErr
        }
        let host = HostClock.hostTime(of: timestamp)
        ctx.queue.async { ctx.process(buf, hostTime: host) }
        // Toujours noErr : renvoyer une erreur ferait démonter la chaîne par le HAL.
        return noErr
    }

    // MARK: Listeners hardware (blocs exécutés sur stateQueue)

    private func installHardwareListeners() {
        guard listeners.isEmpty else { return }
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice] {
            var addr = CoreAudioProps.address(selector)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.hardwareChangedUnsafe(selector: selector)
            }
            if AudioObjectAddPropertyListenerBlock(CoreAudioProps.system, &addr, stateQueue, block) == noErr {
                listeners.append((addr, block))
            }
        }
    }

    private func removeHardwareListeners() {
        for (address, block) in listeners {
            var addr = address
            AudioObjectRemovePropertyListenerBlock(CoreAudioProps.system, &addr, stateQueue, block)
        }
        listeners.removeAll()
        rebuildWork?.cancel()
        rebuildWork = nil
    }

    private func hardwareChangedUnsafe(selector: AudioObjectPropertySelector) {
        guard running, unit != nil else { return }
        let current = CoreAudioProps.defaultInputDevice()
        let stillThere = CoreAudioProps.isAlive(unitDeviceID)
            && CoreAudioProps.deviceUID(unitDeviceID) == unitDeviceUID
        let defaultChanged = current != nil && current != unitDeviceID
        guard !stillThere || defaultChanged else { return }
        // Les changements arrivent en rafale (déconnexion puis nouveau défaut) : on laisse
        // le HAL se poser avant de recréer l'unité.
        rebuildWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.rebuildUnsafe(reason: stillThere ? "nouveau micro par défaut" : "micro déconnecté")
        }
        rebuildWork = work
        stateQueue.asyncAfter(deadline: .now() + 0.4, execute: work)
    }
}

// MARK: - Contexte de rendu

/// Ce que voit le thread IO : unité, pool et file de traitement. La conversion et la livraison
/// tournent sur `queue` (série) ; `closed` est posé sous barrière par `stop()`.
private final class RenderContext {
    let unit: AudioUnit
    let pool: BufferPool
    let resampler: Resampler
    let queue: DispatchQueue
    var deliver: ((AudioChunk) -> Void)?
    var closed = false
    private var first = true
    private let starvedLock = UnfairLock()
    private var _starved = 0
    var starved: Int { starvedLock.withLock { _starved } }

    init(unit: AudioUnit, pool: BufferPool, resampler: Resampler, queue: DispatchQueue) {
        self.unit = unit; self.pool = pool; self.resampler = resampler; self.queue = queue
    }

    func noteStarved() { starvedLock.withLock { _starved += 1 } }

    func process(_ buffer: AVAudioPCMBuffer, hostTime: UInt64) {
        defer { pool.release(buffer) }
        guard !closed else { return }
        let samples = resampler.convert(buffer)
        guard !samples.isEmpty else { return }
        let chunk = AudioChunk(samples: samples, hostTime: hostTime, discontinuity: first)
        first = false
        deliver?(chunk)
    }
}

// MARK: - Callback C

/// Point d'entrée HAL : pointeur de fonction C sans capture, qui retrouve la capture via le refCon.
/// Aucune rétention : `AudioOutputUnitStop` est synchrone, plus aucun callback n'est en vol après.
private let micCaptureInputCallback: AURenderCallback = { refCon, flags, timestamp, bus, frames, _ in
    let capture = Unmanaged<MicCapture>.fromOpaque(refCon).takeUnretainedValue()
    return capture.render(flags: flags, timestamp: timestamp, bus: bus, frames: frames)
}
