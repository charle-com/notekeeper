import SwiftUI
import NotekeeperCore

/// « Demander » : chat avec citations cliquables (ouvre la réunion et surligne le passage).
struct AskPanel: View {
    @EnvironmentObject var model: AppModel
    let allMeetings: Bool
    @State private var question = ""

    private var messages: [ChatMessage] { allMeetings ? model.globalChat : model.chat }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(allMeetings ? "Toutes les réunions" : "Cette réunion", systemImage: "sparkles").font(.system(size: 12, weight: .semibold))
                Spacer()
                if !messages.isEmpty { Button("Effacer") { model.clearChat(allMeetings: allMeetings) }.controlSize(.small).buttonStyle(.plain).foregroundStyle(.secondary) }
            }
            .padding(12)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if messages.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Pose une question, la réponse s'appuie sur le transcript et cite ses sources.").foregroundStyle(.secondary)
                                ForEach(["Qu'est-ce qui a été décidé ?", "Qu'est-ce qu'on attend de moi ?", "Quelles sont les prochaines échéances ?"], id: \.self) { s in
                                    Button(s) { question = s; send() }.buttonStyle(.link).font(.system(size: 12))
                                }
                            }
                            .font(.system(size: 12)).padding(.top, 6)
                        }
                        ForEach(messages) { m in ChatBubble(message: m).id(m.id) }
                        if model.askBusy { HStack { ProgressView().controlSize(.small); Text("Je cherche…").foregroundStyle(.secondary).font(.system(size: 12)) } }
                    }
                    .padding(12)
                }
                .onChange(of: messages.count) { _ in if let l = messages.last { withAnimation { proxy.scrollTo(l.id, anchor: .bottom) } } }
            }
            Divider()
            HStack(spacing: 8) {
                TextField("Demander…", text: $question).textFieldStyle(.roundedBorder).onSubmit { send() }
                Button { send() } label: { Image(systemName: "arrow.up.circle.fill").font(.system(size: 20)) }
                    .buttonStyle(.plain).foregroundStyle(question.isEmpty || model.askBusy ? Color.secondary : NK.accent)
                    .disabled(question.isEmpty || model.askBusy)
            }
            .padding(10)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .onAppear { if allMeetings { model.loadGlobalChat() } }
    }

    private func send() {
        let q = question; question = ""
        model.ask(q, allMeetings: allMeetings)
    }
}

struct ChatBubble: View {
    @EnvironmentObject var model: AppModel
    let message: ChatMessage
    var body: some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 6) {
            if message.role == .user {
                Text(message.markdown).font(.system(size: 13))
                    .padding(10).background(NK.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                MarkdownView(text: message.markdown).font(.system(size: 13))
                if !message.citations.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(message.citations.enumerated()), id: \.offset) { _, c in
                            Button {
                                model.selectedMeetingID = c.meetingID
                                NotificationCenter.default.post(name: .scrollToTime, object: c.start)
                            } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Image(systemName: "quote.opening").font(.system(size: 9))
                                    Text("\(c.meetingTitle) · \(TimeFormat.clock(c.start))").font(.system(size: 11, weight: .medium))
                                    Text(c.quote).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.top, 2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
    }
}

/// Feuille « Demander » sur toutes les réunions.
struct AskSheet: View {
    @Environment(\.dismiss) private var dismiss
    let allMeetings: Bool
    var body: some View {
        VStack(spacing: 0) {
            AskPanel(allMeetings: allMeetings)
            Divider()
            HStack { Spacer(); Button("Fermer") { dismiss() }.keyboardShortcut(.cancelAction) }.padding(10)
        }
        .frame(width: 560, height: 560)
    }
}

extension Notification.Name {
    static let scrollToTime = Notification.Name("nk.scrollToTime")
}
