import Foundation

/// L'assistant IA : nommage des locuteurs, résumé, rattrapage, questions, titre.
/// Il lit et écrit dans le `Store`, appelle le `LLMClient`, et nettoie ce qui en sort.
public final class Assistant: Sendable {

    public let llm: LLMClient
    public let store: Store
    public let userName: String

    /// Au-delà, le transcript envoyé au LLM est tronqué (début et fin conservés).
    public static let maxTranscriptChars = 120_000
    /// Même chose pour le contexte d'une question posée sur une réunion précise.
    public static let maxAskContextChars = 80_000
    /// Contexte maximal pour le rattrapage et la suggestion de titre.
    public static let maxCatchUpChars = 20_000
    public static let maxTitleChars = 30_000
    /// Seuil de confiance pour accepter un nom proposé par le LLM.
    public static let nameConfidenceThreshold = 0.7
    /// Segments voisins ajoutés autour de chaque résultat de recherche.
    public static let neighborSegments = 2

    public init(llm: LLMClient, store: Store, userName: String) {
        self.llm = llm
        self.store = store
        self.userName = userName.trimmingCharacters(in: .whitespaces).isEmpty ? "Moi" : userName
    }

    // MARK: - Nommage des locuteurs

    /// Demande au LLM le nom des « Locuteur N » ; n'accepte qu'une confiance >= 0,7, ne touche jamais
    /// à « Moi » ni à un nom déjà posé. Enregistre puis renvoie les locuteurs de la réunion.
    public func nameSpeakers(meeting: Meeting) async throws -> [Speaker] {
        let speakers = try store.speakers(meetingID: meeting.id)
        let candidates = speakers.filter { !$0.isMe && $0.name == nil }
        guard !candidates.isEmpty else { return speakers }
        let segments = TranscriptMerge.coalesce(try store.segments(meetingID: meeting.id, finalOnly: true))
        guard !segments.isEmpty else { return speakers }

        // Étiquettes techniques pour tout le monde, noms déjà connus signalés à part.
        let labelled = speakers.map { Speaker(id: $0.id, meetingID: $0.meetingID, label: $0.label, name: nil, isMe: $0.isMe) }
        var transcript = TranscriptMerge.render(segments, speakers: labelled)
        transcript = Self.truncate(transcript, max: Self.maxTranscriptChars)
        let known = speakers.filter { !$0.isMe && $0.name != nil }.map { "\($0.label) = \($0.name!)" }
        if !known.isEmpty { transcript = "Déjà identifiés : \(known.joined(separator: ", "))\n\n" + transcript }

        let dictionary = (try? store.dictionary().map(\.term)) ?? []
        let prompt = Prompts.identifySpeakers(transcript: transcript, participants: meeting.participants,
                                              dictionary: dictionary, userName: userName)
        let raw = try await llm.complete(system: prompt.system, user: prompt.user, jsonMode: true)

        guard let root = LLMJSON.object(in: raw), let items = root["speakers"] as? [[String: Any]] else {
            return speakers
        }
        var updated = speakers
        for item in items {
            guard let label = (item["label"] as? String)?.trimmingCharacters(in: .whitespaces),
                  let name = Self.cleanName(item["name"]),
                  Self.number(item["confidence"]) ?? 0 >= Self.nameConfidenceThreshold,
                  let idx = updated.firstIndex(where: { $0.label.caseInsensitiveCompare(label) == .orderedSame }),
                  !updated[idx].isMe, updated[idx].name == nil
            else { continue }
            updated[idx].name = name
            try store.upsert(updated[idx])
        }
        return try store.speakers(meetingID: meeting.id)
    }

    // MARK: - Résumé

