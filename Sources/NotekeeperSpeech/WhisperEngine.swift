import CoreML
import Foundation
import WhisperKit

/// Pipeline Whisper on-device (WhisperKit, CoreML). Un acteur : un seul pipeline, chargé une fois,
/// avec choix automatique du profil de calcul et watchdogs contre les gels CoreML.
///
/// Profils, du plus rapide au plus sûr (mesure du 20/08/2026 sur ce Mac, 32 s de parole) :
/// « tout Neural Engine » 1,9 s, « encodeur ANE + décodeur CPU » 8,6 s. Le TOUT PREMIER chargement
/// d'un graphe compile CoreML (2 à 5 min), les suivants repartent du cache système en 1 à 2 s.
public actor WhisperEngine {

    public static let modelVariant = "openai_whisper-large-v3-v20240930_turbo_632MB"

    // MARK: - Profils de calcul

    public struct ComputeProfile: Equatable, Sendable {
        public let id: String
        public let label: String
        let mel: MLComputeUnits
        let audioEncoder: MLComputeUnits
        let textDecoder: MLComputeUnits
        let prefill: MLComputeUnits

        var options: ModelComputeOptions {
            ModelComputeOptions(melCompute: mel, audioEncoderCompute: audioEncoder,
                                textDecoderCompute: textDecoder, prefillCompute: prefill)
        }
    }

    public static let profiles: [ComputeProfile] = [
        ComputeProfile(id: "ane-full", label: "tout Neural Engine",
                       mel: .cpuOnly, audioEncoder: .cpuAndNeuralEngine,
                       textDecoder: .cpuAndNeuralEngine, prefill: .cpuAndNeuralEngine),
        ComputeProfile(id: "ane-encoder", label: "encodeur Neural Engine + décodeur CPU",
                       mel: .cpuOnly, audioEncoder: .cpuAndNeuralEngine, textDecoder: .cpuOnly, prefill: .cpuOnly),
        ComputeProfile(id: "cpu-only", label: "tout CPU (filet de sécurité)",
                       mel: .cpuOnly, audioEncoder: .cpuOnly, textDecoder: .cpuOnly, prefill: .cpuOnly),
    ]

    private enum Keys {
        static let profileID = "speech.whisper.profile.id"
        static let profileOSBuild = "speech.whisper.profile.osBuild"
        static let profileModel = "speech.whisper.profile.model"
        static let profileDate = "speech.whisper.profile.date"
        static let compiledPrefix = "speech.whisper.compiled."
        static let probationID = "speech.whisper.probation.id"
        static let probationCount = "speech.whisper.probation.count"
    }

    /// Chargement d'un graphe déjà compilé pour ce build macOS : au-delà, c'est une panne.
    private static let loadTimeoutSeconds: Double = 120
    /// Tout premier chargement d'un graphe (compilation CoreML comprise).
    private static let firstLoadTimeoutSeconds: Double = 900
    /// Décodage du bruit de réchauffage.
    private static let warmTimeoutSeconds: Double = 60
    /// Un profil dégradé mémorisé est re-sondé après ce délai (l'ANE a pu se remettre à marcher).
    private static let profileMaxAge: TimeInterval = 14 * 24 * 3600

    // MARK: - État

    private var pipeline: WhisperKit?
    public private(set) var activeProfile: ComputeProfile?
    private var loading: Task<Void, Error>?
    private var executorStorage: AnyObject?
    private var executorSerial = 0
    /// Date du chargement réussi, pour le rapport.
    public private(set) var lastLoadDuration: TimeInterval = 0

    public init() {}

    public var isLoaded: Bool { pipeline != nil }

    // MARK: - Préparation

    /// Copie ou téléchargement du modèle, puis chargement sous watchdog, profil par profil,
    /// réchauffage sur 1 s de bruit. Idempotent ; les appels concurrents partagent le même chargement.
    public func prepare(progress: @escaping (String) -> Void) async throws {
        if pipeline != nil { return }
        if let loading {
            try await loading.value
            return
        }
        let task = Task { try await self.load(progress: progress) }
        loading = task
        defer { loading = nil }
        try await task.value
    }

    private func load(progress: @escaping (String) -> Void) async throws {
        let t0 = Date()
        let model = Self.modelVariant
        let folder = try await ensureModelOnDisk(progress: progress)

        let candidates: [ComputeProfile]
        if let cached = Self.cachedProfile(model: model) {
            SpeechLog.log("profil de calcul mémorisé : \(cached.id)")
            candidates = [cached] + Self.profiles.drop(while: { $0 != cached }).dropFirst()
        } else {
            SpeechLog.log("sondage des profils de calcul pour macOS \(Self.osBuild()) / \(model)")
            candidates = Self.profiles
        }

        var lastError: Error?
        for p in candidates {
            let compiled = Self.graphCompiled(model: model, profile: p)
            progress(compiled ? "Chargement de Whisper (\(p.label))"
                              : "Première compilation de Whisper (\(p.label)), jusqu'à 5 minutes")
            do {
                let t1 = Date()
                let kit = try await loadPipeline(model: model, folder: folder, profile: p)
                SpeechLog.log(String(format: "pipeline %@ chargé en %.1f s", p.id, Date().timeIntervalSince(t1)))
                progress("Réchauffage du décodeur")
                let t2 = Date()
                try await runIsolated(timeout: Self.warmTimeoutSeconds) {
                    let _: [TranscriptionResult] = try await kit.transcribe(
                        audioArray: Self.warmupNoise(), decodeOptions: Self.warmupOptions(), callback: nil)
                }
                SpeechLog.log(String(format: "réchauffage en %.2f s (profil %@)", Date().timeIntervalSince(t2), p.id))
                pipeline = kit
                activeProfile = p
                Self.persistProfile(p, model: model)
                Self.resetProbation()
                lastLoadDuration = Date().timeIntervalSince(t0)
                SpeechLog.log(String(format: "Whisper prêt en %.1f s, profil %@ [%@]", lastLoadDuration, p.id, p.label))
                progress("Whisper prêt (\(p.label))")
                return
            } catch {
                lastError = error
                SpeechLog.log("profil \(p.id) écarté : \(error)")
                renewInferenceExecutor()
            }
        }
        throw lastError ?? SpeechError.modelUnavailable("Aucun profil de calcul n'a pu charger Whisper")
    }

    /// Instancie le pipeline sous watchdog : budget court si ce graphe est déjà compilé pour ce
    /// build macOS, long sinon. Un budget court qui expire sur un graphe marqué compilé signale un
    /// cache CoreML reconstruit : on rejoue le même profil avec le budget long avant de dégrader.
    ///
    /// Mesure du 06/09/2026 (M5, macOS 26.6.2) : lancement 1 = 169 s (ANECompilerService), lancement 2
    /// = 155 s encore (second passage de compilation, dans le processus cette fois), lancement 3 = 1,3 s.
    /// Le marqueur « compilé » n'est donc posé qu'après un chargement rapide (< 60 s).
    private func loadPipeline(model: String, folder: URL, profile p: ComputeProfile) async throws -> WhisperKit {
        var budgets = Self.graphCompiled(model: model, profile: p)
            ? [Self.loadTimeoutSeconds, Self.firstLoadTimeoutSeconds]
            : [Self.firstLoadTimeoutSeconds]
        while true {
            let budget = budgets.removeFirst()
            do {
                let t0 = Date()
                let kit = try await runIsolated(timeout: budget) {
                    try await Self.makePipeline(model: model, folder: folder, profile: p)
                }
                Self.markGraphCompiled(model: model, profile: p, compiled: Date().timeIntervalSince(t0) < 60)
                return kit
            } catch let error as SpeechError {
                guard case .timeout = error, !budgets.isEmpty else { throw error }
                SpeechLog.log("profil \(p.id) marqué compilé mais chargement > \(Int(budget)) s : nouvel essai avec \(Int(budgets[0])) s")
                Self.markGraphCompiled(model: model, profile: p, compiled: false)
                renewInferenceExecutor()
            }
        }
    }

    private static func makePipeline(model: String, folder: URL, profile: ComputeProfile) async throws -> WhisperKit {
        SpeechLog.log("init pipeline, modèle \(model), profil \(profile.id)")
        // `download: false` + `modelFolder` : le modèle est déjà sur disque, aucun accès réseau ici.
        let config = WhisperKitConfig(
            model: model,
            downloadBase: downloadBase(),
            modelFolder: folder.path,
            computeOptions: profile.options,
            verbose: false,
            logLevel: .error,
            download: false
        )
        return try await WhisperKit(config)
    }

    /// 2 s de bruit : WhisperKit ne décode que `seek < fin - windowClipTime` (1 s), donc 1 s d'audio ne
    /// ferait tourner ni l'encodeur ni le décodeur (réchauffage rendu en 10 ms, vu le 06/09/2026).
    private static func warmupNoise() -> [Float] {
        var g = SystemRandomNumberGenerator()
        return (0..<32_000).map { _ in Float.random(in: -0.01...0.01, using: &g) }
    }

    /// Même règle pour les énoncés : en dessous de 2 s, on complète de silence, sinon rien n'est décodé.
    private static let minimumDecodeSamples = 32_000

    /// Seuils désactivés et sortie bornée à 24 tokens : sur du bruit, `noSpeechThreshold` court-circuitait
    /// le décodeur (0,04 s) et le premier vrai décodage payait la mise en route.
    private static func warmupOptions() -> DecodingOptions {
        DecodingOptions(verbose: false, task: .transcribe, language: "fr", temperature: 0,
                        temperatureFallbackCount: 0, sampleLength: 24, usePrefillPrompt: true, usePrefillCache: true,
                        skipSpecialTokens: true, withoutTimestamps: true, compressionRatioThreshold: nil,
                        logProbThreshold: nil, firstTokenLogProbThreshold: nil, noSpeechThreshold: nil,
                        chunkingStrategy: ChunkingStrategy.none)
    }

    /// Injection du dictionnaire en `promptTokens` : DÉSACTIVÉE par défaut.
    ///
    /// WhisperKit 0.18 : au-delà de 2 tokens de prompt forcés, le décodeur prédit `<|endoftext|>` dès la
    /// sortie du prompt et le segment ressort vide (mesure VoxPrompt du 20/08/2026, indépendante du contenu
    /// et des options ; confirmée ici le 06/09/2026 sur les deux pistes de test, profil tout ANE : résultat
    /// vide puis rejeu sans prompt). `usePrefillPrompt: false` ferait revenir le texte mais la langue ne serait
    /// plus forcée. En attendant un correctif WhisperKit, le dictionnaire est appliqué en post-traitement
    /// (`DictionaryCorrector`). Le chemin prompt reste écrit, avec filet de rejeu sans prompt.
    public static var promptInjectionEnabled = false

    // MARK: - Transcription

    /// Transcrit des échantillons 16 kHz mono. `promptTerms` (dictionnaire) est injecté en
    /// `promptTokens` pour orienter l'orthographe des noms propres. `timestamps` : horodatages
    /// réels de Whisper (passage final) ; sinon `withoutTimestamps`, moins de boucles en live.
    public func transcribe(samples: [Float], language: String, promptTerms: [String],
                           timestamps: Bool) async throws -> [(start: TimeInterval, end: TimeInterval, text: String)] {
        let kit = try await ensureLoaded()
        let audioSeconds = Double(samples.count) / 16_000
        guard audioSeconds >= 0.1 else { return [] }
        var samples = samples
        if samples.count < Self.minimumDecodeSamples {
            samples.append(contentsOf: [Float](repeating: 0, count: Self.minimumDecodeSamples - samples.count))
        }

        let prompt = Self.promptInjectionEnabled ? Self.promptTokens(kit: kit, terms: promptTerms) : nil
        let corrector = DictionaryCorrector(terms: promptTerms)
        // `usePrefillCache` : WhisperKit coupe de lui-même le cache KV de prefill dès qu'il y a un
        // prompt ; on le rend explicite. `usePrefillPrompt` reste vrai : les tokens de prompt sont
        // prépendus aux tokens de prefill (langue, tâche, timestamps).
        var options = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: language,
            temperature: 0.0,
            temperatureFallbackCount: 3,
            usePrefillPrompt: true,
            usePrefillCache: prompt == nil,
            skipSpecialTokens: true,
            withoutTimestamps: !timestamps,
            promptTokens: prompt,
            compressionRatioThreshold: 2.4,
            logProbThreshold: -1.0,
            noSpeechThreshold: 0.6,
            chunkingStrategy: .vad
        )

        let timeout = max(20.0, audioSeconds * 5.0)
        var results = try await decode(kit: kit, samples: samples, options: options, timeout: timeout)

        // Un prompt initial peut faire rendre un résultat vide : on rejoue une fois sans prompt
        // plutôt que de perdre une phrase en silence.
        if prompt != nil, results.allSatisfy({ $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            SpeechLog.log("résultat vide avec prompt : nouvel essai sans prompt")
            options.promptTokens = nil
            options.usePrefillCache = true
            results = (try? await decode(kit: kit, samples: samples, options: options, timeout: timeout)) ?? results
        }

        var out: [(start: TimeInterval, end: TimeInterval, text: String)] = []
        for r in results {
            for s in r.segments {
                let text = corrector.apply(HallucinationFilter.clean(s.text))
                guard !text.isEmpty else { continue }
                let start = max(0, TimeInterval(s.start))
                let end = min(audioSeconds, max(start, TimeInterval(s.end)))
                out.append((start: start, end: end, text: text))
            }
        }
        return out.sorted { $0.start < $1.start }
    }

    private func decode(kit: WhisperKit, samples: [Float], options: DecodingOptions,
                        timeout: Double) async throws -> [TranscriptionResult] {
        let monitor = RepetitionMonitor()
        let t0 = Date()
        do {
            let results = try await runIsolated(timeout: timeout) {
                let r: [TranscriptionResult] = try await kit.transcribe(audioArray: samples, decodeOptions: options) { progress in
                    if Task.isCancelled { return false }
                    if monitor.shouldAbort(progress.text) {
                        SpeechLog.log("boucle de répétition détectée en cours de décodage : arrêt")
                        return false
                    }
                    return nil
                }
                return r
            }
            SpeechLog.log(String(format: "décodage %.1f s d'audio en %.2f s (%d résultats)",
                                 Double(samples.count) / 16_000, Date().timeIntervalSince(t0), results.count))
            Self.resetProbation()
            return results
        } catch {
            if case SpeechError.timeout = error {
                SpeechLog.log("décodage figé au-delà de \(Int(timeout)) s : pipeline jeté")
                poisonPipeline()
            }
            throw error
        }
    }

    /// Pipeline courant, rechargé s'il a été jeté après un gel.
    private func ensureLoaded() async throws -> WhisperKit {
        if let pipeline { return pipeline }
        try await prepare(progress: { _ in })
        guard let pipeline else { throw SpeechError.notReady }
        return pipeline
    }

    /// Décharge le pipeline (poids CoreML, tampons ANE) : la mémoire revient au niveau d'une app vide.
    /// Le profil de calcul retenu reste mémorisé, le prochain `prepare` recharge en quelques secondes.
    public func unload() {
        guard pipeline != nil else { return }
        pipeline = nil
        renewInferenceExecutor()
        SpeechLog.log("Whisper déchargé")
    }

    /// Après un timeout, l'instance est suspecte (un thread CoreML probablement figé) : on la jette.
    /// Deux gels consécutifs sur le même profil font passer au profil suivant au prochain chargement.
    private func poisonPipeline() {
        pipeline = nil
        renewInferenceExecutor()
        guard let current = activeProfile else { return }
        activeProfile = nil
        let d = UserDefaults.standard
        var count = d.integer(forKey: Keys.probationCount)
        count = (d.string(forKey: Keys.probationID) == current.id) ? count + 1 : 1
        d.set(current.id, forKey: Keys.probationID)
        d.set(count, forKey: Keys.probationCount)
        guard count >= 2 else {
            SpeechLog.log("gel #1 sur \(current.id) : probation, profil conservé")
            return
        }
        if let idx = Self.profiles.firstIndex(of: current), idx + 1 < Self.profiles.count {
            let next = Self.profiles[idx + 1]
            Self.persistProfile(next, model: Self.modelVariant)
            SpeechLog.log("deux gels sur \(current.id) : repli sur \(next.id) au prochain chargement")
        }
        Self.resetProbation()
    }

    /// Dictionnaire : termes encodés par le tokenizer, 100 tokens maximum.
    private static func promptTokens(kit: WhisperKit, terms: [String]) -> [Int]? {
        let cleaned = terms.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !cleaned.isEmpty, let tokenizer = kit.tokenizer else { return nil }
        let tokens = Array(tokenizer.encode(text: " " + cleaned.joined(separator: ", ")).prefix(100))
        return tokens.isEmpty ? nil : tokens
    }

    // MARK: - Exécution isolée

    @available(macOS 15.0, *)
    private func inferenceExecutor() -> InferenceExecutor {
        if let existing = executorStorage as? InferenceExecutor { return existing }
        executorSerial += 1
        let fresh = InferenceExecutor(label: "fr.charlesneveu.notekeeper.inference.\(executorSerial)")
        executorStorage = fresh
        return fresh
    }

    private func renewInferenceExecutor() {
        guard executorStorage != nil else { return }
        executorStorage = nil
        SpeechLog.log("exécuteur d'inférence renouvelé")
    }

    /// Exécute `work` hors du pool coopératif (macOS 15+) sous watchdog.
    private func runIsolated<T: Sendable>(timeout: Double, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        if #available(macOS 15.0, *) {
            let executor = inferenceExecutor()
            return try await Watchdog.run(seconds: timeout) {
                try await withTaskExecutorPreference(executor) { try await work() }
            }
        }
        return try await Watchdog.run(seconds: timeout, work)
    }

    // MARK: - Modèle sur disque

    /// `~/Library/Application Support/Notekeeper/huggingface`
    public static func downloadBase() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Notekeeper", isDirectory: true)
            .appendingPathComponent("huggingface", isDirectory: true)
    }

    private static func voxPromptBase() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("VoxPrompt", isDirectory: true)
            .appendingPathComponent("huggingface", isDirectory: true)
    }

    private static func modelsRoot(_ base: URL) -> URL {
        base.appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("argmaxinc", isDirectory: true)
            .appendingPathComponent("whisperkit-coreml", isDirectory: true)
    }

    private static func isCompleteModelFolder(_ dir: URL) -> Bool {
        let fm = FileManager.default
        for name in ["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc"] {
            let marker = dir.appendingPathComponent(name, isDirectory: true).appendingPathComponent("coremldata.bin")
            guard fm.fileExists(atPath: marker.path) else { return false }
        }
        return fm.fileExists(atPath: dir.appendingPathComponent("config.json").path)
    }

    /// Dossier du modèle : déjà là, sinon copié depuis VoxPrompt (clone APFS), sinon téléchargé.
    private func ensureModelOnDisk(progress: @escaping (String) -> Void) async throws -> URL {
        let fm = FileManager.default
        let base = Self.downloadBase()
        let dst = Self.modelsRoot(base).appendingPathComponent(Self.modelVariant, isDirectory: true)
        if Self.isCompleteModelFolder(dst) { return dst }

        if let vox = Self.voxPromptBase() {
            let src = Self.modelsRoot(vox).appendingPathComponent(Self.modelVariant, isDirectory: true)
            if Self.isCompleteModelFolder(src) {
                progress("Copie du modèle Whisper depuis VoxPrompt")
                SpeechLog.log("copie du modèle depuis \(src.path)")
                do {
                    try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if fm.fileExists(atPath: dst.path) { try? fm.removeItem(at: dst) }
                    try fm.copyItem(at: src, to: dst)
                    // Le tokenizer (models/openai/whisper-large-v3) évite un accès réseau au chargement.
                    let srcTok = vox.appendingPathComponent("models/openai", isDirectory: true)
                    let dstTok = base.appendingPathComponent("models/openai", isDirectory: true)
                    if fm.fileExists(atPath: srcTok.path), !fm.fileExists(atPath: dstTok.path) {
                        try? fm.copyItem(at: srcTok, to: dstTok)
                    }
                    if Self.isCompleteModelFolder(dst) { return dst }
                } catch {
                    SpeechLog.log("copie depuis VoxPrompt en échec : \(error)")
                }
            }
        }

        progress("Téléchargement du modèle Whisper (632 Mo)")
        SpeechLog.log("téléchargement de \(Self.modelVariant)")
        let lastPercent = PercentBox()
        do {
            let url = try await WhisperKit.download(variant: Self.modelVariant, downloadBase: base) { p in
                let pct = Int(p.fractionCompleted * 100)
                if lastPercent.update(pct) { progress("Téléchargement du modèle Whisper : \(pct) %") }
            }
            SpeechLog.log("modèle téléchargé : \(url.path)")
            return url
        } catch {
            SpeechLog.log("téléchargement en échec : \(error)")
            throw SpeechError.modelUnavailable("Modèle Whisper indisponible (réseau ?) : \(error.localizedDescription)")
        }
    }

    // MARK: - Mémorisation du profil (UserDefaults, par build macOS et modèle)

    private static func osBuild() -> String {
        var size = 0
        if sysctlbyname("kern.osversion", nil, &size, nil, 0) != 0 || size == 0 { return "unknown" }
        var buf = [CChar](repeating: 0, count: size)
        if sysctlbyname("kern.osversion", &buf, &size, nil, 0) != 0 { return "unknown" }
        return String(cString: buf)
    }

    private static func cachedProfile(model: String) -> ComputeProfile? {
        let d = UserDefaults.standard
        guard d.string(forKey: Keys.profileOSBuild) == osBuild(), d.string(forKey: Keys.profileModel) == model,
              let id = d.string(forKey: Keys.profileID), let p = profiles.first(where: { $0.id == id }) else { return nil }
        let age = Date().timeIntervalSince1970 - d.double(forKey: Keys.profileDate)
        if p != profiles[0], age > profileMaxAge {
            SpeechLog.log("profil dégradé \(p.id) trop ancien : nouveau sondage")
            return nil
        }
        return p
    }

    private static func persistProfile(_ p: ComputeProfile, model: String) {
        let d = UserDefaults.standard
        d.set(p.id, forKey: Keys.profileID)
        d.set(osBuild(), forKey: Keys.profileOSBuild)
        d.set(model, forKey: Keys.profileModel)
        d.set(Date().timeIntervalSince1970, forKey: Keys.profileDate)
    }

    /// Le cache CoreML/ANE est lié à l'identité de l'exécutable : chaque nouveau binaire recompile
    /// (vu le 06/09/2026 : 1,3 s puis 178 s après un simple rebuild). La clé porte donc l'empreinte
    /// de l'exécutable (date de modification), pour repartir en budget long dès le premier lancement.
    private static let executableStamp: String = {
        guard let url = Bundle.main.executableURL,
              let date = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        else { return "0" }
        return String(Int(date.timeIntervalSince1970))
    }()

    private static func compiledKey(model: String, profile: ComputeProfile) -> String {
        "\(Keys.compiledPrefix)\(osBuild()).\(executableStamp).\(model).\(profile.id)"
    }

    private static func graphCompiled(model: String, profile: ComputeProfile) -> Bool {
        UserDefaults.standard.bool(forKey: compiledKey(model: model, profile: profile))
    }

    private static func markGraphCompiled(model: String, profile: ComputeProfile, compiled: Bool) {
        let key = compiledKey(model: model, profile: profile)
        if compiled { UserDefaults.standard.set(true, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
    }

    private static func resetProbation() {
        let d = UserDefaults.standard
        d.removeObject(forKey: Keys.probationID)
        d.removeObject(forKey: Keys.probationCount)
    }
}

/// Dédoublonnage des pourcentages de téléchargement.
private final class PercentBox: @unchecked Sendable {
    private let lock = NSLock()
    private var last = -1
    func update(_ pct: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard pct != last else { return false }
        last = pct
        return true
    }
}

/// Détection de boucle pendant le décodage : si le texte partiel se termine par un n-gramme répété
/// quatre fois, le décodeur tourne en rond et on le coupe à la source.
final class RepetitionMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var lastChecked = 0
    func shouldAbort(_ text: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        // Vérification tous les 8 caractères ajoutés, pour rester léger.
        guard text.count - lastChecked >= 8 else { return false }
        lastChecked = text.count
        return HallucinationFilter.hasLoop(text)
    }
}
