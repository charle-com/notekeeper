import SwiftUI
import NotekeeperCore

/// Le transcript : un paragraphe par tour de parole, nom coloré, horodatage. Pendant le live, les
/// hypothèses en cours s'affichent en gris sous le dernier tour.
struct TranscriptView: View {
    @EnvironmentObject var model: AppModel
    @State private var highlight: UUID?

    private var turns: [TranscriptSegment] { TranscriptMerge.coalesce(model.segments) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if turns.isEmpty && !model.isRecording {
                        Text(model.selectedMeeting?.status == .processing ? "Retranscription en cours…" : "Aucun transcript.")
                            .foregroundStyle(.secondary).padding(.top, 30)
                    }
                    ForEach(turns) { seg in
                        TurnView(segment: seg, highlighted: highlight == seg.id).id(seg.id)
                    }
                    if let r = model.recording, r.meetingID == model.selectedMeetingID {
                        if let p = r.partialMic { PartialView(name: AppSettings.userName, text: p, color: NK.accent) }
                        if let p = r.partialSystem { PartialView(name: "Les autres", text: p, color: NK.speakerColor(index: 1, isMe: false)) }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                }
                .padding(20)
                .frame(maxWidth: 820, alignment: .leading)
            }
            .onChange(of: model.segments.count) { _ in
                if model.isRecording { withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
            }
            .onReceive(NotificationCenter.default.publisher(for: .scrollToTime)) { n in
                guard let t = n.object as? TimeInterval else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    let ts = turns
                    guard let target = ts.first(where: { $0.start <= t && t <= $0.end + 0.5 })?.id
                            ?? ts.min(by: { abs($0.start - t) < abs($1.start - t) })?.id else { return }
                    withAnimation { proxy.scrollTo(target, anchor: .center) }
                    highlight = target
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { if highlight == target { highlight = nil } }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .scrollToSegment)) { n in
                guard let id = n.object as? UUID else { return }
                // Le segment cherché peut avoir été fusionné dans un tour : on vise le tour qui le contient.
                let target = turns.first(where: { t in model.segments.contains(where: { $0.id == id && $0.start >= t.start && $0.start <= t.end }) })?.id ?? id
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    withAnimation { proxy.scrollTo(target, anchor: .center) }
                    highlight = target
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { if highlight == target { highlight = nil } }
                }
            }
        }
    }
}

struct TurnView: View {
    @EnvironmentObject var model: AppModel
    let segment: TranscriptSegment
    let highlighted: Bool

    var body: some View {
        let sp = model.speaker(for: segment)
        let isMe = sp?.isMe ?? (segment.track == .mic)
        let color = NK.speakerColor(index: model.speakerIndex(sp), isMe: isMe)
        HStack(alignment: .top, spacing: 12) {
            Text(TimeFormat.clock(segment.start)).font(NK.mono(11)).foregroundStyle(.tertiary).frame(width: 52, alignment: .trailing).padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.displayName(for: segment)).font(.system(size: 12, weight: .semibold)).foregroundStyle(color)
                Text(segment.text).font(.system(size: 14)).lineSpacing(3).textSelection(.enabled)
            }
        }
        .padding(8)
        .background(highlighted ? NK.accent.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .animation(.easeOut(duration: 0.4), value: highlighted)
    }
}

struct PartialView: View {
    let name: String; let text: String; let color: Color
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("").frame(width: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.system(size: 12, weight: .semibold)).foregroundStyle(color.opacity(0.6))
                Text(text).font(.system(size: 14)).foregroundStyle(.tertiary).italic()
            }
        }
        .padding(8)
    }
}

struct SummaryView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let m = model.selectedMeeting {
                    if let s = m.summaryMarkdown, !s.isEmpty {
                        MarkdownView(text: s).font(.system(size: 14))
                        HStack {
                            Button("Régénérer") { model.regenerate(meeting: m) }.controlSize(.small)
                            Button("Copier") {
                                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string)
                            }.controlSize(.small)
                        }.padding(.top, 12)
                    } else if m.status == .recording {
                        Text("Le résumé sera généré à la fin de la réunion.").foregroundStyle(.secondary)
                    } else if model.processing[m.id] != nil {
                        HStack { ProgressView().controlSize(.small); Text("Génération du résumé…").foregroundStyle(.secondary) }
                    } else {
                        Text("Pas de résumé.").foregroundStyle(.secondary)
                        Button("Générer le résumé") { model.regenerate(meeting: m) }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 820, alignment: .leading)
        }
    }
}

struct NotesView: View {
    @EnvironmentObject var model: AppModel
    @State private var text = ""
    var body: some View {
        TextEditor(text: $text)
            .font(.system(size: 14))
            .scrollContentBackground(.hidden)
            .padding(16)
            .onAppear { text = model.selectedMeeting?.notes ?? "" }
            .onChange(of: model.selectedMeetingID) { _ in text = model.selectedMeeting?.notes ?? "" }
            .onChange(of: text) { t in model.updateNotes(t) }
            .overlay(alignment: .topLeading) {
                if text.isEmpty { Text("Tes notes pendant ou après la réunion (markdown).").foregroundStyle(.tertiary).padding(22).allowsHitTesting(false) }
            }
    }
}
