import XCTest
@testable import NotekeeperCore

final class StoreTests: XCTestCase {

    func testRoundTripAndSearch() throws {
        let store = try Store.inMemory()
        var m = Meeting(title: "Point Kheops", source: "Zoom", participants: ["Alexander"])
        try store.insert(m)
        let me = Speaker(meetingID: m.id, label: "Moi", name: "Charles", isMe: true)
        let other = Speaker(meetingID: m.id, label: "Locuteur 2")
        try store.upsert(me); try store.upsert(other)
        try store.insert([
            TranscriptSegment(meetingID: m.id, track: .mic, start: 0, end: 3, text: "On valide le budget SEO ?", speakerID: me.id),
            TranscriptSegment(meetingID: m.id, track: .system, start: 3.2, end: 6, text: "Oui, trente pour cent vers l'emailing.", speakerID: other.id),
        ])
        m.status = .ready; m.summaryMarkdown = "## Décisions\n- budget"
        try store.update(m)

        XCTAssertEqual(try store.meetings().count, 1)
        XCTAssertEqual(try store.meeting(m.id)?.summaryMarkdown, "## Décisions\n- budget")
        XCTAssertEqual(try store.segments(meetingID: m.id).count, 2)

        let hits = try store.search("emailing")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.speakerName, "Locuteur 2")
        // Accents ignorés, préfixe accepté.
        XCTAssertEqual(try store.search("valide").count, 1)
        XCTAssertEqual(try store.search("budg").count, 1)

        try store.rename(speakerID: other.id, name: "Alexander")
        XCTAssertEqual(try store.speakers(meetingID: m.id).first(where: { !$0.isMe })?.name, "Alexander")
        XCTAssertEqual(try store.search("emailing").first?.speakerName, "Alexander")

        try store.delete(meetingID: m.id)
        XCTAssertEqual(try store.meetings().count, 0)
        XCTAssertEqual(try store.search("emailing").count, 0)
    }

    func testAssignSpeakersAndCoalesce() {
        let mid = UUID(), me = UUID()
        let segs = [
            TranscriptSegment(meetingID: mid, track: .mic, start: 0, end: 2, text: "Bonjour"),
            TranscriptSegment(meetingID: mid, track: .system, start: 2, end: 4, text: "Salut"),
            TranscriptSegment(meetingID: mid, track: .system, start: 4.2, end: 6, text: "ça va ?"),
            TranscriptSegment(meetingID: mid, track: .system, start: 7, end: 9, text: "Moi c'est Paul"),
        ]
        let spans = [DiarizedSpan(clusterKey: "A", start: 1.9, end: 6.1), DiarizedSpan(clusterKey: "B", start: 6.9, end: 9.5)]
        let r = TranscriptMerge.assignSpeakers(segments: segs, spans: spans, meetingID: mid, meSpeakerID: me)
        XCTAssertEqual(r.speakers.count, 2)
        XCTAssertEqual(r.speakers.map(\.label), ["Locuteur 2", "Locuteur 3"])
        XCTAssertEqual(r.segments[0].speakerID, me)
        XCTAssertEqual(r.segments[1].speakerID, r.segments[2].speakerID)
        XCTAssertNotEqual(r.segments[2].speakerID, r.segments[3].speakerID)
        let c = TranscriptMerge.coalesce(r.segments)
        XCTAssertEqual(c.count, 3)
        XCTAssertEqual(c[1].text, "Salut ça va ?")
        XCTAssertEqual(TimeFormat.clock(3725), "1:02:05")
    }
}

final class EchoTests: XCTestCase {
    func testEchoRemoval() {
        let mid = UUID()
        let sys = TranscriptSegment(meetingID: mid, track: .system, start: 10, end: 16, text: "Oui, livré mardi matin, 32 palettes. Il reste le contrôle de réception.")
        let echo = TranscriptSegment(meetingID: mid, track: .mic, start: 11, end: 17, text: "oui livré mardi matin 32 palettes il reste le contrôle de réception")
        let me = TranscriptSegment(meetingID: mid, track: .mic, start: 18, end: 22, text: "Parfait, on recale ça sur le prochain départ.")
        let short = TranscriptSegment(meetingID: mid, track: .mic, start: 12, end: 13, text: "Oui")
        XCTAssertTrue(TranscriptMerge.isEcho(echo, against: [sys]))
        XCTAssertFalse(TranscriptMerge.isEcho(me, against: [sys]))
        XCTAssertFalse(TranscriptMerge.isEcho(short, against: [sys]))
        let kept = TranscriptMerge.removeEcho([sys, echo, me, short])
        XCTAssertEqual(kept.map(\.text), [sys.text, me.text, short.text])
        XCTAssertEqual(TranscriptMerge.cleanText("- Alexander, tu envoies ?  "), "Alexander, tu envoies ?")
    }
}
