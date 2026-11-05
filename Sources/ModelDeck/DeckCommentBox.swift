import SwiftUI
import ModelDeckCore

/// Comment box for Deck Officer. target is "global" or a card/row id; hidden entirely when the tool is switched off.
struct DeckCommentBox: View {
    @EnvironmentObject var store: DeckStore
    @AppStorage("deckCommentsEnabled") private var available = false
    @AppStorage("deckCommentsOn") private var on = true
    let target: String
    var compact = false
    @State private var text = ""
    @State private var open = false
    @State private var error: String?

    private var comments: [DeckComment] { store.deckComments.filter { $0.target == target } }

    var body: some View {
        if available && on {
            VStack(alignment: .leading, spacing: 8) {
                if compact && !open {
                    Button(L("Commenta"), systemImage: "bubble.left") { open = true }.buttonStyle(.borderless).font(.system(size: 11))
                } else {
                    HStack(spacing: 8) {
                        TextField(L(target == "global" ? "Scrivi a Deck Officer" : "Commento per Deck Officer su questo elemento"), text: $text, axis: .vertical)
                            .textFieldStyle(.roundedBorder).lineLimit(1...4).onSubmit(send)
                        Button(L("Invia"), action: send).buttonStyle(.bordered).disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }.font(.system(size: 11))
                }
                if let error { Text(D(error)).font(.system(size: 10)).foregroundStyle(DeckTheme.amber) }
                ForEach(comments.suffix(compact ? 3 : 6)) { comment in thread(comment) }
            }
        }
    }

    private func thread(_ comment: DeckComment) -> some View {
        let reply = store.deckReplies[comment.key]
        let state = reply?.status == "done" || reply?.text != nil ? "Fatto" : reply?.status == "picked_up" ? "Preso in carico" : "Inviato"
        return VStack(alignment: .leading, spacing: 4) {
            Text(comment.text).font(.system(size: 11)).textSelection(.enabled)
            if let text = reply?.text, !text.isEmpty {
                Text(text).font(.system(size: 11)).foregroundStyle(DeckTheme.mint).textSelection(.enabled).padding(.leading, 12)
            } else { Text(D(state)).font(.system(size: 10)).foregroundStyle(DeckTheme.muted) }
        }.padding(8).frame(maxWidth: .infinity, alignment: .leading).background(DeckTheme.subtle.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    private func send() {
        error = store.sendDeckComment(target: target, text: text)
        if error == nil { text = "" }
    }
}
