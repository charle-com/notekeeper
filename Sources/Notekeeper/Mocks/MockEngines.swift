import Foundation
import NotekeeperCore
import NotekeeperAudio
import NotekeeperSpeech

/// Moteurs factices pour la démo (`NOTEKEEPER_MOCK=1`) et la QA sans micro ni modèle.
final class MockCaptureEngine: CaptureEngine {
    var onLevels: ((Float, Float) -> Void)?
    var micDeviceName: String { "Micro de démonstration" }
    private var timer: Timer?
    private var t: TimeInterval = 0

    func start(micWAV: URL, systemWAV: URL, onSamples: @escaping (Track, [Float], TimeInterval) -> Void) async throws {
        t = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            let mic = Float.random(in: 0.05...0.5), sys = Float.random(in: 0.1...0.8)
            self.onLevels?(mic, sys)
            let block = [Float](repeating: 0, count: 1600)
            onSamples(.mic, block, self.t); onSamples(.system, block, self.t)
            self.t += 0.1
        }
    }
    func stop() async { timer?.invalidate(); timer = nil }
}

final class MockCallDetector: CallDetector {
    var onChange: ((String?) -> Void)?
    var currentApp: String?
    func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            self?.currentApp = "Google Meet (Chrome)"; self?.onChange?("Google Meet (Chrome)")
        }
    }
    func stop() {}
}

/// Rejoue un dialogue français scripté à cadence réelle.
final class MockSpeechEngine: SpeechEngine {
    var isReady = true
    private var timer: Timer?
    private var onEvent: ((TranscriptEvent) -> Void)?
    private var i = 0
    private var meetingID = UUID()

    static let script: [(Track, TimeInterval, String)] = [
        (.mic, 3, "Bon, on fait le point sur le transfert GreenLog. Le camion cinq est arrivé mardi ?"),
        (.system, 4, "Oui, livré mardi matin, trente-deux palettes. Il reste le contrôle de réception, Hélène s'en occupe jeudi."),
        (.system, 5, "Par contre le camion quatre a été annulé, donc il manque les Berlin bleu grisé."),
        (.mic, 3, "Ok. On recale ça sur le prochain départ. Alexander, tu envoies l'attendu ShippingBo aujourd'hui ?"),
        (.system, 4, "Je le fais cet après-midi. Et pour le prix de la collection 26-27, on part bien de la marge ?"),
        (.mic, 4, "Oui, la marge d'abord, lot de trois, lot de deux, unité. Je vous envoie le classeur ce soir."),
        (.system, 3, "Parfait. Dernier point : la vente Bradery se termine le six, on fait un bilan lundi."),
        (.mic, 2, "Ça marche. Merci Hélène, merci Alexander."),
    ]

    func prepare(progress: @escaping (String) -> Void) async throws {
        progress("Modèle de démonstration prêt")
    }

    func startLive(meetingID: UUID, language: String, dictionary: [String], onEvent: @escaping (TranscriptEvent) -> Void) {
        self.meetingID = meetingID; self.onEvent = onEvent; i = 0
        scheduleNext(at: 1.5)
    }

    private var clock: TimeInterval = 0
    private func scheduleNext(at delay: TimeInterval) {
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self, self.i < Self.script.count else { return }
            let (track, dur, text) = Self.script[self.i]
            self.onEvent?(.partial(track: track, text: "…"))
            let start = self.clock
            self.clock += dur
            let seg = TranscriptSegment(meetingID: self.meetingID, track: track, start: start, end: self.clock, text: text)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.onEvent?(.final(seg)) }
            self.i += 1
            self.scheduleNext(at: dur)
        }
    }

    func feed(track: Track, samples: [Float], at time: TimeInterval) {}
    func stopLive() async { timer?.invalidate(); timer = nil }

    func finalPass(meetingID: UUID, language: String, dictionary: [String], micWAV: URL?, systemWAV: URL?,
                   progress: @escaping (String) -> Void) async throws -> (segments: [TranscriptSegment], spans: [DiarizedSpan]) {
        progress("Retranscription de démonstration")
        try? await Task.sleep(nanoseconds: 800_000_000)
        var t: TimeInterval = 0
        var segs: [TranscriptSegment] = []
        var spans: [DiarizedSpan] = []
        for (idx, (track, dur, text)) in Self.script.enumerated() {
            segs.append(TranscriptSegment(meetingID: meetingID, track: track, start: t, end: t + dur, text: text))
            if track == .system { spans.append(DiarizedSpan(clusterKey: idx % 3 == 1 ? "A" : "B", start: t, end: t + dur)) }
            t += dur
        }
        return (segs, spans)
    }
}

final class MockAssistant: AssistantService {
    let store: Store
    init(store: Store) { self.store = store }

    func nameSpeakers(meeting: Meeting) async throws -> [Speaker] {
        var sp = try store.speakers(meetingID: meeting.id)
        let names = ["Hélène", "Alexander"]
        var k = 0
        for i in sp.indices where !sp[i].isMe && sp[i].name == nil && k < names.count {
            sp[i].name = names[k]; k += 1; try store.upsert(sp[i])
        }
        return sp
    }
    func summarize(meeting: Meeting) async throws -> String {
        try? await Task.sleep(nanoseconds: 600_000_000)
        return """
        ## En bref
        Point logistique GreenLog et prix de la collection 26-27. Le camion 5 est livré, le camion 4 annulé. Bilan Bradery lundi.

        ## Décisions
        - Les prix 26-27 partent de la marge, par format (lot de 3, lot de 2, unité).
        - Les Berlin bleu grisé du camion 4 sont recalés sur le prochain départ.

        ## Par thème
        ### Transfert GreenLog
        - Camion 5 livré mardi, 32 palettes (Hélène).
        - Contrôle de réception jeudi, par Hélène.
        ### Prix collection 26-27
        - Classeur envoyé ce soir par Moi.

        ## Prochaines étapes
        - Alexander : envoyer l'attendu ShippingBo, aujourd'hui.
        - Hélène : contrôle de réception, jeudi.
        - Moi : classeur prix et marges, ce soir.

        ## Questions ouvertes
        - Date du prochain départ pour les Berlin bleu grisé.
        """
    }
    func catchUp(segments: [TranscriptSegment], speakers: [Speaker]) async throws -> String {
        try? await Task.sleep(nanoseconds: 500_000_000)
        return "- Le camion 4 est annulé, il manque les Berlin bleu grisé.\n- Alexander envoie l'attendu ShippingBo cet après-midi.\n- On t'attend sur le classeur prix 26-27 ce soir."
    }
    func ask(question: String, meetingID: UUID?) async throws -> AskAnswer {
        try? await Task.sleep(nanoseconds: 700_000_000)
        let hits = try store.search(question, limit: 3)
        let cites = hits.map { Citation(meetingID: $0.meetingID, meetingTitle: $0.meetingTitle, start: $0.start, quote: $0.snippet) }
        let md = hits.isEmpty ? "Je ne trouve pas ça dans tes réunions." : "D'après tes réunions : " + hits.map(\.snippet).joined(separator: " ")
        let a = AskAnswer(markdown: md, citations: cites)
        try store.insert(ChatMessage(meetingID: meetingID, role: .user, markdown: question))
        try store.insert(ChatMessage(meetingID: meetingID, role: .assistant, markdown: a.markdown, citations: a.citations))
        return a
    }
    func suggestTitle(meeting: Meeting) async throws -> String { "Point GreenLog et prix 26-27" }
}
