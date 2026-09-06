import SwiftUI
import Combine
import UserNotifications
import NotekeeperCore
import NotekeeperAudio
import NotekeeperSpeech

/// État central de l'app. Tout passe par là : la liste des réunions, la capture en cours, le transcript
/// live, le post-traitement, l'assistant. Les moteurs sont injectés (réels ou factices).
@MainActor
final class AppModel: ObservableObject {

    struct Recording {
        let meetingID: UUID
        let startedAt: Date
        var elapsed: TimeInterval = 0
        var micLevel: Float = 0
        var systemLevel: Float = 0
        var partialMic: String? = nil
        var partialSystem: String? = nil
        var micWAV: URL
        var systemWAV: URL
    }

    struct Banner: Identifiable, Equatable {
        enum Kind { case info, warning, error }
        let id = UUID()
        let kind: Kind
        let text: String
        var action: String? = nil
        var onAction: (() -> Void)? = nil
        static func == (a: Banner, b: Banner) -> Bool { a.id == b.id }
    }

    let store: Store
    let capture: CaptureEngine
    let speech: SpeechEngine
    let calls: CallDetector
    let calendar = CalendarService()
    var assistant: AssistantService

    @Published private(set) var meetings: [Meeting] = []
    @Published var selectedMeetingID: UUID? {
        didSet { if oldValue != selectedMeetingID { loadSelected() } }
    }
    @Published var searchText: String = "" { didSet { runSearch() } }
    @Published private(set) var searchHits: [SearchHit] = []

    @Published private(set) var segments: [TranscriptSegment] = []
    @Published private(set) var speakers: [Speaker] = []
    @Published private(set) var chat: [ChatMessage] = []
    @Published private(set) var globalChat: [ChatMessage] = []

    @Published private(set) var recording: Recording?
    @Published private(set) var liveSegments: [TranscriptSegment] = []
    @Published private(set) var processing: [UUID: String] = [:]
    @Published private(set) var engineStatus: String = "Chargement du modèle…"
    @Published private(set) var engineReady = false
    @Published private(set) var detectedCallApp: String?
    @Published var banner: Banner?
    @Published private(set) var catchUpText: String?
    @Published private(set) var catchUpBusy = false
    @Published private(set) var askBusy = false
    @Published var showWelcome = false

    var selectedMeeting: Meeting? { selectedMeetingID.flatMap { id in meetings.first { $0.id == id } } }
    var isRecording: Bool { recording != nil }

    private var ticker: Timer?
    private var speakerCache: [UUID: Speaker] = [:]

    init(store: Store, capture: CaptureEngine, speech: SpeechEngine, calls: CallDetector, assistant: AssistantService) {
        self.store = store; self.capture = capture; self.speech = speech; self.calls = calls; self.assistant = assistant
        reloadMeetings()
        showWelcome = !AppSettings.onboardingDone
        calls.onChange = { [weak self] app in self?.callChanged(app) }
        calls.start()
        Task { await prepareEngine() }
        // Réunions restées « en cours » après un crash : on les ferme proprement.
        for m in meetings where m.status == .recording {
            var mm = m; mm.status = .failed; mm.endedAt = mm.endedAt ?? mm.updatedAt
            try? store.update(mm)
        }
        reloadMeetings()
    }

    // MARK: - Moteur

    func prepareEngine() async {
        do {
            try await speech.prepare { [weak self] msg in Task { @MainActor in self?.engineStatus = msg } }
            engineReady = true
            engineStatus = "Transcription prête"
        } catch {
            engineReady = false
            engineStatus = "Modèle indisponible : \(error.localizedDescription)"
            show(.error, "Le modèle de transcription n'a pas pu être chargé. \(error.localizedDescription)")
        }
    }

    // MARK: - Réunions

    func reloadMeetings() {
        meetings = (try? store.meetings()) ?? []
    }

    private func loadSelected() {
        guard let id = selectedMeetingID else { segments = []; speakers = []; chat = []; return }
        speakers = (try? store.speakers(meetingID: id)) ?? []
        speakerCache = Dictionary(uniqueKeysWithValues: speakers.map { ($0.id, $0) })
        if recording?.meetingID == id {
            segments = liveSegments
        } else {
            segments = TranscriptMerge.coalesce((try? store.segments(meetingID: id)) ?? [])
        }
        chat = (try? store.chat(meetingID: id)) ?? []
        catchUpText = nil
    }

    func speaker(for seg: TranscriptSegment) -> Speaker? {
        seg.speakerID.flatMap { speakerCache[$0] }
    }