    /// Résumé structuré (cinq sections), nettoyé, enregistré dans `summaryMarkdown`.
    public func summarize(meeting: Meeting) async throws -> String {
        let transcript = try renderTranscript(meetingID: meeting.id, max: Self.maxTranscriptChars)
        let prompt = Prompts.summarize(transcript: transcript, title: meeting.title, date: meeting.startedAt)
        let raw = try await llm.complete(system: prompt.system, user: prompt.user, jsonMode: false)
        let markdown = Self.normalizeSummary(Self.clean(raw))
        guard !markdown.isEmpty else { throw LLMError.badResponse("résumé vide") }
        var m = try store.meeting(meeting.id) ?? meeting
        m.summaryMarkdown = markdown
        try store.update(m)
        return markdown
    }

    // MARK: - Qu'est-ce que j'ai raté ?

    public func catchUp(segments: [TranscriptSegment], speakers: [Speaker]) async throws -> String {
        let coalesced = TranscriptMerge.coalesce(segments.filter(\.isFinal))
        var transcript = TranscriptMerge.render(coalesced, speakers: speakers)
        transcript = Self.truncate(transcript, max: Self.maxCatchUpChars, headRatio: 0.2)
        let prompt = Prompts.catchUp(recentTranscript: transcript)
        let raw = try await llm.complete(system: prompt.system, user: prompt.user, jsonMode: false)
        let text = Self.clean(raw)
        return text.isEmpty ? "- Rien de notable." : text
    }

    // MARK: - Ask anything

    /// Avec `meetingID` : le transcript complet de la réunion sert de contexte. Sans : recherche plein texte
    /// étendue aux segments voisins, groupée par réunion. Question et réponse sont archivées dans le chat.
    public func ask(question: String, meetingID: UUID?) async throws -> AskAnswer {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let blocks: [String]
        if let meetingID {
            guard let meeting = try store.meeting(meetingID) else { throw LLMError.badResponse("réunion introuvable") }
            let transcript = try renderTranscript(meetingID: meetingID, max: Self.maxAskContextChars)
            blocks = [Self.contextHeader(meeting) + "\n" + transcript]
        } else {
            blocks = try searchContext(for: question)
        }

        try store.insert(ChatMessage(meetingID: meetingID, role: .user, markdown: question))
        let prompt = Prompts.ask(question: question, contextBlocks: blocks)
        let raw = try await llm.complete(system: prompt.system, user: prompt.user, jsonMode: false)
        let answer = try parseAnswer(raw, forcedMeetingID: meetingID)
        try store.insert(ChatMessage(meetingID: meetingID, role: .assistant, markdown: answer.markdown,
                                     citations: answer.citations))
        return answer
    }

    // MARK: - Titre

    public func suggestTitle(meeting: Meeting) async throws -> String {
        let transcript = try renderTranscript(meetingID: meeting.id, max: Self.maxTitleChars, headRatio: 0.8)
        guard !transcript.isEmpty else { throw LLMError.badResponse("transcription vide") }
        let prompt = Prompts.suggestTitle(transcript: transcript)
        let raw = try await llm.complete(system: prompt.system, user: prompt.user, jsonMode: false)
        let title = Self.cleanTitle(raw)
        guard !title.isEmpty else { throw LLMError.badResponse("titre vide") }
        return title
    }

    // MARK: - Contexte

    /// Transcript final, coalescé, horodaté, avec les noms connus ; tronqué si besoin.
    func renderTranscript(meetingID: UUID, max: Int, headRatio: Double = 0.6) throws -> String {
        let speakers = try store.speakers(meetingID: meetingID)
        let segments = TranscriptMerge.coalesce(try store.segments(meetingID: meetingID, finalOnly: true))
        return Self.truncate(TranscriptMerge.render(segments, speakers: speakers), max: max, headRatio: headRatio)
    }

    /// En-tête d'un bloc de contexte : `[Réunion « titre » du 05/09/2026] (meeting_id: ...)`.
    public static func contextHeader(_ m: Meeting) -> String {
        "[Réunion « \(m.title) » du \(Prompts.shortDate(m.startedAt))] (meeting_id: \(m.id.uuidString))"
    }

