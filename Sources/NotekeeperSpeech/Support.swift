import AVFoundation
import Foundation
import os

// MARK: - Journal

/// Journal du module parole : stderr horodaté (visible dans les exécutables de test) + os_log.
public enum SpeechLog {
    private static let logger = Logger(subsystem: "fr.charlesneveu.notekeeper", category: "speech")
    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    public static func log(_ message: String) {
        logger.info("\(message, privacy: .public)")
        let line = "[\(clock.string(from: Date()))] speech: \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
}

// MARK: - Erreurs

public enum SpeechError: Error, LocalizedError {
    /// Chargement ou décodage figé au-delà du budget.
    case timeout(seconds: Double)
    case modelUnavailable(String)
    case audioUnreadable(String)
    case notReady

    public var errorDescription: String? {
        switch self {
        case .timeout(let s): return String(format: "Délai dépassé (%.0f s)", s)
        case .modelUnavailable(let m): return m
        case .audioUnreadable(let m): return "Audio illisible : \(m)"
        case .notReady: return "Le moteur de parole n'est pas prêt"
        }
    }
}

// MARK: - Watchdog

/// Garde de résolution unique d'une continuation (un double `resume` ferait planter l'app).
actor ResumeOnce {
    private var claimed = false
    func claim() -> Bool {
        if claimed { return false }
        claimed = true
        return true
    }
}

/// Porte-tâche annulable, tolérant à l'ordre : si `cancel()` arrive avant `arm()`, la tâche est
/// annulée dès qu'elle est confiée.
final class CancelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var cancelled = false

    func arm(_ t: Task<Void, Never>) {
        lock.lock()
        if cancelled { lock.unlock(); t.cancel(); return }
        task = t
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let t = task
        task = nil
        lock.unlock()
        t?.cancel()
    }
}

enum Watchdog {
    /// Exécute `work` avec un délai maximum. La continuation est résolue au PREMIER des deux
    /// événements (fin du travail ou échéance) : un décodage figé sur un deadlock natif, insensible
    /// à l'annulation, est simplement abandonné en arrière-plan au lieu de bloquer l'appelant.
    static func run<T: Sendable>(seconds: Double, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let gate = ResumeOnce()
        let timer = CancelBox()
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            let workTask = Task.detached(priority: .userInitiated) {
                do {
                    let value = try await work()
                    if await gate.claim() { timer.cancel(); cont.resume(returning: value) }
                } catch {
                    if await gate.claim() { timer.cancel(); cont.resume(throwing: error) }
                }
            }
            let timerTask = Task {
                do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) } catch { return }
                if await gate.claim() {
                    workTask.cancel()
                    cont.resume(throwing: SpeechError.timeout(seconds: seconds))
                }
            }
            timer.arm(timerTask)
        }
    }
}

/// Exécuteur de tâches adossé à une file GCD concurrente dédiée, HORS du pool coopératif Swift.
/// `WhisperKit(config)` compile les graphes CoreML sur le thread appelant et `transcribe` bloque
/// son thread pendant l'inférence : un gel CoreML sur le pool coopératif confisquerait un de ses
/// threads pour de bon. Ici un gel ne coûte qu'un thread de cette file, remplacée au gel suivant.
@available(macOS 15.0, *)
final class InferenceExecutor: TaskExecutor, @unchecked Sendable {
    private let queue: DispatchQueue

    init(label: String) {
        // Concurrente : le découpage VAD de WhisperKit lance plusieurs fenêtres en parallèle.
        queue = DispatchQueue(label: label, qos: .userInitiated, attributes: .concurrent)
    }

    func enqueue(_ job: consuming ExecutorJob) {
        let unowned = UnownedJob(job)
        // `asUnownedTaskExecutor()` ne retient pas : on capture `self` pour que l'exécuteur
        // survive à ses travaux en file, même après avoir été abandonné.
        queue.async { [self] in unowned.runSynchronously(on: asUnownedTaskExecutor()) }
    }
}

// MARK: - Chargement audio

public enum AudioFileLoader {
    /// Lit un fichier audio et le rend en Float32 mono 16 kHz (conversion si nécessaire).
    public static func loadMono16k(url: URL) throws -> [Float] {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch {
            throw SpeechError.audioUnreadable("\(url.lastPathComponent) : \(error.localizedDescription)")
        }
        let srcFormat = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0 else { return [] }
        guard let srcBuffer = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: frames) else {
            throw SpeechError.audioUnreadable("tampon source impossible")
        }
        try file.read(into: srcBuffer)

