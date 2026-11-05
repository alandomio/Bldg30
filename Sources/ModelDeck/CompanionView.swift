import SwiftUI
import ModelDeckCore

private struct PendingClick: Identifiable {
    let id = UUID()
    let actionID: String, target: String, label: String
    var draft: String? = nil
}

struct CompanionView: View {
    @EnvironmentObject var store: DeckStore
    @State private var tab = "decisions"
    @State private var index = 0
    @State private var openDrafts = Set<String>()
    @State private var confirm: PendingClick?
    @State private var feedback: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let feed = store.companionFeed {
                let stale = feed.isStale()
                status(feed, stale: stale)
                Picker("", selection: $tab) {
                    Text(L("Decisioni (\(feed.decisions.count))")).tag("decisions")
                    Text(L("MR e revisioni (\(feed.mrs.count))")).tag("mrs")
                    Text(L("Ticket (\(feed.tickets.count))")).tag("tickets")
                }.labelsHidden().pickerStyle(.segmented).frame(maxWidth: 520)
                Group {
                    if tab == "decisions" { decisions(feed.decisions, locked: stale) }
                    else if tab == "mrs" { mrs(feed.mrs, locked: stale) }
                    else { tickets(feed.tickets, locked: stale) }
                }.opacity(stale ? 0.45 : 1)
            } else {
                DeckCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L(CompanionSettings.enabled ? "Nessun feed disponibile" : "Companion spento")).font(.system(size: 15, weight: .semibold))
                        Text(D(store.companionError ?? (CompanionSettings.enabled ? "In attesa del file feed." : "Attivalo nelle impostazioni e indica il file feed."))).font(.system(size: 11)).foregroundStyle(DeckTheme.muted)
                    }
                }
            }
            if let feedback { Text(D(feedback)).font(.system(size: 12)).foregroundStyle(DeckTheme.amber).textSelection(.enabled) }
        }
        .alert(item: $confirm) { pending in
            Alert(title: Text(L("Inviare a firstmate?")), message: Text(D(pending.label)),
                  primaryButton: .default(Text(L("Invia"))) { send(pending) }, secondaryButton: .cancel(Text(L("Annulla"))))
        }
    }

    private func status(_ feed: CompanionFeed, stale: Bool) -> some View {
        HStack(spacing: 10) {
            StatusPill(text: stale ? "Feed non aggiornato" : "Feed aggiornato", color: stale ? DeckTheme.amber : DeckTheme.mint)
            Text(L("Generato \(feed.generatedAt.formatted(.relative(presentation: .named))) da \(feed.producer)")).font(.system(size: 10)).foregroundStyle(DeckTheme.muted)
            if let error = store.companionError { Text(D(error)).font(.system(size: 10)).foregroundStyle(DeckTheme.amber) }
            Spacer()
        }
    }

    private func decisions(_ items: [CompanionFeed.Decision], locked: Bool) -> some View {
        let position = min(index, max(0, items.count - 1))
        return Group {
            if items.isEmpty { empty("Nessuna decisione in attesa.") }
            else {
                let item = items[position]
                DeckCard {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text(L("Decisione \(position + 1) di \(items.count)")).font(.system(size: 10, design: .monospaced)).foregroundStyle(DeckTheme.muted)
                            if item.urgent { StatusPill(text: "Urgente", color: .red) }
                            Spacer()
                            Button { index = position - 1 } label: { Image(systemName: "chevron.left") }.disabled(position == 0)
                            Button { index = position + 1 } label: { Image(systemName: "chevron.right") }.disabled(position >= items.count - 1)
                        }.buttonStyle(.bordered)
                        Text(item.title).font(.system(size: 18, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                        if !item.project.isEmpty { Text(item.project).font(.system(size: 11)).foregroundStyle(DeckTheme.muted) }
                        if !item.whyNow.isEmpty { Text(item.whyNow).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true) }
                        ForEach(Array(item.options.enumerated()), id: \.offset) { offset, option in
                            let key = "decision:\(item.id):option:\(offset)|\(item.id)"
                            HStack(alignment: .top, spacing: 12) {
                                Button(option.label) { request(PendingClick(actionID: "decision:\(item.id):option:\(offset)", target: item.id, label: option.label, draft: option.label)) }
                                    .buttonStyle(.borderedProminent).disabled(locked)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(option.consequence).font(.system(size: 11)).foregroundStyle(DeckTheme.muted).fixedSize(horizontal: false, vertical: true)
                                    if option.label == item.recommendation { Text(L("Consigliata")).font(.system(size: 10, weight: .semibold)).foregroundStyle(DeckTheme.mint) }
                                    sentLabel(key)
                                }
                            }
                        }
                        ForEach(item.links, id: \.self) { Link($0.absoluteString, destination: $0).font(.system(size: 10)) }
                        DeckCommentBox(target: item.id, compact: true).id(item.id)
                    }
                }
            }
        }
    }

    private func mrs(_ items: [CompanionFeed.MergeRequest], locked: Bool) -> some View {
        VStack(spacing: 12) {
            if items.isEmpty { empty("Nessuna MR in attesa.") }
            ForEach(items) { mr in
                DeckCard {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            StatusPill(text: verdictTitle(mr.verdict), color: verdictColor(mr.verdict))
                            Text(mr.ref).font(.system(size: 10, design: .monospaced)).foregroundStyle(DeckTheme.muted)
                            Text(D(mr.role == "author" ? "Autore" : "Revisore")).font(.system(size: 10)).foregroundStyle(DeckTheme.muted)
                            Spacer()
                            Link(destination: mr.url) { Image(systemName: "arrow.up.right.square") }
                        }
                        Text(mr.title).font(.system(size: 14, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                        Text(L("\(mr.label) · prossimo: \(mr.nextOwner) · pipeline \(mr.pipeline) · \(mr.openThreads) thread aperti")).font(.system(size: 11)).foregroundStyle(DeckTheme.muted)
                        if !mr.drafts.isEmpty {
                            Toggle(L("Bozze (\(mr.drafts.count))"), isOn: Binding(get: { openDrafts.contains(mr.ref) }, set: { if $0 { openDrafts.insert(mr.ref) } else { openDrafts.remove(mr.ref) } }))
                                .toggleStyle(.checkbox).font(.system(size: 11))
                            if openDrafts.contains(mr.ref) {
                                ForEach(mr.drafts) { draft in
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(draft.text).font(.system(size: 11)).textSelection(.enabled).padding(8)
                                            .frame(maxWidth: .infinity, alignment: .leading).background(DeckTheme.subtle.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                                        HStack {
                                            Button(L("Invia bozza")) { request(PendingClick(actionID: "draft:" + draft.id, target: draft.targetUrl, label: draft.text, draft: draft.text), confirmFirst: true) }.disabled(locked)
                                            sentLabel("draft:\(draft.id)|\(draft.targetUrl)")
                                        }.buttonStyle(.bordered)
                                    }
                                }
                            }
                        }
                        actions(mr.actions, target: mr.url.absoluteString, locked: locked)
                        DeckCommentBox(target: mr.ref, compact: true)
                    }
                }
            }
        }
    }

    private func tickets(_ items: [CompanionFeed.Ticket], locked: Bool) -> some View {
        VStack(spacing: 12) {
            if items.isEmpty { empty("Nessun ticket aperto.") }
            ForEach(items) { ticket in
                DeckCard {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(ticket.identifier).font(.system(size: 11, weight: .semibold, design: .monospaced))
                            StatusPill(text: ticket.status, color: DeckTheme.blue)
                            Spacer()
                            Link(destination: ticket.url) { Image(systemName: "arrow.up.right.square") }
                        }
                        Text(ticket.title).font(.system(size: 14, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                        if let finish = ticket.finish {
                            Text(L("Per chiudere: \(finish.step) · \(finish.owner)")).font(.system(size: 11)).foregroundStyle(DeckTheme.muted)
                        }
                        if !ticket.linkedMrs.isEmpty { Text(ticket.linkedMrs.joined(separator: " · ")).font(.system(size: 10, design: .monospaced)).foregroundStyle(DeckTheme.muted) }
                        actions(ticket.actions, target: ticket.identifier, locked: locked)
                        DeckCommentBox(target: ticket.identifier, compact: true)
                    }
                }
            }
        }
    }

    private func actions(_ list: [CompanionFeed.Action], target: String, locked: Bool) -> some View {
        HStack(spacing: 10) {
            ForEach(list) { action in
                Button(action.label) { request(PendingClick(actionID: action.id, target: target, label: action.label), confirmFirst: action.outward) }
                    .buttonStyle(.bordered).disabled(locked)
                sentLabel(action.id + "|" + target)
            }
        }
    }

    @ViewBuilder private func sentLabel(_ key: String) -> some View {
        if let state = store.companionStatuses[key] {
            Text(D(state == .sent ? "Inviato" : state == .pickedUp ? "Preso in carico" : "Fatto")).font(.system(size: 10)).foregroundStyle(DeckTheme.mint)
        }
    }
    private func empty(_ text: String) -> some View { DeckCard { Text(D(text)).font(.system(size: 12)).foregroundStyle(DeckTheme.muted) } }
    private func verdictTitle(_ verdict: String) -> String {
        switch verdict { case "close": "Da chiudere"; case "notyet": "Non ancora"; case "blocked": "Bloccata"; default: "In attesa" }
    }
    private func verdictColor(_ verdict: String) -> Color {
        switch verdict { case "close": DeckTheme.mint; case "notyet": DeckTheme.amber; case "blocked": .red; default: DeckTheme.muted }
    }
    /// Outward actions and drafts ask for confirmation first; everything only files an inbox note.
    private func request(_ click: PendingClick, confirmFirst: Bool = false) {
        if confirmFirst { confirm = click } else { send(click) }
    }
    private func send(_ click: PendingClick) {
        feedback = store.sendCompanionClick(actionID: click.actionID, target: click.target, draftText: click.draft)
    }
}