    /// Recherche FTS sur la question, étendue à ± `neighborSegments` voisins, groupée par réunion.
    func searchContext(for question: String) throws -> [String] {
        let hits = try searchHits(for: question)
        guard !hits.isEmpty else { return [] }
        var byMeeting: [UUID: Set<UUID>] = [:]
        for h in hits { byMeeting[h.meetingID, default: []].insert(h.segmentID) }

        var blocks: [(date: Date, text: String)] = []
        for (meetingID, segmentIDs) in byMeeting {
            guard let meeting = try store.meeting(meetingID) else { continue }
            let speakers = try store.speakers(meetingID: meetingID)
            let all = try store.segments(meetingID: meetingID, finalOnly: true).sorted { $0.start < $1.start }
            var keep = Set<Int>()
            for (i, s) in all.enumerated() where segmentIDs.contains(s.id) {
                for j in max(0, i - Self.neighborSegments)...min(all.count - 1, i + Self.neighborSegments) { keep.insert(j) }
            }
            var lines: [String] = []
            var previous = -1
            for i in keep.sorted() {
                if previous >= 0, i > previous + 1 { lines.append("[...]") }
                lines.append(TranscriptMerge.render([all[i]], speakers: speakers))
                previous = i
            }
            blocks.append((meeting.startedAt, Self.contextHeader(meeting) + "\n" + lines.joined(separator: "\n")))
        }
        return blocks.sorted { $0.date > $1.date }.map(\.text)
    }

    /// FTS5 combine les termes en ET : on cherche d'abord les mots significatifs ensemble,
    /// puis chacun séparément si rien ne sort, puis la question brute en dernier recours.
    func searchHits(for question: String, limit: Int = 40) throws -> [SearchHit] {
        let keywords = Self.keywords(in: question)
        if !keywords.isEmpty {
            let together = try store.search(keywords.joined(separator: " "), limit: limit)
            if !together.isEmpty { return together }
            var seen = Set<UUID>()
            var union: [SearchHit] = []
            for k in keywords {
                for h in try store.search(k, limit: limit) where !seen.contains(h.segmentID) {
                    seen.insert(h.segmentID); union.append(h)
                }
            }
            if !union.isEmpty { return Array(union.prefix(limit)) }
        }
        return try store.search(question, limit: limit)
    }

    static let stopWords: Set<String> = [
        "les", "des", "une", "est", "sont", "qui", "que", "quoi", "quel", "quelle", "quels", "quelles", "dans", "sur", "pour",
        "avec", "sans", "par", "pas", "plus", "mais", "donc", "car", "nous", "vous", "ils", "elles", "elle", "lui", "leur",
        "leurs", "notre", "nos", "votre", "vos", "mon", "mes", "ton", "tes", "son", "ses", "cette", "ces", "cet", "aux",
        "était", "ete", "été", "etre", "être", "avoir", "fait", "faire", "dit", "comment", "pourquoi", "quand", "combien",
        "est-ce", "ce", "de", "du", "la", "le", "un", "et", "ou", "où", "on", "en", "au", "se", "sa", "ne", "je", "tu",
        "il", "ma", "ta", "si", "y", "a", "à", "été", "ont", "avons", "avez", "as", "ai", "peut", "peux", "doit", "dois",
        "réunion", "reunion", "réunions", "reunions", "dernière", "derniere", "dernier", "parlé", "parle",
    ]

