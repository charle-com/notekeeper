import XCTest
@testable import NotekeeperCore

final class AssistantTests: XCTestCase {

    /// Réunion de test : Moi (Charles), Locuteur 2 (sans nom), Locuteur 3 (déjà nommé Marc).
    private func makeMeeting(store: Store) throws -> (Meeting, Speaker, Speaker, Speaker) {
        let m = Meeting(title: "Point Kheops", startedAt: Date(timeIntervalSince1970: 1_788_000_000),
                        source: "Zoom", participants: ["Priya Sharma", "Paul Lemaire"], status: .ready)
        try store.insert(m)
        let me = Speaker(meetingID: m.id, label: "Moi", name: "Charles", isMe: true)
        let l2 = Speaker(meetingID: m.id, label: "Locuteur 2")
        let l3 = Speaker(meetingID: m.id, label: "Locuteur 3", name: "Marc")
        try store.upsert(me); try store.upsert(l2); try store.upsert(l3)
        try store.insert([
            TranscriptSegment(meetingID: m.id, track: .mic, start: 0, end: 3, text: "On valide le budget SEO ? Merci Priya.", speakerID: me.id),
            TranscriptSegment(meetingID: m.id, track: .system, start: 3.2, end: 6, text: "Oui, trente pour cent vers l'emailing.", speakerID: l2.id),
            TranscriptSegment(meetingID: m.id, track: .system, start: 7, end: 9, text: "Et le reste en netlinking.", speakerID: l3.id),
            TranscriptSegment(meetingID: m.id, track: .mic, start: 10, end: 12, text: "Parfait, on part là-dessus.", speakerID: me.id),
        ])
        return (m, me, l2, l3)
    }

    func testNameSpeakersAppliesThresholdAndPreservesExistingNames() async throws {
        let store = try Store.inMemory()
        let (m, me, l2, l3) = try makeMeeting(store: store)
        let mock = MockLLM(responses: [
            """
            ```json
            {"speakers":[
              {"label":"Moi","name":"Quelqu'un","confidence":0.99,"evidence":"x"},
              {"label":"Locuteur 2","name":"Priya Sharma","confidence":0.92,"evidence":"[0:00] Moi : Merci Priya."},
              {"label":"Locuteur 3","name":"Paul Lemaire","confidence":0.95,"evidence":"x"},
              {"label":"Locuteur 4","name":"Fantôme","confidence":0.99,"evidence":"x"}
            ]}
            ```
            """,
        ])
        let assistant = Assistant(llm: mock, store: store, userName: "Charles")
        let speakers = try await assistant.nameSpeakers(meeting: m)

        XCTAssertEqual(speakers.first(where: { $0.id == me.id })?.name, "Charles", "« Moi » n'est jamais renommé")
        XCTAssertEqual(speakers.first(where: { $0.id == l2.id })?.name, "Priya Sharma")
        XCTAssertEqual(speakers.first(where: { $0.id == l3.id })?.name, "Marc", "un nom déjà posé n'est pas écrasé")
        XCTAssertEqual(speakers.count, 3)

        // Le prompt reçoit les étiquettes techniques, les invités et l'utilisateur.
        let call = try XCTUnwrap(mock.lastCall)
        XCTAssertTrue(call.jsonMode)
        XCTAssertTrue(call.user.contains("Locuteur 2 : Oui, trente pour cent"))
        XCTAssertTrue(call.user.contains("Priya Sharma, Paul Lemaire"))
        XCTAssertTrue(call.user.contains("Déjà identifiés : Locuteur 3 = Marc"))
        XCTAssertTrue(call.system.contains("Charles"))
    }

    func testNameSpeakersIgnoresLowConfidenceAndBrokenJSON() async throws {
        let store = try Store.inMemory()
        let (m, _, l2, _) = try makeMeeting(store: store)
        let mock = MockLLM(responses: [
            #"{"speakers":[{"label":"Locuteur 2","name":"Priya","confidence":0.4,"evidence":""}]}"#,
            "pas du json du tout",
        ])
        let assistant = Assistant(llm: mock, store: store, userName: "Charles")
        var speakers = try await assistant.nameSpeakers(meeting: m)
        XCTAssertNil(speakers.first(where: { $0.id == l2.id })?.name, "confiance 0,4 : ignorée")
        speakers = try await assistant.nameSpeakers(meeting: m)
        XCTAssertNil(speakers.first(where: { $0.id == l2.id })?.name, "JSON cassé : pas d'erreur, pas de nom")
        XCTAssertEqual(mock.calls.count, 2)
    }