        if srcFormat.sampleRate == 16_000, srcFormat.channelCount == 1, srcFormat.commonFormat == .pcmFormatFloat32,
           let data = srcBuffer.floatChannelData {
            return Array(UnsafeBufferPointer(start: data[0], count: Int(srcBuffer.frameLength)))
        }

        guard let dstFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: srcFormat, to: dstFormat) else {
            throw SpeechError.audioUnreadable("conversion 16 kHz mono impossible")
        }
        let ratio = 16_000 / srcFormat.sampleRate
        let dstFrames = AVAudioFrameCount(Double(frames) * ratio) + 1024
        guard let dstBuffer = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: dstFrames) else {
            throw SpeechError.audioUnreadable("tampon destination impossible")
        }
        var consumed = false
        var convError: NSError?
        converter.convert(to: dstBuffer, error: &convError) { _, status in
            if consumed { status.pointee = .endOfStream; return nil }
            consumed = true
            status.pointee = .haveData
            return srcBuffer
        }
        if let convError { throw SpeechError.audioUnreadable(convError.localizedDescription) }
        guard let data = dstBuffer.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(dstBuffer.frameLength)))
    }
}

// MARK: - Filtre anti-hallucination

/// Nettoyage des sorties Whisper : segments vides, boucles de répétition, phrases parasites
/// apprises sur les sous-titres YouTube (typiques en français sur du silence ou du bruit).
public enum HallucinationFilter {
    /// Marqueurs normalisés (minuscules, sans accents, sans ponctuation).
    static let parasites: [String] = [
        "sous titres realises par la communaute d amara org",
        "sous titres realises para la communaute d amara org",
        "sous titres realises par",
        "sous titrage societe radio canada",
        "sous titrage st 501",
        "sous titrage",
        "merci d avoir regarde cette video",
        "merci d avoir regarde",
        "merci de m avoir regarde",
        "merci a tous d avoir regarde",
        "abonnez vous",
        "n oubliez pas de vous abonner",
        "n hesitez pas a vous abonner",
        "like et abonne toi",
        "a bientot pour une nouvelle video",
        "traduction et sous titrage",
        "www ",
        "http",
    ].map(normalize)

    static func normalize(_ s: String) -> String {
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr"))
        let scalars = folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(scalars).split(separator: " ").joined(separator: " ")
    }

    /// Texte nettoyé, ou chaîne vide si le segment doit être écarté.
    public static func clean(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        // Segment sans la moindre lettre ou chiffre : ponctuation seule, musique, etc.
        guard text.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) else { return "" }

        let norm = normalize(text)
        if let hit = parasites.first(where: { norm.contains($0) }) {
            let words = norm.split(separator: " ").count
            if words <= 12 { return "" }
            // Phrase longue : on retire seulement le marqueur (rare, mais on ne jette pas une vraie phrase).
            text = stripMarker(hit, from: text)
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "" }
        }
        text = collapseRepetitions(text)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Vrai si le texte se termine par une boucle : un n-gramme (1 à 4 mots) répété plus de 3 fois.
    public static func hasLoop(_ text: String) -> Bool {
        let words = text.split(whereSeparator: { $0.isWhitespace }).map { normalize(String($0)) }.filter { !$0.isEmpty }
        for n in 1...4 {
            guard words.count >= n * 4 else { continue }
            let tail = Array(words.suffix(n * 4))
            let pattern = Array(tail.suffix(n))
            var repeats = 0
            for k in 0..<4 where Array(tail[(k * n)..<((k + 1) * n)]) == pattern { repeats += 1 }
            if repeats == 4 { return true }
        }
        return false
    }

    /// Réduit toute suite d'un même n-gramme (1 à 6 mots) répété plus de 3 fois à une seule occurrence.
    public static func collapseRepetitions(_ text: String) -> String {
        var words = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard words.count >= 4 else { return text }
        var changed = true
        while changed {
            changed = false
            for n in 1...6 where words.count >= n * 4 {
                var i = 0
                while i + n * 4 <= words.count {
                    let pattern = words[i..<(i + n)].map(normalize)
                    var count = 1
                    while i + (count + 1) * n <= words.count,
                          words[(i + count * n)..<(i + (count + 1) * n)].map(normalize) == pattern {
                        count += 1
                    }
                    if count > 3 {
                        words.removeSubrange((i + n)..<(i + count * n))
                        changed = true
                    }
                    i += 1
                }
            }
        }
        return words.joined(separator: " ")
    }

    private static func stripMarker(_ marker: String, from text: String) -> String {
        // Retire les mots du texte dont la forme normalisée reconstitue le marqueur.
        let markerWords = marker.split(separator: " ").map(String.init)
        var words = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let normWords = words.map(normalize)
        var i = 0
        while i + markerWords.count <= words.count {
            let window = normWords[i..<(i + markerWords.count)].joined(separator: " ")
            if window == marker {
                words.removeSubrange(i..<(i + markerWords.count))
                return words.joined(separator: " ")
            }
            i += 1
        }
        return text
    }
}

