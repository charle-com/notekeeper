import SwiftUI
import NotekeeperCore

struct MeetingView: View {
    @EnvironmentObject var model: AppModel
    @State private var tab: Tab = .transcript
    @State private var title: String = ""
    @State private var showAsk = false

    enum Tab: String, CaseIterable { case transcript = "Transcript", summary = "Résumé", notes = "Mes notes" }

    var meeting: Meeting? { model.selectedMeeting }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.isRecording, model.recording?.meetingID == meeting?.id { LiveBar() ; Divider() }
            HSplitView {
                content.frame(minWidth: 420)
                if showAsk { AskPanel(allMeetings: false).frame(minWidth: 300, idealWidth: 340, maxWidth: 460) }
            }
        }
        .onAppear { title = meeting?.title ?? "" }
        .onChange(of: model.selectedMeetingID) { _ in title = meeting?.title ?? ""; if model.isRecording { tab = .transcript } }
        .onChange(of: meeting?.title) { t in if let t, t != title { title = t } }
        .onReceive(NotificationCenter.default.publisher(for: .qaCommand)) { n in
            guard let cmd = n.object as? String else { return }
            switch cmd {
            case "tab:summary": tab = .summary
            case "tab:notes": tab = .notes
            case "tab:transcript": tab = .transcript
            case "ask:show": showAsk = true
            default: break
            }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Toggle(isOn: $showAsk) { Label("Demander", systemImage: "sidebar.right") }
                    .help("Poser une question sur cette réunion")
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                TextField("Titre", text: $title, onCommit: { model.updateTitle(title) })
                    .textFieldStyle(.plain).font(NK.title(22))
                    .onSubmit { model.updateTitle(title) }
                Spacer()
                if let m = meeting, let p = model.processing[m.id] {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text(p).font(.system(size: 12)).foregroundStyle(.secondary) }
                } else if let m = meeting, m.status == .failed {
                    Label("Post-traitement en échec", systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(NK.warn)
                }
            }
            if let m = meeting {
                HStack(spacing: 10) {
                    Text(m.startedAt.formatted(.dateTime.weekday(.wide).day().month(.wide).hour().minute().locale(Locale(identifier: "fr_FR"))))
                    Text("·"); Text(TimeFormat.clock(m.duration)).monospacedDigit()
                    Text("·"); Text(m.source)
                    if !m.participants.isEmpty { Text("·"); Text("Invités : " + m.participants.joined(separator: ", ")).lineLimit(1) }
                }
                .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                SpeakerStrip()
                Spacer()
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).frame(width: 300)
            }
        }
        .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 10)
    }

    @ViewBuilder private var content: some View {
        switch tab {
        case .transcript: TranscriptView()
        case .summary: SummaryView()
        case .notes: NotesView()
        }
    }
}

/// Pastilles des locuteurs, cliquables : renommer, fusionner.
struct SpeakerStrip: View {
    @EnvironmentObject var model: AppModel
    @State private var editing: Speaker?
    @State private var name = ""

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(model.speakers.enumerated()), id: \.element.id) { i, s in
                Button {
                    editing = s; name = s.isMe ? AppSettings.userName : (s.name ?? "")
                } label: {
                    SpeakerChip(name: s.isMe ? AppSettings.userName : s.displayName,
                                color: NK.speakerColor(index: i, isMe: s.isMe), isMe: s.isMe)
                }
                .buttonStyle(.plain)
                .popover(isPresented: Binding(get: { editing?.id == s.id }, set: { if !$0 { editing = nil } })) {
                    SpeakerEditor(speaker: s, name: $name) { editing = nil }
                }
            }
        }
    }
}

struct SpeakerEditor: View {
    @EnvironmentObject var model: AppModel
    let speaker: Speaker
    @Binding var name: String
    var done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(speaker.isMe ? "C'est toi" : "Qui est \(speaker.label) ?").font(.system(size: 13, weight: .semibold))
            TextField("Prénom Nom", text: $name).textFieldStyle(.roundedBorder).frame(width: 220)
                .onSubmit { save() }
            if !speaker.isMe, model.speakers.count > 2 {
                Menu("Fusionner avec…") {
                    ForEach(model.speakers.filter { $0.id != speaker.id }) { other in
                        Button(other.isMe ? AppSettings.userName : other.displayName) { model.merge(speaker: speaker, into: other); done() }
                    }
                }
                .controlSize(.small)
            }
            HStack {
                Spacer()
                Button("Annuler") { done() }.keyboardShortcut(.cancelAction)
                Button("Enregistrer") { save() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
    }

    private func save() {
        if speaker.isMe { AppSettings.userName = name.trimmingCharacters(in: .whitespaces) }
        model.rename(speaker: speaker, to: name)
        done()
    }
}

/// Bandeau pendant l'enregistrement : chrono, vumètres, dernier « qu'est-ce que j'ai raté ».
struct LiveBar: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 14) {
                HStack(spacing: 6) {
                    Circle().fill(NK.live).frame(width: 8, height: 8)
                    Text(TimeFormat.clock(model.recording?.elapsed ?? 0)).font(NK.mono(13)).monospacedDigit()
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack { Text(AppSettings.userName).font(.system(size: 10)).foregroundStyle(.secondary); LevelMeter(level: model.recording?.micLevel ?? 0, color: NK.accent) }
                    HStack { Text("Les autres").font(.system(size: 10)).foregroundStyle(.secondary); LevelMeter(level: model.recording?.systemLevel ?? 0, color: NK.speakerColor(index: 1, isMe: false)) }
                }
                .frame(width: 220)
                Spacer()
                Text(model.capture.micDeviceName).font(.system(size: 11)).foregroundStyle(.secondary)
                Button { model.catchUp() } label: {
                    if model.catchUpBusy { ProgressView().controlSize(.small) } else { Label("Qu'est-ce que j'ai raté ?", systemImage: "clock.arrow.circlepath") }
                }
                .disabled(model.catchUpBusy)
            }
            if let t = model.catchUpText {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "sparkles").foregroundStyle(NK.accent)
                    MarkdownView(text: t).font(.system(size: 12))
                    Spacer()
                }
                .padding(10)
                .background(NK.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}