    static func keywords(in question: String) -> [String] {
        var out: [String] = []
        for raw in question.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "-" }) {
            let w = raw.trimmingCharacters(in: CharacterSet(charactersIn: "-")).lowercased()
            guard w.count >= 3, !stopWords.contains(w), !out.contains(w) else { continue }
            out.append(w)
        }
        return out
    }

    // MARK: - Réponses

    /// Sépare le markdown du bloc final de citations. Bloc absent ou cassé : réponse sans citations.
    func parseAnswer(_ raw: String, forcedMeetingID: UUID?) throws -> AskAnswer {
        var body = raw
        var citations: [Citation] = []
        if let (jsonText, range) = LLMJSON.lastFencedBlock(in: raw, containing: "citations") {
            body = String(raw[..<range.lowerBound])
            if let obj = LLMJSON.object(in: jsonText), let items = obj["citations"] as? [[String: Any]] {
                citations = items.compactMap { citation(from: $0, forcedMeetingID: forcedMeetingID) }
            }
        } else if let obj = LLMJSON.trailingObject(in: raw, containing: "citations") {
            body = String(raw[..<obj.range.lowerBound])
            if let items = obj.object["citations"] as? [[String: Any]] {
                citations = items.compactMap { citation(from: $0, forcedMeetingID: forcedMeetingID) }
            }
        }
        var markdown = Self.clean(body)
        if markdown.isEmpty { markdown = "Je ne trouve pas ça dans tes réunions." }
        return AskAnswer(markdown: markdown, citations: citations)
    }

    private func citation(from item: [String: Any], forcedMeetingID: UUID?) -> Citation? {
        let idText = (item["meeting_id"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        let meetingID = forcedMeetingID ?? UUID(uuidString: idText)
        guard let meetingID, let meeting = try? store.meeting(meetingID) else { return nil }
        let start = Self.seconds(item["start_seconds"]) ?? Self.seconds(item["start"]) ?? 0
        let quote = Self.clean((item["quote"] as? String) ?? "")
        return Citation(meetingID: meetingID, meetingTitle: meeting.title, start: start, quote: quote)
    }

    // MARK: - Nettoyage

    /// Tiret cadratin remplacé (virgule s'il est entouré d'espaces, tiret simple sinon), emojis retirés.
    public static func clean(_ text: String) -> String {
        var s = text
        for dash in ["\u{2014}", "\u{2013}", "\u{2015}"] {
            s = s.replacingOccurrences(of: " \(dash) ", with: ", ")
            s = s.replacingOccurrences(of: dash, with: "-")
        }
        s = String(String.UnicodeScalarView(s.unicodeScalars.filter { !isEmojiScalar($0) }))
        // Espaces laissés par un emoji retiré ; on ne touche pas aux espaces avant « : ; ! ? » (typographie française).
        s = s.replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: " +([.,])", with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: "[ \\t]+\\n", with: "\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isEmojiScalar(_ u: Unicode.Scalar) -> Bool {
        if u.value == 0x200D || u.value == 0xFE0F || (0x1F3FB...0x1F3FF).contains(u.value) { return true }
        if u.properties.isEmojiPresentation { return true }
        return u.properties.isEmoji && u.value > 0x238C
    }

    /// Garantit la présence des cinq sections (celles qui manquent sont ajoutées, vides, à la fin).
    static func normalizeSummary(_ markdown: String) -> String {
        var out = markdown
        for section in Prompts.summarySections where !out.contains(section) {
            out += "\n\n\(section)\n- aucune"
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func cleanTitle(_ raw: String) -> String {
        var t = clean(raw).split(whereSeparator: \.isNewline).map(String.init).first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
        t = t.replacingOccurrences(of: "^(titre\\s*:\\s*)", with: "", options: [.regularExpression, .caseInsensitive])
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: "«»\"'“”‘’`*#_ .:!?"))
        if t.count > 80 { t = String(t.prefix(80)).trimmingCharacters(in: .whitespaces) }
        return t
    }

    static func cleanName(_ value: Any?) -> String? {
        guard let s = value as? String else { return nil }
        let name = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.lowercased() != "null", name.count <= 60 else { return nil }
        return name
    }

    static func number(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let s = value as? String { return Double(s.replacingOccurrences(of: ",", with: ".")) }
        return nil
    }

    /// Accepte un nombre, une chaîne numérique ou une horloge « 12:07 » / « 1:02:07 ».
    static func seconds(_ value: Any?) -> TimeInterval? {
        if let n = number(value) { return n }
        guard let s = (value as? String)?.trimmingCharacters(in: CharacterSet(charactersIn: "[] ")) else { return nil }
        let parts = s.split(separator: ":").compactMap { Double($0) }
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }

    /// Tronque en gardant le début et la fin, coupe sur des fins de ligne, et le dit dans le texte.
    public static func truncate(_ text: String, max: Int, headRatio: Double = 0.6) -> String {
        guard text.count > max, max > 200 else { return text }
        let headBudget = Int(Double(max) * headRatio)
        let tailBudget = max - headBudget
        var head = String(text.prefix(headBudget))
        if let cut = head.lastIndex(of: "\n") { head = String(head[..<cut]) }
        var tail = String(text.suffix(tailBudget))
        if let cut = tail.firstIndex(of: "\n") { tail = String(tail[tail.index(after: cut)...]) }
        let omitted = text.count - head.count - tail.count
        return head + "\n\n[... passage omis pour longueur : environ \(omitted) caractères au milieu de la réunion ...]\n\n" + tail
    }
}

/// Extraction tolérante de JSON dans une réponse de LLM (barrières de code, texte autour, accolades déséquilibrées).
enum LLMJSON {

    /// Le premier objet JSON trouvé dans le texte, ou nil.
    static func object(in text: String) -> [String: Any]? {
        let stripped = stripFences(text)
        if let obj = parse(stripped) { return obj }
        guard let open = stripped.firstIndex(of: "{") else { return nil }
        // Accolades et crochets équilibrés depuis la première ouvrante, en ignorant ceux des chaînes.
        var stack: [Character] = []
        var inString = false, escaped = false
        var i = open
        while i < stripped.endIndex {
            let c = stripped[i]
            if inString {
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
            } else if c == "\"" { inString = true }
            else if c == "{" || c == "[" { stack.append(c) }
            else if c == "}" || c == "]" {
                _ = stack.popLast()
                if stack.isEmpty { return parse(String(stripped[open...i])) }
            }
            i = stripped.index(after: i)
        }
        // Réponse coupée : on referme nous-mêmes ce qui est resté ouvert (chaîne, puis crochets et accolades).
        var repaired = String(stripped[open...])
        if inString { repaired += "\"" }
        repaired = repaired.replacingOccurrences(of: ",\\s*$", with: "", options: .regularExpression)
        for c in stack.reversed() { repaired += c == "{" ? "}" : "]" }
        return parse(repaired)
    }

    /// Dernier bloc ```json ... ``` (ou ``` ... ```) contenant `needle`, avec l'emplacement du bloc entier.
    static func lastFencedBlock(in text: String, containing needle: String) -> (String, Range<String.Index>)? {
        let pattern = "```(?:json|JSON)?[ \\t]*\\n?([\\s\\S]*?)```"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        for m in matches.reversed() {
            let inner = ns.substring(with: m.range(at: 1))
            guard inner.contains(needle), let range = Range(m.range, in: text) else { continue }
            return (inner, range)
        }
        // Barrière ouverte jamais fermée en fin de texte.
        if let open = text.range(of: "```json", options: .backwards) ?? text.range(of: "```", options: .backwards) {
            let inner = String(text[open.upperBound...])
            if inner.contains(needle) { return (inner, open.lowerBound..<text.endIndex) }
        }
        return nil
    }

    /// Objet JSON nu en fin de texte (sans barrière), s'il contient `needle`.
    static func trailingObject(in text: String, containing needle: String) -> (object: [String: Any], range: Range<String.Index>)? {
        guard let start = text.range(of: "{\"\(needle)\"") ?? text.range(of: "{ \"\(needle)\"") else { return nil }
        let tail = String(text[start.lowerBound...])
        guard let obj = object(in: tail) else { return nil }
        return (obj, start.lowerBound..<text.endIndex)
    }

    static func stripFences(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            if let nl = s.firstIndex(of: "\n") { s = String(s[s.index(after: nl)...]) } else { s = "" }
            if let close = s.range(of: "```", options: .backwards) { s = String(s[..<close.lowerBound]) }
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parse(_ s: String) -> [String: Any]? {
        guard let data = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any]
        else { return nil }
        return obj
    }
}