// MARK: - Dictionnaire en post-traitement

/// Applique les termes du dictionnaire au texte décodé : casse exacte sur correspondance normalisée
/// (« Greenlog » devient « GreenLog ») et rapprochement des formes proches (distance d'édition 1 jusqu'à
/// 6 lettres, 2 au-delà, sur 1 à 3 mots consécutifs, trait d'union compris). Jamais sur les termes de
/// moins de 4 lettres. Remplace l'injection de prompt, cassée dans WhisperKit 0.18.
public struct DictionaryCorrector {
    private struct Term { let display: String; let norm: String; let words: Int }
    private let terms: [Term]

    public init(terms: [String]) {
        self.terms = terms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { Term(display: $0, norm: HallucinationFilter.normalize($0).replacingOccurrences(of: " ", with: ""),
                        words: $0.split(separator: " ").count) }
            .filter { $0.norm.count >= 4 }
    }

    public func apply(_ text: String) -> String {
        guard !terms.isEmpty, !text.isEmpty else { return text }
        var words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        var i = 0
        while i < words.count {
            var replaced = false
            for span in stride(from: 3, through: 1, by: -1) where i + span <= words.count {
                let slice = words[i..<(i + span)]
                let joined = slice.joined(separator: " ")
                // Une fenêtre de plusieurs mots n'est comparée qu'aux termes composés, ou si les mots
                // sont liés par un trait d'union (« Gréant-Logue ») : sinon « me va » deviendrait « Meta ».
                let hyphenated = joined.contains("-")
                let (lead, core, trail) = Self.split(joined)
                guard !core.isEmpty else { continue }
                let norm = HallucinationFilter.normalize(core).replacingOccurrences(of: " ", with: "")
                guard norm.count >= 4 else { continue }
                if let t = terms.first(where: { (span == 1 || hyphenated || $0.words == span) && Self.matches($0.norm, norm) }) {
                    words.replaceSubrange(i..<(i + span), with: [lead + t.display + trail])
                    i += 1
                    replaced = true
                    break
                }
            }
            if !replaced { i += 1 }
        }
        return words.joined(separator: " ")
    }

    private static func matches(_ term: String, _ candidate: String) -> Bool {
        if term == candidate { return true }
        let tolerance = term.count <= 6 ? 1 : 2
        guard abs(term.count - candidate.count) <= tolerance else { return false }
        return levenshtein(Array(term), Array(candidate), max: tolerance) <= tolerance
    }

    /// Sépare la ponctuation de tête et de queue du mot (apostrophes élidées comprises : « d'Amara »).
    private static func split(_ s: String) -> (String, String, String) {
        var core = Substring(s)
        var lead = ""
        var trail = ""
        while let f = core.first, !(f.isLetter || f.isNumber) { lead.append(f); core = core.dropFirst() }
        while let l = core.last, !(l.isLetter || l.isNumber) { trail.insert(l, at: trail.startIndex); core = core.dropLast() }
        if let apos = core.firstIndex(where: { $0 == "'" || $0 == "\u{2019}" }), core.distance(from: core.startIndex, to: apos) <= 2 {
            lead += core[...apos]
            core = core[core.index(after: apos)...]
        }
        return (lead, String(core), trail)
    }

    private static func levenshtein(_ a: [Character], _ b: [Character], max limit: Int) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            var rowMin = cur[0]
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                cur[j] = Swift.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
                rowMin = Swift.min(rowMin, cur[j])
            }
            if rowMin > limit { return limit + 1 }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }
}