    func testSummarizeCleansAndStoresMarkdown() async throws {
        let store = try Store.inMemory()
        let (m, _, _, _) = try makeMeeting(store: store)
        let mock = MockLLM(responses: [
            """
            ## En bref
            Budget SEO validé \u{2014} 30 % vers l'emailing \u{1F680}.

            ## Décisions
            - 30 % du budget vers l'emailing\u{2014}le reste en netlinking

            ## Par thème
            ### Budget
            - Marc : le reste en netlinking

            ## Prochaines étapes
            - Charles : lancer, échéance non précisée
            """,
        ])
        let assistant = Assistant(llm: mock, store: store, userName: "Charles")
        let md = try await assistant.summarize(meeting: m)

        XCTAssertFalse(md.contains("\u{2014}"))
        XCTAssertFalse(md.contains("\u{1F680}"))
        XCTAssertTrue(md.contains("Budget SEO validé, 30 % vers l'emailing."))
        XCTAssertTrue(md.contains("l'emailing-le reste"))
        XCTAssertTrue(md.hasPrefix("## En bref"))
        XCTAssertTrue(md.contains("## Questions ouvertes\n- aucune"), "section manquante ajoutée")
        XCTAssertEqual(try store.meeting(m.id)?.summaryMarkdown, md)

        let call = try XCTUnwrap(mock.lastCall)
        XCTAssertFalse(call.jsonMode)
        XCTAssertTrue(call.user.contains("« Point Kheops »"))
        XCTAssertTrue(call.user.contains("[0:03] Locuteur 2 : Oui, trente pour cent vers l'emailing."))
        XCTAssertTrue(call.user.contains("[0:07] Marc : Et le reste en netlinking."))
    }

    func testAskOnMeetingParsesCitations() async throws {
        let store = try Store.inMemory()
        let (m, _, _, _) = try makeMeeting(store: store)
        let mock = MockLLM()
        mock.setHandler { _, user, _ in
            XCTAssertTrue(user.contains("(meeting_id: \(m.id.uuidString))"))
            XCTAssertTrue(user.contains("Question : Quelle part pour l'emailing ?"))
            return """
            30 % du budget vont vers l'emailing, dit Locuteur 2.

            ```json
            {"citations":[{"meeting_id":"\(m.id.uuidString)","start_seconds":"0:03","quote":"trente pour cent vers l'emailing"},
                          {"meeting_id":"00000000-0000-0000-0000-000000000000","start_seconds":99,"quote":"ignorée"}]}
            ```
            """
        }
        let assistant = Assistant(llm: mock, store: store, userName: "Charles")
        let answer = try await assistant.ask(question: "Quelle part pour l'emailing ?", meetingID: m.id)

        XCTAssertEqual(answer.markdown, "30 % du budget vont vers l'emailing, dit Locuteur 2.")
        XCTAssertEqual(answer.citations.count, 2, "avec meetingID, toute citation est rattachée à la réunion")
        XCTAssertEqual(answer.citations.first?.meetingTitle, "Point Kheops")
        XCTAssertEqual(answer.citations.first?.start, 3)
        XCTAssertEqual(answer.citations.first?.quote, "trente pour cent vers l'emailing")

        let chat = try store.chat(meetingID: m.id)
        XCTAssertEqual(chat.map(\.role), [.user, .assistant])
        XCTAssertEqual(chat.last?.citations.count, 2)
    }

    func testAskAcrossMeetingsWithoutCitationsBlock() async throws {
        let store = try Store.inMemory()
        let (m, _, _, _) = try makeMeeting(store: store)
        let mock = MockLLM(responses: ["Trente pour cent du budget vont vers l'emailing."])
        let assistant = Assistant(llm: mock, store: store, userName: "Charles")
        let answer = try await assistant.ask(question: "Qu'est-ce qu'on a décidé pour l'emailing ?", meetingID: nil)

        XCTAssertEqual(answer.markdown, "Trente pour cent du budget vont vers l'emailing.")
        XCTAssertTrue(answer.citations.isEmpty)
        let call = try XCTUnwrap(mock.lastCall)
        XCTAssertTrue(call.user.contains("[Réunion « Point Kheops » du"), "contexte issu de la recherche")
        XCTAssertTrue(call.user.contains("(meeting_id: \(m.id.uuidString))"))
        XCTAssertTrue(call.user.contains("trente pour cent vers l'emailing"))
        XCTAssertTrue(call.user.contains("[0:00] Charles : On valide"), "segment voisin inclus")
        XCTAssertEqual(try store.chat(meetingID: nil).count, 2)

        // Citation en JSON nu (sans barrière) et bloc cassé : tolérés.
        mock.enqueue("Réponse.\n{\"citations\":[{\"meeting_id\":\"\(m.id.uuidString)\",\"start_seconds\":7,\"quote\":\"netlinking\"}]}")
        var a = try await assistant.ask(question: "netlinking", meetingID: nil)
        XCTAssertEqual(a.markdown, "Réponse.")
        XCTAssertEqual(a.citations.first?.start, 7)
        mock.enqueue("Réponse.\n```json\n{\"citations\":[{\"meeting_id\":")
        a = try await assistant.ask(question: "netlinking", meetingID: nil)
        XCTAssertEqual(a.markdown, "Réponse.")
        XCTAssertTrue(a.citations.isEmpty)
    }

