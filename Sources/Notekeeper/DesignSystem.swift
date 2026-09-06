import SwiftUI

/// Look natif macOS : polices système, couleurs sémantiques, un seul accent. La signature visuelle
/// est le transcript à deux voix (moi / les autres) et les pastilles de locuteurs.
enum NK {
    static let accent = Color.accentColor
    static let live = Color(red: 0.86, green: 0.22, blue: 0.27)
    static let ok = Color(red: 0.18, green: 0.62, blue: 0.40)
    static let warn = Color(red: 0.88, green: 0.58, blue: 0.14)

    /// Couleur d'un locuteur : « Moi » prend l'accent, les autres une teinte stable par index.
    static func speakerColor(index: Int, isMe: Bool) -> Color {
        if isMe { return accent }
        let palette: [Color] = [
            Color(red: 0.80, green: 0.42, blue: 0.16),
            Color(red: 0.24, green: 0.56, blue: 0.62),
            Color(red: 0.60, green: 0.36, blue: 0.70),
            Color(red: 0.72, green: 0.30, blue: 0.40),
            Color(red: 0.30, green: 0.58, blue: 0.32),
            Color(red: 0.52, green: 0.50, blue: 0.20),
        ]
        return palette[abs(index) % palette.count]
    }

    static func title(_ size: CGFloat = 20) -> Font { .system(size: size, weight: .semibold) }
    static func body(_ size: CGFloat = 13) -> Font { .system(size: size) }
    static func mono(_ size: CGFloat = 11) -> Font { .system(size: size, design: .monospaced) }
}

/// Rendu markdown léger et fidèle pour les résumés : titres `##`/`###`, puces, gras/italique en ligne.
struct MarkdownView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in
                switch b {
                case .h2(let s): Text(s).font(.system(size: 15, weight: .semibold)).padding(.top, 10)
                case .h3(let s): Text(s).font(.system(size: 13, weight: .semibold)).padding(.top, 6)
                case .bullet(let s, let level):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•").foregroundStyle(.secondary)
                        inline(s)
                    }.padding(.leading, CGFloat(level) * 14)
                case .numbered(let n, let s):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(n).").foregroundStyle(.secondary).monospacedDigit()
                        inline(s)
                    }
                case .para(let s): inline(s)
                case .blank: Spacer().frame(height: 2)
                }
            }
        }
        .textSelection(.enabled)
    }

    private func inline(_ s: String) -> Text {
        if let a = try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(a)
        }
        return Text(s)
    }

    private enum Block { case h2(String), h3(String), bullet(String, Int), numbered(Int, String), para(String), blank }

    private var blocks: [Block] {
        var out: [Block] = []
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { out.append(.blank); continue }
            if line.hasPrefix("### ") { out.append(.h3(String(line.dropFirst(4)))); continue }
            if line.hasPrefix("## ") { out.append(.h2(String(line.dropFirst(3)))); continue }
            if line.hasPrefix("# ") { out.append(.h2(String(line.dropFirst(2)))); continue }
            let indent = raw.prefix(while: { $0 == " " }).count / 2
            if line.hasPrefix("- ") || line.hasPrefix("* ") { out.append(.bullet(String(line.dropFirst(2)), indent)); continue }
            if let dot = line.firstIndex(of: "."), line[..<dot].allSatisfy(\.isNumber), !line[..<dot].isEmpty,
               let n = Int(line[..<dot]) {
                out.append(.numbered(n, line[line.index(after: dot)...].trimmingCharacters(in: .whitespaces))); continue
            }
            out.append(.para(line))
        }
        return out
    }
}

/// Pastille de locuteur : point coloré + nom, cliquable pour renommer.
struct SpeakerChip: View {
    let name: String
    let color: Color
    var isMe: Bool = false
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(name).font(.system(size: 12, weight: isMe ? .semibold : .regular))
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(color.opacity(0.12), in: Capsule())
    }
}

/// Vumètre horizontal discret.
struct LevelMeter: View {
    let level: Float
    let color: Color
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(color).frame(width: max(2, g.size.width * CGFloat(min(1, level))))
            }
        }
        .frame(height: 4)
        .animation(.linear(duration: 0.05), value: level)
    }
}