    func speakerIndex(_ s: Speaker?) -> Int {
        guard let s, let i = speakers.firstIndex(of: s) else { return 0 }
        return i
    }

    func displayName(for seg: TranscriptSegment) -> String {
        if let s = speaker(for: seg) { return s.isMe ? AppSettings.userName : s.displayName }
        return seg.track == .mic ? AppSettings.userName : "Locuteur"
    }

    func updateTitle(_ title: String) {
        guard var m = selectedMeeting, m.title != title else { return }
        m.title = title.trimmingCharacters(in: .whitespaces)
        try? store.update(m); reloadMeetings(); exportIfWanted(m)
    }

    func updateNotes(_ notes: String) {
        guard var m = selectedMeeting, m.notes != notes else { return }
        m.notes = notes
        try? store.update(m)
        if let i = meetings.firstIndex(where: { $0.id == m.id }) { meetings[i] = m }
    }

    func delete(meeting: Meeting) {
        for p in [meeting.micAudioPath, meeting.systemAudioPath].compactMap({ $0 }) {
            try? FileManager.default.removeItem(atPath: p)
        }
        try? store.delete(meetingID: meeting.id)
        if selectedMeetingID == meeting.id { selectedMeetingID = nil }
        reloadMeetings()
    }

    func rename(speaker: Speaker, to name: String) {
        let clean = name.trimmingCharacters(in: .whitespaces)
        try? store.rename(speakerID: speaker.id, name: clean.isEmpty ? nil : clean)
        refreshSpeakers()
        if let m = selectedMeeting { exportIfWanted(m) }
    }

    func merge(speaker: Speaker, into target: Speaker) {
        guard speaker.id != target.id else { return }
        try? store.merge(speakerID: speaker.id, into: target.id)
        loadSelected()
    }

    private func refreshSpeakers() {
        guard let id = selectedMeetingID else { return }
        speakers = (try? store.speakers(meetingID: id)) ?? []
        speakerCache = Dictionary(uniqueKeysWithValues: speakers.map { ($0.id, $0) })
    }

    private func runSearch() {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        searchHits = q.count >= 2 ? ((try? store.search(q, limit: 60)) ?? []) : []
    }

    // MARK: - Capture

