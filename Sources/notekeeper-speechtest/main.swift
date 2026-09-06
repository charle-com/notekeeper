import Foundation
import NotekeeperCore
import NotekeeperSpeech

// notekeeper-speechtest live <mic.wav> <system.wav>   : rejoue les WAV en temps simulé (blocs de 100 ms)
// notekeeper-speechtest final <mic.wav> <system.wav>  : passage final + diarisation

setvbuf(stdout, nil, _IOLBF, 0)

func out(_ s: String) { print(s); fflush(stdout) }
func fail(_ s: String) -> Never { out("ERREUR : \(s)"); exit(1) }

let args = CommandLine.arguments
guard args.count == 4, ["live", "final"].contains(args[1]) else {
    fail("usage : notekeeper-speechtest live|final <mic.wav> <system.wav>")
}
let mode = args[1]
let micURL = URL(fileURLWithPath: args[2])
let sysURL = URL(fileURLWithPath: args[3])
let dictionary = ["Alexander", "GreenLog", "Kheops", "ShippingBo", "Shopify", "Meta"]
let meetingID = UUID()

let engine = WhisperSpeechEngine()

func prepare() async throws {
    let t0 = Date()
    try await engine.prepare { out("  [prépa] \($0)") }
    let profile = await engine.activeProfileLabel() ?? "?"
    let load = await engine.whisper.lastLoadDuration
    out(String(format: "Moteur prêt en %.1f s (chargement Whisper %.1f s), profil : %@, diarizer : %@",
               Date().timeIntervalSince(t0), load, profile, engine.diarizer.isReady ? "prêt" : "absent"))
}

func runLive() async throws {
    var mic = try AudioFileLoader.loadMono16k(url: micURL)
    var sys = try AudioFileLoader.loadMono16k(url: sysURL)
    out(String(format: "Audio : micro %.1f s, système %.1f s", Double(mic.count) / 16_000, Double(sys.count) / 16_000))
    // Comme une vraie capture, les deux pistes durent autant : la plus courte est complétée de silence
    // (plus 1,5 s de queue) pour que le dernier énoncé se ferme par la VAD et non par stopLive.
    let padded = max(mic.count, sys.count) + 16_000 * 3 / 2
    mic.append(contentsOf: [Float](repeating: 0, count: padded - mic.count))
    sys.append(contentsOf: [Float](repeating: 0, count: padded - sys.count))
    try await prepare()

    let wall0 = Date()
    var latencies: [Double] = []
    var finals = 0
    let lock = NSLock()
    engine.startLive(meetingID: meetingID, language: "fr", dictionary: dictionary) { event in
        let now = Date().timeIntervalSince(wall0)
        switch event {
        case .partial(let track, let text):
            out(String(format: "[%6.2f] partial  %-6@ : %@", now, track.rawValue, text))
        case .final(let s):
            let latency = now - s.end
            lock.lock(); latencies.append(latency); finals += 1; lock.unlock()
            out(String(format: "[%6.2f] FINAL    %-6@ %6.2f-%6.2f  latence %.2f s : %@",
                       now, s.track.rawValue, s.start, s.end, latency, s.text))
        case .status(let m): out(String(format: "[%6.2f] statut : %@", now, m))
        case .error(let m): out(String(format: "[%6.2f] erreur : %@", now, m))
        }
    }

    let block = 1_600 // 100 ms
    let total = max(mic.count, sys.count)
    var i = 0
    while i < total {
        let t = Double(i) / 16_000
        let target = wall0.addingTimeInterval(t)
        let wait = target.timeIntervalSinceNow
        if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
        if i < mic.count { engine.feed(track: .mic, samples: Array(mic[i..<min(i + block, mic.count)]), at: t) }
        if i < sys.count { engine.feed(track: .system, samples: Array(sys[i..<min(i + block, sys.count)]), at: t) }
        i += block
    }
    out(String(format: "[%6.2f] fin de la lecture (%.1f s d'audio), stopLive…", Date().timeIntervalSince(wall0), Double(total) / 16_000))
    let ts = Date()
    await engine.stopLive()
    out(String(format: "stopLive en %.2f s", Date().timeIntervalSince(ts)))
    lock.lock()
    if !latencies.isEmpty {
        out(String(format: "%d segments finaux, latence moyenne %.2f s, max %.2f s",
                   finals, latencies.reduce(0, +) / Double(latencies.count), latencies.max()!))
    } else {
        out("Aucun segment final émis")
    }
    lock.unlock()
}

func runFinal() async throws {
    try await prepare()
    let mic = try AudioFileLoader.loadMono16k(url: micURL)
    let sys = try AudioFileLoader.loadMono16k(url: sysURL)
    let audioSeconds = Double(mic.count + sys.count) / 16_000
    let t0 = Date()
    let (segments, spans) = try await engine.finalPass(meetingID: meetingID, language: "fr", dictionary: dictionary,
                                                       micWAV: micURL, systemWAV: sysURL) { out("  [final] \($0)") }
    let elapsed = Date().timeIntervalSince(t0)
    out(String(format: "Passage final : %.1f s d'audio traitées en %.1f s, facteur temps réel %.3f",
               audioSeconds, elapsed, elapsed / audioSeconds))
    out("\nSegments (\(segments.count)) :")
    for s in segments {
        out(String(format: "  %-6@ %6.2f-%6.2f : %@", s.track.rawValue, s.start, s.end, s.text))
    }
    let clusters = Set(spans.map(\.clusterKey)).sorted()
    out("\nSpans de diarisation (\(spans.count), \(clusters.count) locuteurs : \(clusters.joined(separator: ", "))) :")
    for sp in spans {
        out(String(format: "  %@  %6.2f-%6.2f", sp.clusterKey, sp.start, sp.end))
    }
    let me = UUID()
    let merged = TranscriptMerge.assignSpeakers(segments: segments, spans: spans, meetingID: meetingID, meSpeakerID: me)
    var speakers = merged.speakers
    speakers.append(Speaker(id: me, meetingID: meetingID, label: "Moi", isMe: true))
    out("\nTranscript fusionné :")
    out(TranscriptMerge.render(TranscriptMerge.coalesce(merged.segments), speakers: speakers))
}

let task = Task {
    do {
        if mode == "live" { try await runLive() } else { try await runFinal() }
        exit(0)
    } catch {
        fail("\(error)")
    }
}
RunLoop.main.run()
