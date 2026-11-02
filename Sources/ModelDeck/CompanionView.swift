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

    @State private var selected: String?
    @State private var contextText = ""
    @State private var answers: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let selected, let row = rows[selected] {
                detail(row)
            } else if store.companionFeed != nil || store.rawBoard != nil {
                let feed = store.companionFeed
                let stale = feed?.isStale() ?? false
                status(feed, stale: stale)
                Picker("", selection: $tab) {
                    Text(L("Decisioni (\(feed?.decisions.count ?? 0))")).tag("decisions")
                    Text(L("MR e revisioni (\(store.boardMRs.count))")).tag("mrs")
                    Text(L("Ticket (\(store.boardTickets.count))")).tag("tickets")
                }.labelsHidden().pickerStyle(.segmented).frame(maxWidth: 520)
                Group {
                    if tab == "decisions" { decisions(feed?.decisions ?? [], locked: stale) }
                    else if tab == "mrs" { mrs(store.boardMRs, locked: stale) }
                    else { tickets(store.boardTickets, locked: stale) }
                }.opacity(stale && tab == "decisions" ? 0.45 : 1)
            } else {
                DeckCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L(CompanionSettings.enabled ? "Nessun feed disponibile" : "Command Bridge spento")).font(.system(size: 15, weight: .semibold))
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

    private enum Row { case mr(BoardMR), ticket(BoardTicketRow) }
    private var rows: [String: Row] {
        var result: [String: Row] = [:]
        for mr in store.boardMRs { result[mr.ref] = .mr(mr) }
        for ticket in store.boardTickets { result[ticket.identifier] = .ticket(ticket) }
        return result
    }

    private func status(_ feed: CompanionFeed?, stale: Bool) -> some View {
        HStack(spacing: 10) {
            if let feed {
                StatusPill(text: stale ? "Feed non aggiornato" : "Feed aggiornato", color: stale ? DeckTheme.amber : DeckTheme.mint)
                Text(L("Generato \(feed.generatedAt.formatted(.relative(presentation: .named))) da \(feed.producer)")).font(.system(size: 10)).foregroundStyle(DeckTheme.muted)
            }
            if let raw = store.rawBoard {
                StatusPill(text: "Dati diretti", color: DeckTheme.blue)
                Text(L("Letti \(raw.fetchedAt.formatted(.relative(presentation: .named)))")).font(.system(size: 10)).foregroundStyle(DeckTheme.muted)
            }
            if let feed, !feed.skipped.isEmpty {
                Text(L("\(feed.skipped.count) righe saltate")).font(.system(size: 10)).foregroundStyle(DeckTheme.amber).help(feed.skipped.joined(separator: "\n"))
            }
            if let error = store.companionError { Text(D(error)).font(.system(size: 10)).foregroundStyle(DeckTheme.amber) }
            if let error = store.pollError { Text(D(error)).font(.system(size: 10)).foregroundStyle(DeckTheme.amber) }
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
                            let key = CompanionAnswer.actionID(decisionID: item.id, option: option, optionIndex: offset) + "|" + item.id
                            HStack(alignment: .top, spacing: 12) {
                                Button(option.label) { sendDecision(item, option: option, index: offset) }
                                    .buttonStyle(.borderedProminent).disabled(locked)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(option.consequence).font(.system(size: 11)).foregroundStyle(DeckTheme.muted).fixedSize(horizontal: false, vertical: true)
                                    if option.label == item.recommendation { Text(L("Consigliata")).font(.system(size: 10, weight: .semibold)).foregroundStyle(DeckTheme.mint) }
                                    sentLabel(key)
                                }
                            }
                        }
                        answerField(item, locked: locked)
                        ForEach(item.links, id: \.self) { Link($0.absoluteString, destination: $0).font(.system(size: 10)) }
                    }
                }
            }
        }
    }

    private func answerField(_ item: CompanionFeed.Decision, locked: Bool) -> some View {
        let binding = Binding(get: { answers[item.id] ?? "" }, set: { answers[item.id] = $0 })
        let empty = binding.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(alignment: .leading, spacing: 6) {
            Text(L("La tua risposta o contesto")).font(.system(size: 11, weight: .semibold))
            TextEditor(text: binding).font(.system(size: 12)).frame(minHeight: 60).scrollContentBackground(.hidden)
                .padding(6).background(DeckTheme.subtle.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Button(L("Invia")) { sendDecision(item, option: nil, index: 0) }.buttonStyle(.borderedProminent).disabled(locked || empty)
                sentLabel(CompanionAnswer.actionID(decisionID: item.id, option: nil, optionIndex: 0) + "|" + item.id)
            }
            Text(L("Invia manda solo il testo. Un pulsante opzione lo manda insieme a quell’opzione.")).font(.system(size: 10)).foregroundStyle(DeckTheme.muted)
        }
    }

    private func sendDecision(_ item: CompanionFeed.Decision, option: CompanionFeed.Option?, index: Int) {
        guard let click = CompanionAnswer.click(decisionID: item.id, option: option, optionIndex: index, text: answers[item.id] ?? "") else { return }
        feedback = store.sendCompanionClick(actionID: click.actionID, target: click.target, draftText: click.draftText)
        if feedback == nil { answers[item.id] = "" }
    }

    private func mrs(_ items: [BoardMR], locked: Bool) -> some View {
        VStack(spacing: 12) {
            if items.isEmpty { empty("Nessuna MR in attesa.") }
            ForEach(items) { mr in
                DeckCard {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            verdictPill(mr.verdict, stale: mr.verdictStale)
                            Text(mr.ref).font(.system(size: 10, design: .monospaced)).foregroundStyle(DeckTheme.muted)
                            Text(D(mr.role == "author" ? "Autore" : "Revisore")).font(.system(size: 10)).foregroundStyle(DeckTheme.muted)
                            Spacer()
                            Link(destination: mr.url) { Image(systemName: "arrow.up.right.square") }
                            Image(systemName: "chevron.right").foregroundStyle(DeckTheme.muted)
                        }
                        Text(mr.title).font(.system(size: 14, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                        Text(mr.verdict == nil ? L("pipeline \(unknown(mr.pipeline)) · \(unknown(mr.openThreads)) thread aperti") : L("\(mr.label) · prossimo: \(mr.nextOwner) · pipeline \(unknown(mr.pipeline)) · \(unknown(mr.openThreads)) thread aperti")).font(.system(size: 11)).foregroundStyle(DeckTheme.muted)
                        if !mr.drafts.isEmpty {
                            Toggle(L("Bozze (\(mr.drafts.count))"), isOn: Binding(get: { openDrafts.contains(mr.ref) }, set: { if $0 { openDrafts.insert(mr.ref) } else { openDrafts.remove(mr.ref) } }))
                                .toggleStyle(.checkbox).font(.system(size: 11))
                            if openDrafts.contains(mr.ref) {
                                ForEach(mr.drafts) { draft in
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(draft.text).font(.system(size: 11)).textSelection(.enabled).padding(8)
                                            .frame(maxWidth: .infinity, alignment: .leading).background(DeckTheme.subtle.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                                        HStack {
                                            Button(L("Invia bozza")) { request(PendingClick(actionID: "draft:" + draft.id, target: draft.targetUrl, label: draft.text, draft: draft.text), confirmFirst: true) }.disabled(locked || mr.verdictStale)
                                            sentLabel("draft:\(draft.id)|\(draft.targetUrl)")
                                        }.buttonStyle(.bordered)
                                    }
                                }
                            }
                        }
                        actions(mr.actions, target: mr.url.absoluteString, locked: locked)
                    }
                }.contentShape(Rectangle()).onTapGesture { open(mr.ref) }
            }
        }
    }

    private func tickets(_ items: [BoardTicketRow], locked: Bool) -> some View {
        VStack(spacing: 12) {
            if items.isEmpty { empty("Nessun ticket aperto.") }
            ForEach(items) { ticket in
                DeckCard {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(ticket.identifier).font(.system(size: 11, weight: .semibold, design: .monospaced))
                            StatusPill(text: ticket.status, color: DeckTheme.blue)
                            if ticket.finishStale { StatusPill(text: "Verdetto superato", color: DeckTheme.amber) }
                            Spacer()
                            Link(destination: ticket.url) { Image(systemName: "arrow.up.right.square") }
                            Image(systemName: "chevron.right").foregroundStyle(DeckTheme.muted)
                        }
                        Text(ticket.title).font(.system(size: 14, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                        if let finish = ticket.finish {
                            Text(L("Per chiudere: \(finish.step) · \(finish.owner)")).font(.system(size: 11)).foregroundStyle(DeckTheme.muted)
                        }
                        if !ticket.linkedMrs.isEmpty { Text(ticket.linkedMrs.joined(separator: " · ")).font(.system(size: 10, design: .monospaced)).foregroundStyle(DeckTheme.muted) }
                        actions(ticket.actions, target: ticket.identifier, locked: locked || ticket.finishStale)
                    }
                }.contentShape(Rectangle()).onTapGesture { open(ticket.identifier) }
            }
        }
    }

    @ViewBuilder private func verdictPill(_ verdict: String?, stale: Bool) -> some View {
        if let verdict { StatusPill(text: verdictTitle(verdict), color: verdictColor(verdict)) } else { StatusPill(text: "Nessun verdetto", color: DeckTheme.muted) }
        if stale { StatusPill(text: "Verdetto superato", color: DeckTheme.amber) }
    }

    private func unknown<T>(_ value: T?) -> String { value.map { String(describing: $0) } ?? D("n/d") }
    private func open(_ ref: String) { selected = ref; contextText = ""; feedback = nil }

    private func detail(_ row: Row) -> some View {
        let ref: String, title: String, url: URL
        switch row {
        case .mr(let mr): ref = mr.ref; title = mr.title; url = mr.url
        case .ticket(let ticket): ref = ticket.identifier; title = ticket.title; url = ticket.url
        }
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button { selected = nil } label: { Label(L("Indietro"), systemImage: "chevron.left") }.buttonStyle(.bordered)
                Spacer()
                Link(destination: url) { Label(L("Apri"), systemImage: "arrow.up.right.square") }
            }
            DeckCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text(ref).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(DeckTheme.muted)
                    Text(title).font(.system(size: 18, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        switch row {
                        case .mr(let mr):
                            verdictPill(mr.verdict, stale: mr.verdictStale)
                            Text(L("pipeline \(unknown(mr.pipeline)) · \(unknown(mr.openThreads)) thread aperti")).font(.system(size: 11)).foregroundStyle(DeckTheme.muted)
                        case .ticket(let ticket):
                            StatusPill(text: ticket.status, color: DeckTheme.blue)
                            if ticket.finishStale { StatusPill(text: "Verdetto superato", color: DeckTheme.amber) }
                        }
                    }
                }
            }
            dossierCard(store.dossier(for: ref))
            DeckCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L("Aggiungi contesto")).font(.system(size: 13, weight: .semibold))
                    TextEditor(text: $contextText).font(.system(size: 12)).frame(minHeight: 70).scrollContentBackground(.hidden)
                        .padding(6).background(DeckTheme.subtle.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                    HStack {
                        Button(L("Aggiungi contesto")) {
                            let text = contextText.trimmingCharacters(in: .whitespacesAndNewlines)
                            feedback = store.sendCompanionClick(actionID: "add_context", target: ref, draftText: text)
                            if feedback == nil { contextText = "" }
                        }.buttonStyle(.borderedProminent).disabled(contextText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        sentLabel("add_context|" + ref)
                    }
                }
            }
        }
    }

    @ViewBuilder private func dossierCard(_ lookup: Dossier.Lookup) -> some View {
        switch lookup {
        case .missing:
            DeckCard { Text(L("Nessun dossier per questa voce. Compare quando il tuo assistente lo scrive accanto al feed.")).font(.system(size: 12)).foregroundStyle(DeckTheme.muted) }
        case .invalid(let error):
            DeckCard { Text(L("Dossier non valido: \(error)")).font(.system(size: 12)).foregroundStyle(DeckTheme.amber).textSelection(.enabled) }
        case .loaded(let dossier):
            DeckCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L("Dossier generato \(dossier.generatedAt.formatted(.relative(presentation: .named)))")).font(.system(size: 10)).foregroundStyle(DeckTheme.muted)
                    if !dossier.summary.isEmpty { Text(dossier.summary).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true) }
                    if !dossier.nextAction.isEmpty { section("Prossima azione", [dossier.nextAction]) }
                    if !dossier.openDecisions.isEmpty { section("Decisioni aperte", dossier.openDecisions) }
                    if !dossier.gotchas.isEmpty { section("Attenzione", dossier.gotchas) }
                    if !dossier.timeline.isEmpty { section("Cronologia", dossier.timeline.map { ($0.at.map { $0 + " · " } ?? "") + $0.text }) }
                    if !dossier.links.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L("Link")).font(.system(size: 11, weight: .semibold))
                            ForEach(dossier.links, id: \.url) { Link($0.label, destination: $0.url).font(.system(size: 11)) }
                        }
                    }
                }
            }
        }
    }

    private func section(_ title: String, _ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(D(title)).font(.system(size: 11, weight: .semibold))
            ForEach(Array(lines.enumerated()), id: \.offset) { Text($0.element).font(.system(size: 11)).foregroundStyle(DeckTheme.muted).fixedSize(horizontal: false, vertical: true).textSelection(.enabled) }
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