    func startMeeting(source: String? = nil) {
        guard recording == nil else { return }
        let event = calendar.currentEvent()
        let now = Date()
        let df = DateFormatter(); df.locale = Locale(identifier: "fr_FR"); df.dateFormat = "EEEE d MMMM, HH'h'mm"
        var m = Meeting(title: event?.title ?? "Réunion du \(df.string(from: now))",
                        startedAt: now, source: source ?? detectedCallApp ?? "Micro",
                        participants: event?.attendees ?? [], calendarEventID: event?.id,
                        status: .recording, language: AppSettings.language)
        let audioDir = Store.defaultDirectory().appendingPathComponent("audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        let micWAV = audioDir.appendingPathComponent("\(m.id.uuidString)-mic.wav")
        let sysWAV = audioDir.appendingPathComponent("\(m.id.uuidString)-system.wav")
        m.micAudioPath = micWAV.path; m.systemAudioPath = sysWAV.path
        do { try store.insert(m) } catch { show(.error, "Impossible de créer la réunion : \(error.localizedDescription)"); return }
        let me = Speaker(meetingID: m.id, label: "Moi", name: AppSettings.userName, isMe: true)
        try? store.upsert(me)

        var rec = Recording(meetingID: m.id, startedAt: now, micWAV: micWAV, systemWAV: sysWAV)
        rec.elapsed = 0
        recording = rec
        liveSegments = []
        reloadMeetings()
        selectedMeetingID = m.id
        catchUpText = nil

        let dictionary = ((try? store.dictionary()) ?? []).map(\.term)
        let meetingID = m.id
        speech.startLive(meetingID: meetingID, language: m.language, dictionary: dictionary) { [weak self] event in
            Task { @MainActor in self?.handle(event, meetingID: meetingID, meID: me.id) }
        }
        capture.onLevels = { [weak self] mic, sys in
            guard let self, self.recording != nil else { return }
            self.recording?.micLevel = mic; self.recording?.systemLevel = sys
        }
        Task {
            do {
                try await capture.start(micWAV: micWAV, systemWAV: sysWAV) { [weak self] track, samples, t in
                    self?.speech.feed(track: track, samples: samples, at: t)
                }
            } catch {
                show(.error, "Capture impossible : \(error.localizedDescription)")
                await stopMeeting()
            }
        }
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let r = self.recording else { return }
                self.recording?.elapsed = Date().timeIntervalSince(r.startedAt)
            }
        }
    }

    private func handle(_ event: TranscriptEvent, meetingID: UUID, meID: UUID) {
        guard recording?.meetingID == meetingID else { return }
        switch event {
        case .partial(let track, let text):
            if track == .mic { recording?.partialMic = text } else { recording?.partialSystem = text }
        case .final(var seg):
            if seg.track == .mic { recording?.partialMic = nil; seg.speakerID = meID } else { recording?.partialSystem = nil }
            seg.text = TranscriptMerge.cleanText(seg.text)
            guard !seg.text.isEmpty else { return }
            // Écho acoustique : sans casque, le micro entend les haut-parleurs. La piste système fait foi.
            if seg.track == .mic, TranscriptMerge.isEcho(seg, against: liveSegments) { return }
            if seg.track == .system {
                let echoes = liveSegments.filter { $0.track == .mic && TranscriptMerge.isEcho($0, against: [seg]) }
                for e in echoes { try? store.delete(segmentID: e.id) }
                liveSegments.removeAll { s in echoes.contains { $0.id == s.id } }
            }
            try? store.insert([seg])
            liveSegments.append(seg)
            liveSegments.sort { $0.start < $1.start }
            if selectedMeetingID == meetingID { segments = liveSegments }
        case .status(let s):
            engineStatus = s
        case .error(let e):
            show(.warning, e)
        }
    }

    func stopMeeting() async {
        guard var rec = recording else { return }
        ticker?.invalidate(); ticker = nil
        rec.elapsed = Date().timeIntervalSince(rec.startedAt)
        await capture.stop()
        await speech.stopLive()
        capture.onLevels = nil
        recording = nil
        engineStatus = "Transcription prête"
        guard var m = try? store.meeting(rec.meetingID) else { return }
        m.endedAt = Date(); m.status = .processing
        try? store.update(m)
        reloadMeetings()
        if selectedMeetingID == m.id { loadSelected() }
        Task { await postProcess(meetingID: m.id, micWAV: rec.micWAV, systemWAV: rec.systemWAV) }
    }

    // MARK: - Post-traitement

    /// Retranscription complète, diarisation, attribution des locuteurs, noms, résumé, titre, export.
    func postProcess(meetingID: UUID, micWAV: URL?, systemWAV: URL?) async {
        guard var m = try? store.meeting(meetingID) else { return }
        processing[meetingID] = "Retranscription…"
        let dictionary = ((try? store.dictionary()) ?? []).map(\.term)
        let existing = (try? store.speakers(meetingID: meetingID)) ?? []
        let me = existing.first(where: { $0.isMe }) ?? {
            let s = Speaker(meetingID: meetingID, label: "Moi", name: AppSettings.userName, isMe: true)
            try? store.upsert(s); return s
        }()
        do {
            let micURL = micWAV.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            let sysURL = systemWAV.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            let result = try await speech.finalPass(meetingID: meetingID, language: m.language, dictionary: dictionary,
                                                    micWAV: micURL, systemWAV: sysURL) { [weak self] msg in
                Task { @MainActor in self?.processing[meetingID] = msg }
            }
            var segs = result.segments.map { s -> TranscriptSegment in var c = s; c.text = TranscriptMerge.cleanText(s.text); return c }
                .filter { !$0.text.isEmpty }
            // Si la retranscription n'a rien rendu (WAV vide), on garde le live.
            if segs.isEmpty { segs = (try? store.segments(meetingID: meetingID)) ?? [] }
            segs = TranscriptMerge.removeEcho(segs)
            processing[meetingID] = "Attribution des locuteurs…"
            let assigned = TranscriptMerge.assignSpeakers(segments: segs, spans: result.spans, meetingID: meetingID,
                                                         meSpeakerID: me.id, existing: existing)
            for s in assigned.speakers { try store.upsert(s) }
            try store.replaceSegments(meetingID: meetingID, with: assigned.segments)
            if selectedMeetingID == meetingID { loadSelected() }

            processing[meetingID] = "Identification des noms…"
            do { _ = try await assistant.nameSpeakers(meeting: m) } catch { report(error, "noms") }
            if selectedMeetingID == meetingID { refreshSpeakers() }

            processing[meetingID] = "Résumé…"
            do {
                let summary = try await assistant.summarize(meeting: m)
                m = (try? store.meeting(meetingID)) ?? m
                m.summaryMarkdown = summary
            } catch { report(error, "résumé") }

            if m.calendarEventID == nil, m.title.hasPrefix("Réunion du") {
                if let t = try? await assistant.suggestTitle(meeting: m), !t.isEmpty { m.title = t }
            }
            m.status = .ready
        } catch {
            m.status = .failed
            show(.error, "Post-traitement en échec : \(error.localizedDescription). Le transcript live est conservé.")
        }
        if !AppSettings.keepAudio {
            for p in [m.micAudioPath, m.systemAudioPath].compactMap({ $0 }) { try? FileManager.default.removeItem(atPath: p) }
            m.micAudioPath = nil; m.systemAudioPath = nil
        }
        try? store.update(m)
        processing[meetingID] = nil
        reloadMeetings()
        if selectedMeetingID == meetingID { loadSelected() }
        exportIfWanted(m)
    }

    /// Relance noms + résumé sur une réunion existante (après correction manuelle des locuteurs, par exemple).
    func regenerate(meeting: Meeting) {
        Task {
            processing[meeting.id] = "Résumé…"
            do {
                _ = try await assistant.summarize(meeting: meeting)
            } catch { report(error, "résumé") }
            processing[meeting.id] = nil
            reloadMeetings()
            if selectedMeetingID == meeting.id { loadSelected() }
            if let m = try? store.meeting(meeting.id) { exportIfWanted(m) }
        }
    }

    // MARK: - Assistant

    func catchUp() {
        guard let rec = recording, !catchUpBusy else { return }
        catchUpBusy = true
        let window = TimeInterval(AppSettings.catchUpWindow)
        let recent = TranscriptMerge.recent(liveSegments, now: rec.elapsed, seconds: window)
        let sp = (try? store.speakers(meetingID: rec.meetingID)) ?? []
        Task {
            defer { catchUpBusy = false }
            guard !recent.isEmpty else { catchUpText = "Rien de dit dans les \(Int(window / 60)) dernières minutes."; return }
            do { catchUpText = try await assistant.catchUp(segments: recent, speakers: sp) }
            catch { catchUpText = nil; report(error, "rattrapage") }
        }
    }

    func ask(_ question: String, allMeetings: Bool) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !askBusy else { return }
        askBusy = true
        let scope: UUID? = allMeetings ? nil : selectedMeetingID
        Task {
            defer { askBusy = false }
            do {
                _ = try await assistant.ask(question: q, meetingID: scope)
            } catch { report(error, "question") }
            if allMeetings { globalChat = (try? store.chat(meetingID: nil)) ?? [] }
            else if let id = scope { chat = (try? store.chat(meetingID: id)) ?? [] }
        }
    }

    func loadGlobalChat() { globalChat = (try? store.chat(meetingID: nil)) ?? [] }
    func clearChat(allMeetings: Bool) {
        try? store.clearChat(meetingID: allMeetings ? nil : selectedMeetingID)
        if allMeetings { globalChat = [] } else { chat = [] }
    }

    // MARK: - Export

    func exportIfWanted(_ m: Meeting) {
        guard AppSettings.autoExport, m.status == .ready else { return }
        _ = export(m)
    }

    @discardableResult
    func export(_ m: Meeting) -> URL? {
        let dir = AppSettings.exportFolder
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let segs = (try? store.segments(meetingID: m.id, finalOnly: true)) ?? []
            let sp = (try? store.speakers(meetingID: m.id)) ?? []
            let md = MarkdownExport.render(meeting: m, segments: segs, speakers: sp)
            let url = dir.appendingPathComponent(MarkdownExport.fileName(for: m))
            try md.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            show(.warning, "Export markdown impossible : \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Détection d'appel

    private func callChanged(_ app: String?) {
        detectedCallApp = app
        guard let app, recording == nil, AppSettings.askBeforeRecordingCalls else { return }
        show(.info, "Tu es en appel sur \(app). Prendre des notes ?", action: "Enregistrer") { [weak self] in
            self?.startMeeting(source: app)
        }
        let content = UNMutableNotificationContent()
        content.title = "Appel détecté sur \(app)"
        content.body = "Ouvre Notekeeper pour prendre des notes."
        let req = UNNotificationRequest(identifier: "call-\(app)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    // MARK: - Bannières

    func show(_ kind: Banner.Kind, _ text: String, action: String? = nil, onAction: (() -> Void)? = nil) {
        banner = Banner(kind: kind, text: text, action: action, onAction: onAction)
    }

    private func report(_ error: Error, _ step: String) {
        show(.warning, "IA (\(step)) : \(error.localizedDescription)")
    }
}