    func testAskWithoutHitsSendsEmptyContext() async throws {
        let store = try Store.inMemory()
        _ = try makeMeeting(store: store)
        let mock = MockLLM(responses: ["Je ne trouve pas ça dans tes réunions.\n```json\n{\"citations\":[]}\n```"])
        let assistant = Assistant(llm: mock, store: store, userName: "Charles")
        let answer = try await assistant.ask(question: "Quel est le prix du camion ?", meetingID: nil)
        XCTAssertEqual(answer.markdown, "Je ne trouve pas ça dans tes réunions.")
        XCTAssertTrue(answer.citations.isEmpty)
        XCTAssertTrue(try XCTUnwrap(mock.lastCall).user.contains("(aucun extrait ne correspond"))
    }

    func testSuggestTitleAndCatchUp() async throws {
        let store = try Store.inMemory()
        let (m, me, l2, _) = try makeMeeting(store: store)
        let mock = MockLLM(responses: ["« Budget SEO trimestre ».\n", "- Priya a validé 30 % vers l'emailing \u{2705}"])
        let assistant = Assistant(llm: mock, store: store, userName: "Charles")
        let title = try await assistant.suggestTitle(meeting: m)
        XCTAssertEqual(title, "Budget SEO trimestre")

        let segments = try store.segments(meetingID: m.id)
        let speakers = [me, l2]
        let text = try await assistant.catchUp(segments: segments, speakers: speakers)
        XCTAssertEqual(text, "- Priya a validé 30 % vers l'emailing")
        XCTAssertTrue(try XCTUnwrap(mock.lastCall).user.contains("Charles : On valide le budget SEO ?"))
    }

    func testTruncateKeepsHeadAndTail() {
        let lines = (1...2000).map { "ligne \($0) : du texte pour remplir" }
        let text = lines.joined(separator: "\n")
        let out = Assistant.truncate(text, max: 5_000)
        XCTAssertLessThan(out.count, 5_300)
        XCTAssertTrue(out.hasPrefix("ligne 1 :"))
        XCTAssertTrue(out.hasSuffix("ligne 2000 : du texte pour remplir"))
        XCTAssertTrue(out.contains("[... passage omis pour longueur"))
        XCTAssertEqual(Assistant.truncate("court", max: 5_000), "court")
    }

    func testJSONExtractionTolerance() {
        XCTAssertEqual(LLMJSON.object(in: "```json\n{\"a\":1}\n```")?["a"] as? Int, 1)
        XCTAssertEqual(LLMJSON.object(in: "Voici : {\"a\":{\"b\":\"}\"}} fin")?.keys.count, 1)
        XCTAssertEqual((LLMJSON.object(in: "{\"speakers\":[{\"label\":\"x\"")?["speakers"] as? [[String: Any]])?.count, 1)
        XCTAssertNil(LLMJSON.object(in: "rien"))
        XCTAssertEqual(Assistant.seconds("1:02:07"), 3727)
        XCTAssertEqual(Assistant.seconds("727"), 727)
        XCTAssertEqual(Assistant.clean("a \u{2014} b \u{1F600} c \u{2013} d"), "a, b c, d")
        XCTAssertEqual(Assistant.clean("Fini \u{1F680}. Durée : 3 h"), "Fini. Durée : 3 h")
        XCTAssertEqual(Assistant.clean("Point 1 #2"), "Point 1 #2", "chiffres et dièse conservés")
    }

    func testLLMConfigDefaultsAndRoundTrip() {
        let defaults = UserDefaults(suiteName: "fr.charlesneveu.notekeeper.tests.\(UUID().uuidString)")!
        let loaded = LLMConfig.load(from: defaults)
        XCTAssertEqual(loaded.provider, .gemini)
        XCTAssertEqual(loaded.geminiModel, "gemini-3.1-pro-preview")
        XCTAssertEqual(loaded.ollamaModel, "qwen3:8b")
        XCTAssertEqual(loaded.ollamaURL, "http://127.0.0.1:11434")
        XCTAssertEqual(loaded.userName, "Moi")
        var c = loaded
        c.provider = .ollama; c.userName = "Charles"
        c.save(to: defaults)
        XCTAssertEqual(LLMConfig.load(from: defaults), c)
        XCTAssertTrue(c.makeClient() is OllamaClient)
        XCTAssertTrue(loaded.makeClient() is GeminiClient)
    }

    func testMockDemoAnswersEveryPrompt() async throws {
        let mock = MockLLM.demo(latency: 0)
        let p = Prompts.summarize(transcript: "x", title: "t", date: Date())
        let s = try await mock.complete(system: p.system, user: p.user, jsonMode: false)
        XCTAssertTrue(s.contains("## Questions ouvertes"))
        let t = Prompts.suggestTitle(transcript: "x")
        let title = try await mock.complete(system: t.system, user: t.user, jsonMode: false)
        XCTAssertEqual(title, "Cadrage refonte site Atelier Morin")
    }
}
