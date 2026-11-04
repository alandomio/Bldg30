import SwiftUI
import ModelDeckCore

/// One key press seen by `KeyRouter`; the id makes two presses of the same key distinct.
struct KeyEvent: Equatable {
    let id = UUID()
    let key: DecisionKeys.Key, typing: Bool
}

/// Watches key presses while the decision cards are on screen; ignores them while a text field has focus.
final class KeyRouter {
    static let shared = KeyRouter()
    private var monitor: Any?
    private var owner = ""
    /// `swallow` says which keys the screen handles itself, so they do not beep.
    func start(owner: String, swallow: @escaping (DecisionKeys.Key) -> Bool = { DecisionKeys.command($0, optionCount: 26, typing: false) != nil }, _ handler: @escaping (DecisionKeys.Key, Bool) -> Void) {
        stop(owner: nil); self.owner = owner
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return event }
            let typing = NSApp.keyWindow?.firstResponder is NSText
            let key: DecisionKeys.Key
            switch event.keyCode {
            case 123: key = .left
            case 124: key = .right
            case 126: key = .up
            case 125: key = .down
            case 36, 76: key = .enter
            default: key = .character(event.charactersIgnoringModifiers ?? "")
            }
            handler(key, typing)
            return typing ? event : (swallow(key) ? nil : event)
        }
    }
    /// Only the screen that started the monitor can stop it, so a tab switch cannot stop its successor.
    func stop(owner: String?) { guard owner == nil || owner == self.owner else { return }; if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
}

extension View {
    /// A pointing-hand cursor while the mouse is over the view.
    func pointerCursor() -> some View { onHover { $0 ? NSCursor.pointingHand.push() : NSCursor.pop() } }
}

private struct PendingClick: Identifiable {
    let id = UUID()
    let actionID: String, target: String, label: String
    var draft: String? = nil
    /// "Post all": one confirmation, then one click per draft.
    var batch: [PendingClick] = []
}

struct CompanionView: View {
    @EnvironmentObject var store: DeckStore
    @State private var tab = CommandLine.arguments.contains("--mrs-tab") ? "mrs" : CommandLine.arguments.contains("--tickets-tab") ? "tickets" : CommandLine.arguments.contains("--workers-tab") ? "workers" : "decisions"
    @State private var index = 0
    @State private var openDrafts = Set<String>()
    @State private var confirm: PendingClick?
    @State private var feedback: String?

    @State private var selected: String?
    @State private var contextText = ""
    @State private var answers: [String: String] = [:]
    @State private var draftTexts: [String: String] = [:]
    @State private var openContext = Set<String>()
    @State private var detailsOpen = Set<String>()
    @State private var dropPending = Set<String>()
    @State private var dropSent = Set<String>()
    @State private var dropTasks: [String: Task<Void, Never>] = [:]
    @State private var keyPress: KeyEvent?
    @State private var selection: [String: Int] = [:]
    @State private var mrIndex = 0
    @State private var draftIndex: [String: Int] = [:]
    @State private var discarded = Set<String>()
    @State private var editingDrafts = Set<String>()
    @State private var waitingOpen = CommandLine.arguments.contains("--waiting-open")
    @State private var discardedReview = Set(UserDefaults.standard.stringArray(forKey: "discardedReviewDrafts") ?? [])
    @AppStorage("decisionOrder") private var decisionOrder = DecisionOrder.feed.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let selected, let row = rows[selected] {
                detail(row)
            } else if store.companionFeed != nil || store.rawBoard != nil {
                let feed = store.companionFeed
                let stale = feed?.isStale() ?? false
                status(feed, stale: stale)
                if stale { Text(L("Il feed è vecchio: leggi con cautela. I click vengono salvati e aspettano firstmate.")).font(.system(size: 11)).foregroundStyle(DeckTheme.amber) }
                HStack(spacing: 8) {
                    tabButton("decisions", L("Decisioni (\(openDecisions.count))"))
                    tabButton("mrs", L("MR e revisioni (\(store.boardMRs.filter { $0.waitingOn == nil }.count))"))
                    tabButton("tickets", L("Ticket (\(store.boardTickets.count))"))
                    tabButton("workers", L("Lavoratori"))
                }
                Group {
                    // A stale feed stays readable and clickable; the click state warns when firstmate does not answer.
                    if tab == "decisions" { decisions(DecisionOrder(rawValue: decisionOrder)?.apply(openDecisions) ?? openDecisions, locked: false) }
                    else if tab == "mrs" { mrs(store.boardMRs.filter { $0.waitingOn == nil }, locked: false); waitingGroup(store.boardMRs.filter { $0.waitingOn != nil }); finishedNote(feed) }
                    else if tab == "workers" { WorkersView(openDecisions: { tab = "decisions" }) }
                    else { tickets(store.boardTickets, locked: false) }
                }
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
                  primaryButton: .default(Text(L("Invia"))) { if pending.batch.isEmpty { send(pending) } else { pending.batch.forEach { send($0) } } }, secondaryButton: .cancel(Text(L("Annulla"))))
        }
    }

    /// "11 set · 52 giorni" for a dated decision: amber after 14 days, red after 30.
    private func ageLabel(_ decision: CompanionFeed.Decision) -> (text: String, color: Color)? {
        guard let created = decision.created, let days = decision.ageDays() else { return nil }
        let formatter = DateFormatter(); formatter.locale = DeckLanguage.current.locale; formatter.setLocalizedDateFormatFromTemplate("d MMM")
        let age = days == 1 ? L("1 giorno") : L("\(days) giorni")
        return (formatter.string(from: created) + " · " + age, days > 30 ? .red : days > 14 ? DeckTheme.amber : DeckTheme.muted)
    }
    private func tabButton(_ id: String, _ title: String) -> some View {
        Button(title) { tab = id }.buttonStyle(DeckTabStyle(selected: tab == id))
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

    private func decisions(_ items: [CompanionFeed.Decision], locked outerLocked: Bool) -> some View {
        let position = min(index, max(0, items.count - 1))
        return Group {
            if items.isEmpty { empty("Nessuna decisione in attesa.") }
            else {
                let item = items[position]
                let locked = outerLocked || cardBusy(item.id)
                let specific = Array(item.options.enumerated()).filter { !$0.element.isStandard }
                let standard = Array(item.options.enumerated()).filter { $0.element.isStandard }
                let recommendedOffset = CompanionRecommendation.optionIndex(recommendation: item.recommendation, options: specific.map(\.element)).map { specific[$0].offset }
                DeckCard {
                    VStack(alignment: .leading, spacing: 14) {
                        decisionHeader(item, position: position, count: items.count)
                        if dropPending.contains(item.id) || dropSent.contains(item.id) {
                            droppedRow(item, standard: standard)
                        } else {
                            CardStatusLine(target: item.id).environmentObject(store)
                            decisionText(item)
                            VStack(spacing: 8) {
                                ForEach(Array(specific.enumerated()), id: \.offset) { letterIndex, entry in
                                    optionRow(item, option: entry.element, offset: entry.offset, letter: DecisionKeys.keycap(letterIndex), recommended: entry.offset == recommendedOffset, selected: letterIndex == (selection[item.id] ?? specific.firstIndex { $0.offset == recommendedOffset } ?? 0), locked: locked)
                                }
                            }
                            if let hint = keyHint(count: specific.count) { Text(hint).font(.system(size: 10, design: .monospaced)).foregroundStyle(DeckTheme.muted) }
                            answerField(item, locked: locked)
                            VStack(alignment: .leading, spacing: 6) {
                                AddContextRow(ref: item.id, small: true) {
                                    ForEach(standard, id: \.offset) { offset, option in
                                        if isDrop(option) {
                                            Button(option.label) { startDrop(item, option: option, offset: offset) }
                                                .buttonStyle(DeckButtonStyle(small: true, danger: true)).disabled(locked).help(option.consequence)
                                        } else {
                                            Button(option.label) { sendDecision(item, option: option, index: offset) }
                                                .buttonStyle(DeckButtonStyle(small: true)).disabled(locked).help(option.consequence)
                                        }
                                    }
                                }.environmentObject(store)
                            }
                            ForEach(item.links, id: \.self) { Link($0.absoluteString, destination: $0).font(.system(size: 10)).pointerCursor() }
                            CardHistory(target: item.id, labels: Dictionary(item.options.compactMap { o in o.actionId.map { ($0, o.label) } }, uniquingKeysWith: { a, _ in a })).environmentObject(store)
                        }
                    }
                }
                .onAppear { KeyRouter.shared.start(owner: "decisions") { key, typing in keyPress = KeyEvent(key: key, typing: typing) } }
                .onDisappear { KeyRouter.shared.stop(owner: "decisions") }
                .onChange(of: keyPress) { _, event in
                    guard let event, let command = DecisionKeys.command(event.key, optionCount: specific.count, typing: event.typing) else { return }
                    switch command {
                    case .previous: index = max(0, position - 1)
                    case .next: index = min(items.count - 1, position + 1)
                    case .selectUp, .selectDown:
                        let current = recommendedOffset.flatMap { r in specific.firstIndex { $0.offset == r } }
                        selection[item.id] = DecisionKeys.moved(selected: selection[item.id], recommended: current, by: command == .selectUp ? -1 : 1, count: specific.count)
                    case .confirm:
                        let current = selection[item.id] ?? recommendedOffset.flatMap { r in specific.firstIndex { $0.offset == r } } ?? 0
                        guard !locked, !dropPending.contains(item.id), !dropSent.contains(item.id), specific.indices.contains(current) else { return }
                        sendDecision(item, option: specific[current].element, index: specific[current].offset)
                    case .pick(let letterIndex):
                        guard !locked, !dropPending.contains(item.id), !dropSent.contains(item.id), specific.indices.contains(letterIndex) else { return }
                        sendDecision(item, option: specific[letterIndex].element, index: specific[letterIndex].offset)
                    }
                }
            }
        }
    }

    /// Feed decisions that are not dropped; a Drop whose undo window is over has already written its queued line.
    private var openDecisions: [CompanionFeed.Decision] {
        OpenDecisions.filter(store.companionFeed?.decisions ?? [], ledger: store.commandLedger).filter { !dropSent.contains($0.id) }
    }

    /// MRs the feed marks merged or closed are not cards; one line says how many were left out.
    @ViewBuilder private func finishedNote(_ feed: CompanionFeed?) -> some View {
        let gone = CompanionBoard.finishedMRs(feed: feed)
        if !gone.isEmpty {
            Text(L("\(gone.count) MR già unite o chiuse non sono mostrate: \(gone.map(\.ref).joined(separator: ", "))")).font(.system(size: 10)).foregroundStyle(DeckTheme.muted)
        }
    }

    private func isDrop(_ option: CompanionFeed.Option) -> Bool { option.actionId?.hasSuffix(".opt-drop") == true }

    private func decisionHeader(_ item: CompanionFeed.Decision, position: Int, count: Int) -> some View {
        HStack {
            Text(L("Decisione \(position + 1) di \(count)")).font(.system(size: 10, design: .monospaced)).foregroundStyle(DeckTheme.muted)
            if let age = ageLabel(item) { Text(age.text).font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(age.color) }
            switch item.level {
            case .urgent: StatusPill(text: "Urgente", color: .red)
            case .high: StatusPill(text: "Alta", color: DeckTheme.amber)
            case .normal: EmptyView()
            }
            Spacer()
            Picker(L("Ordine"), selection: $decisionOrder) {
                Text(L("Ordine del feed")).tag(DecisionOrder.feed.rawValue)
                Text(L("Più vecchie prima")).tag(DecisionOrder.oldestFirst.rawValue)
            }.labelsHidden().pickerStyle(.menu).frame(width: 170).onChange(of: decisionOrder) { _, _ in index = 0 }
            Button { index = position - 1 } label: { Image(systemName: "chevron.left") }.disabled(position == 0)
            Button { index = position + 1 } label: { Image(systemName: "chevron.right") }.disabled(position >= count - 1)
        }.buttonStyle(DeckButtonStyle())
    }

    /// Title, headed summary (or `why_now` when the feed has none) and the collapsed full record.
    private func decisionText(_ item: CompanionFeed.Decision) -> some View {
        let parts = item.displayParts
        let open = openContext.contains(item.id)
        return VStack(alignment: .leading, spacing: 14) {
            Text(item.displayTitle).font(.system(size: 18, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            if !item.project.isEmpty { Text(item.project).font(.system(size: 11)).foregroundStyle(DeckTheme.muted) }
            if parts.isEmpty {
                if !item.whyNow.isEmpty { Text(item.whyNow).font(.system(size: 15)).lineSpacing(10).fixedSize(horizontal: false, vertical: true) }
            } else {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                    VStack(alignment: .leading, spacing: 4) {
                        if let heading = CompanionFeed.text(part.heading) { Text(heading.uppercased()).font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(1).foregroundStyle(DeckTheme.mint) }
                        Text(part.text).font(.system(size: 15)).lineSpacing(10).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            HStack(spacing: 10) {
                Button(L(open ? "Nascondi contesto completo" : "Mostra contesto completo")) {
                    if open { openContext.remove(item.id) } else { openContext.insert(item.id) }
                }.buttonStyle(DeckButtonStyle(small: true))
                if let created = item.created {
                    let formatter = DateFormatter()
                    let _ = { formatter.locale = DeckLanguage.current.locale; formatter.setLocalizedDateFormatFromTemplate("d MMM") }()
                    Text(L("in attesa dal \(formatter.string(from: created))")).font(.system(size: 10, design: .monospaced)).foregroundStyle(DeckTheme.muted)
                }
            }
            if open {
                let paragraphs = item.contextText.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in Text(paragraph).font(.system(size: 12)).foregroundStyle(DeckTheme.muted).fixedSize(horizontal: false, vertical: true) }
                }.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    .background(DeckTheme.subtle.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    /// One option as a full-width row: keycap letter, label, consequence under it; the recommended row gets the mint edge.
    private func optionRow(_ item: CompanionFeed.Decision, option: CompanionFeed.Option, offset: Int, letter: String?, recommended: Bool, selected: Bool, locked: Bool) -> some View {
        let key = CompanionAnswer.actionID(decisionID: item.id, option: option, optionIndex: offset) + "|" + item.id
        return VStack(alignment: .leading, spacing: 3) {
            Button { sendDecision(item, option: option, index: offset) } label: {
                HStack(alignment: .top, spacing: 12) {
                    Text(letter ?? "·").font(.system(size: 12, weight: .semibold, design: .monospaced)).frame(width: 26, height: 26)
                        .foregroundStyle(recommended ? DeckTheme.mint : DeckTheme.buttonTextOther)
                        .background(DeckTheme.subtle.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(DeckTheme.subtle.opacity(0.25), lineWidth: 1))
                    VStack(alignment: .leading, spacing: 3) {
                        if recommended {
                            Text(L("RECOMMENDED")).font(.system(size: 9, weight: .bold, design: .monospaced)).tracking(1)
                                .foregroundStyle(DeckTheme.mint).padding(.horizontal, 6).padding(.vertical, 2)
                                .background(DeckTheme.mint.opacity(0.15), in: Capsule())
                        }
                        Text(option.label).font(.system(size: recommended ? 16 : 14, weight: recommended ? .semibold : .medium)).foregroundStyle(DeckTheme.foreground)
                        Text(option.consequence).font(.system(size: 11)).foregroundStyle(DeckTheme.muted)
                    }.multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(recommended ? DeckTheme.mint.opacity(0.10) : DeckTheme.buttonFill, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(recommended ? DeckTheme.mint : DeckTheme.subtle.opacity(0.12), lineWidth: recommended ? 1.5 : 1))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DeckTheme.blue, lineWidth: 2).padding(-4).opacity(selected ? 1 : 0))
                .contentShape(RoundedRectangle(cornerRadius: 8))
            }.buttonStyle(.plain).disabled(locked).pointerCursor()
        }
    }

    private func keyHint(count: Int) -> String? {
        guard count > 0 else { return nil }
        let lettered = min(count, DecisionKeys.maxLettered)
        let first = DecisionKeys.letter(0), last = DecisionKeys.letter(lettered - 1)
        let letters = lettered == 1 ? first : lettered == 2 ? "\(first)/\(last)" : "\(first)–\(last)"
        return L("\(letters) oppure ↑ ↓ e Invio per scegliere · ← → per passare da una decisione all’altra")
    }

    /// The card after Drop: Undo works until the click goes out a few seconds later.
    private func droppedRow(_ item: CompanionFeed.Decision, standard: [(offset: Int, element: CompanionFeed.Option)]) -> some View {
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text(L("Scartata")).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color(red: 1, green: 0.6, blue: 0.6))
                Text(item.title).font(.system(size: 12)).foregroundStyle(DeckTheme.muted).lineLimit(2)
                Spacer()
                if dropPending.contains(item.id) { Button(L("Annulla")) { undoDrop(item.id) }.buttonStyle(DeckButtonStyle(small: true)) }
            }
        }
    }

    private func startDrop(_ item: CompanionFeed.Decision, option: CompanionFeed.Option, offset: Int) {
        dropPending.insert(item.id)
        dropTasks[item.id] = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled, dropPending.contains(item.id) else { return }
            dropPending.remove(item.id); dropSent.insert(item.id); dropTasks[item.id] = nil
            sendDecision(item, option: option, index: offset)
        }
    }
    private func undoDrop(_ id: String) {
        dropTasks[id]?.cancel(); dropTasks[id] = nil; dropPending.remove(id)
    }

    private func answerField(_ item: CompanionFeed.Decision, locked: Bool) -> some View {
        let binding = Binding(get: { answers[item.id] ?? "" }, set: { answers[item.id] = $0 })
        let empty = binding.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(alignment: .leading, spacing: 6) {
            Text(L("Qualcos’altro, o aggiungi contesto")).font(.system(size: 11, weight: .semibold))
            TextEditor(text: binding).font(.system(size: 12)).frame(minHeight: 60).scrollContentBackground(.hidden)
                .padding(6).background(DeckTheme.subtle.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Button(L("Invia")) { sendDecision(item, option: nil, index: 0) }.buttonStyle(DeckButtonStyle(primary: true)).disabled(locked || empty)
            }
            Text(L("Invia manda solo il testo. Un pulsante opzione lo manda insieme a quell’opzione.")).font(.system(size: 10)).foregroundStyle(DeckTheme.muted)
        }
    }

    private func sendDecision(_ item: CompanionFeed.Decision, option: CompanionFeed.Option?, index: Int) {
        guard let click = CompanionAnswer.click(decisionID: item.id, option: option, optionIndex: index, text: answers[item.id] ?? "") else { return }
        feedback = store.sendCompanionClick(actionID: click.actionID, target: click.target, draftText: click.draftText, label: option?.label ?? L("Risposta libera"))
        if feedback == nil { answers[item.id] = "" }
    }

    private func mrs(_ items: [BoardMR], locked: Bool) -> some View {
        let position = Pager.move(mrIndex, by: 0, count: items.count, wrap: false)
        return VStack(spacing: 12) {
            if items.isEmpty { empty("Nessuna MR in attesa.") }
            else {
                let mr = items[position]
                let posted = mr.postActionID.flatMap { store.commandLedger.latest(target: mr.ref, actionID: $0) }?.state == .done
                let perDraft = ReviewDrafts.isPerDraft(mr.drafts, actions: mr.actions)
                let reviewDrafts = perDraft ? ReviewDrafts.remaining(mr.drafts, target: mr.ref, actions: mr.actions, ledger: store.commandLedger, discarded: discardedReview) : []
                let drafts = perDraft ? [] : (posted ? [] : mr.drafts.filter { !discarded.contains(mr.ref + "|" + $0.id) })
                let draftPos = Pager.move(draftIndex[mr.ref] ?? 0, by: 0, count: drafts.count, wrap: false)
                DeckCard {
                    VStack(alignment: .leading, spacing: 10) {
                        mrHeader(mr, position: position, count: items.count)
                        Button { open(mr.ref) } label: { Text(mr.title).font(.system(size: 14, weight: .semibold)).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true) }
                            .buttonStyle(.plain).help(L("Apri i dettagli"))
                        Text(L("pipeline \(unknown(mr.pipeline)) · \(unknown(mr.openThreads)) thread aperti")).font(.system(size: 11)).foregroundStyle(DeckTheme.muted)
                        CardStatusLine(target: mr.ref).environmentObject(store)
                        mrContext(mr)
                        if !reviewDrafts.isEmpty { reviewDraftsPanel(mr, drafts: reviewDrafts, locked: locked) }
                        if !drafts.isEmpty { draftPanel(mr, drafts: drafts, position: draftPos, locked: locked) }
                        actions(ReviewDrafts.buttons(mr.actions), target: mr.ref, locked: locked, recommended: recommended(for: mr), draft: drafts.indices.contains(draftPos) ? (draftTexts[mr.ref + "|" + drafts[draftPos].id] ?? drafts[draftPos].text) : nil, postID: mr.postActionID)
                        AddContextRow(ref: mr.ref).environmentObject(store)
                        if detailsOpen.contains(mr.ref) || CommandLine.arguments.contains("--details-open") { mrDetailsBox(mr) }
                    }
                }
                .onAppear { KeyRouter.shared.start(owner: "mrs", swallow: { $0 == .left || $0 == .right }) { key, typing in keyPress = KeyEvent(key: key, typing: typing) } }
                .onDisappear { KeyRouter.shared.stop(owner: "mrs") }
                .onChange(of: keyPress) { _, event in
                    guard let event, let command = DecisionKeys.command(event.key, optionCount: 0, typing: event.typing) else { return }
                    if command == .previous { mrIndex = Pager.move(position, by: -1, count: items.count, wrap: true) }
                    if command == .next { mrIndex = Pager.move(position, by: 1, count: items.count, wrap: true) }
                }
            }
        }
    }

    /// MRs the user approved at the current head with nothing waiting on them: collapsed, one line each.
    @ViewBuilder private func waitingGroup(_ items: [BoardMR]) -> some View {
        if !items.isEmpty {
            DisclosureGroup(isExpanded: $waitingOpen) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(items) { mr in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Link(mr.ref, destination: mr.url).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(DeckTheme.blue).underline().buttonStyle(.plain).pointerCursor()
                            Text(mr.title).font(.system(size: 12)).lineLimit(1)
                            Spacer()
                            approvalBadge(mr.feedRow?.approval)
                            Text(L("in attesa di \(mr.waitingOn ?? "") per il merge")).font(.system(size: 11)).foregroundStyle(DeckTheme.muted)
                            Button(L("Dettagli")) { open(mr.ref) }.buttonStyle(DeckButtonStyle(small: true))
                        }
                    }
                }.padding(.top, 8)
            } label: {
                Text(L("In attesa di altri (\(items.count))")).font(.system(size: 12, weight: .semibold)).foregroundStyle(DeckTheme.muted)
            }
            .padding(12).background(DeckTheme.subtle.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    /// "Approved by you" or "Approved by omar.pp, kmang"; nothing when nobody approved.
    @ViewBuilder private func approvalBadge(_ approval: CompanionFeed.Approval?) -> some View {
        if let badge = approval?.badge {
            let others = badge.others.joined(separator: ", ")
            Text(badge.byMe ? (others.isEmpty ? L("Approvata da te") : L("Approvata da te e \(others)")) : L("Approvata da \(others)")).font(.system(size: 10, weight: .semibold)).padding(.horizontal, 7).padding(.vertical, 2)
                .foregroundStyle(DeckTheme.mint).background(DeckTheme.mint.opacity(0.15), in: Capsule())
                
        }
    }

    /// "MR n of N", verdict, clickable MR ref and ticket id, author, details and Previous/Next.
    private func mrHeader(_ mr: BoardMR, position: Int, count: Int) -> some View {
        let ticketText = CompanionFeed.text(mr.feedRow?.ticket) ?? store.boardTickets.first { $0.linkedMrs.contains(mr.ref) }?.identifier
        let ticketID = MRTicket.identifier(in: ticketText)
        let ticketURL = ticketID.flatMap { MRTicket.url(identifier: $0, feedURL: mr.feedRow?.ticketUrl, tickets: store.boardTickets) }
        return HStack(spacing: 8) {
            Text(L("MR \(position + 1) di \(count)")).font(.system(size: 10, design: .monospaced)).foregroundStyle(DeckTheme.muted)
            verdictPill(mr.verdict, stale: mr.verdictStale)
            approvalBadge(mr.feedRow?.approval)
            if let step = MROrder.stepLabel(mr.feedRow?.closeStep) {
                Text(D(step)).font(.system(size: 10, weight: .semibold)).padding(.horizontal, 7).padding(.vertical, 2)
                    .foregroundStyle(DeckTheme.buttonTextOther).background(DeckTheme.buttonFill, in: Capsule()).help(L("Passo per chiudere"))
            }
            Link(mr.ref, destination: mr.url).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(DeckTheme.blue).underline().buttonStyle(.plain).pointerCursor().help(mr.url.absoluteString)
            if let ticketID {
                if let ticketURL { Link(ticketID, destination: ticketURL).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(DeckTheme.blue).underline().buttonStyle(.plain).pointerCursor().help(ticketURL.absoluteString) }
                else { Text(ticketID).font(.system(size: 11, design: .monospaced)).foregroundStyle(DeckTheme.muted) }
            }
            Text(D(mr.role == "author" ? "Autore" : "Revisore") + (CompanionFeed.text(mr.feedRow?.author).map { " · " + $0 } ?? "")).font(.system(size: 10)).foregroundStyle(DeckTheme.muted)
            Spacer()
            detailsToggle(mr.ref)
            detailsButton(mr.ref)
            Button { mrIndex = Pager.move(position, by: -1, count: count, wrap: true) } label: { Image(systemName: "chevron.left") }.help(L("MR precedente (←)")).disabled(count < 2)
            Button { mrIndex = Pager.move(position, by: 1, count: count, wrap: true) } label: { Image(systemName: "chevron.right") }.help(L("MR successiva (→)")).disabled(count < 2)
        }.buttonStyle(DeckButtonStyle())
    }

    /// One draft at a time: the comment it answers as a quote, the editable text, Post and Discard, and the draft pager.
    private func draftPanel(_ mr: BoardMR, drafts: [CompanionFeed.Draft], position: Int, locked: Bool) -> some View {
        let draft = drafts[position]
        let draftKey = mr.ref + "|" + draft.id
        let text = Binding(get: { draftTexts[draftKey] ?? draft.text }, set: { draftTexts[draftKey] = $0 })
        return VStack(alignment: .leading, spacing: 8) {
            Text(L("Bozza di risposta").uppercased()).font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(1).foregroundStyle(DeckTheme.mint)
            if let quote = draft.replyTo, let quoted = CompanionFeed.text(quote.text) {
                VStack(alignment: .leading, spacing: 3) {
                    let who = [CompanionFeed.text(quote.author).map { L("\($0) ha scritto") }, CompanionFeed.text(quote.at), CompanionFeed.text(quote.location)].compactMap { $0 }.joined(separator: " · ")
                    if !who.isEmpty { Text(who).font(.system(size: 10)).foregroundStyle(DeckTheme.muted) }
                    Text(quoted).font(.system(size: 12)).foregroundStyle(DeckTheme.buttonTextOther).fixedSize(horizontal: false, vertical: true)
                }.textSelection(.enabled).padding(.vertical, 8).padding(.horizontal, 12).frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .leading) { Rectangle().fill(DeckTheme.subtle.opacity(0.3)).frame(width: 3) }
                    .background(DeckTheme.subtle.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
            }
            TextEditor(text: text).font(.system(size: 12)).frame(minHeight: 90).scrollContentBackground(.hidden)
                .padding(6).background(DeckTheme.subtle.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            HStack(spacing: 8) {
                Button(L("Invia bozza")) { postDraft(mr, text: text.wrappedValue) }
                    .buttonStyle(DeckButtonStyle(primary: mr.postActionID != nil)).disabled(locked || mr.verdictStale || mr.postActionID == nil || !canRun(mr.postActionID ?? "", mr.ref))
                HStack(spacing: 4) {
                    Button(L("‹ Bozza precedente")) { draftIndex[mr.ref] = Pager.move(position, by: -1, count: drafts.count, wrap: false) }
                        .buttonStyle(DeckButtonStyle(small: true)).disabled(!Pager.canMove(position, by: -1, count: drafts.count))
                    Text(L("bozza \(position + 1) di \(drafts.count)")).font(.system(size: 10, design: .monospaced)).foregroundStyle(DeckTheme.muted)
                    Button(L("Bozza successiva ›")) { draftIndex[mr.ref] = Pager.move(position, by: 1, count: drafts.count, wrap: false) }
                        .buttonStyle(DeckButtonStyle(small: true)).disabled(!Pager.canMove(position, by: 1, count: drafts.count))
                }.opacity(drafts.count > 1 ? 1 : 0).allowsHitTesting(drafts.count > 1)
                Button(L("Scarta")) { discarded.insert(draftKey) }.buttonStyle(DeckButtonStyle(small: true, danger: true))
                if mr.postActionID == nil { Text(L("Il feed non ha un'azione di invio per questa MR.")).font(.system(size: 10)).foregroundStyle(DeckTheme.muted) }
            }
        }
    }


    /// Review comments, all in full: where each goes, whether it is required, the exact text, and its own Post, Edit and Discard.
    private func reviewDraftsPanel(_ mr: BoardMR, drafts: [CompanionFeed.Draft], locked: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L("Commenti di review da inviare").uppercased()).font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(1).foregroundStyle(DeckTheme.mint)
                Spacer()
                if drafts.count > 1 {
                    Button(L("Invia tutti")) { postAll(mr, drafts: drafts) }
                        .buttonStyle(DeckButtonStyle(primary: true, small: true)).disabled(locked || mr.verdictStale || cardBusy(mr.ref))
                }
            }
            ForEach(drafts) { draft in reviewDraftBox(mr, draft: draft, locked: locked) }
        }
    }

    private func reviewDraftBox(_ mr: BoardMR, draft: CompanionFeed.Draft, locked: Bool) -> some View {
        let key = mr.ref + "|" + draft.id
        let actionID = ReviewDrafts.actionID(for: draft, in: mr.actions) ?? ""
        let text = Binding(get: { draftTexts[key] ?? draft.text }, set: { draftTexts[key] = $0 })
        let editing = editingDrafts.contains(key)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(CompanionFeed.text(draft.target) ?? L("Nota generale")).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(DeckTheme.foreground).textSelection(.enabled)
                if let severity = ReviewDrafts.label(draft.severity) {
                    Text(D(severity)).font(.system(size: 10, weight: .semibold)).padding(.horizontal, 7).padding(.vertical, 2)
                        .foregroundStyle(draft.severity?.lowercased() == "required" ? DeckTheme.amber : DeckTheme.muted)
                        .background((draft.severity?.lowercased() == "required" ? DeckTheme.amber : DeckTheme.subtle).opacity(0.15), in: Capsule())
                }
                if let finding = CompanionFeed.text(draft.finding) { Text(finding).font(.system(size: 10, design: .monospaced)).foregroundStyle(DeckTheme.muted) }
                Spacer()
            }
            if editing {
                TextEditor(text: text).font(.system(size: 12)).frame(minHeight: 120).scrollContentBackground(.hidden)
                    .padding(6).background(DeckTheme.subtle.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            } else {
                Text(text.wrappedValue).font(.system(size: 12)).foregroundStyle(DeckTheme.buttonTextOther).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8).padding(.horizontal, 12).background(DeckTheme.subtle.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            }
            HStack(spacing: 8) {
                Button(L("Invia commento")) { request(PendingClick(actionID: actionID, target: mr.ref, label: text.wrappedValue, draft: text.wrappedValue), confirmFirst: true) }
                    .buttonStyle(DeckButtonStyle(primary: true, small: true)).disabled(locked || mr.verdictStale || !canRun(actionID, mr.ref))
                Button(L(editing ? "Fine" : "Modifica")) { if editing { editingDrafts.remove(key) } else { editingDrafts.insert(key) } }.buttonStyle(DeckButtonStyle(small: true))
                Button(L("Scarta")) {
                    discardedReview.insert(ReviewDrafts.discardKey(target: mr.ref, draft: draft))
                    UserDefaults.standard.set(Array(discardedReview), forKey: "discardedReviewDrafts")
                }.buttonStyle(DeckButtonStyle(small: true, danger: true))
            }
        }
        .padding(10).overlay(RoundedRectangle(cornerRadius: 8).stroke(DeckTheme.subtle.opacity(0.25), lineWidth: 1))
    }

    /// One confirmation, then one click per draft with its own text.
    private func postAll(_ mr: BoardMR, drafts: [CompanionFeed.Draft]) {
        let clicks = drafts.compactMap { draft in
            ReviewDrafts.actionID(for: draft, in: mr.actions).map { id -> PendingClick in
                let text = draftTexts[mr.ref + "|" + draft.id] ?? draft.text
                return PendingClick(actionID: id, target: mr.ref, label: text, draft: text)
            }
        }
        let summary = L("Inviare tutti i commenti a firstmate?") + "\n\n" + drafts.map { (CompanionFeed.text($0.target) ?? "") + "\n" + (draftTexts[mr.ref + "|" + $0.id] ?? $0.text) }.joined(separator: "\n\n")
        confirm = PendingClick(actionID: "", target: mr.ref, label: summary, batch: clicks)
    }

    private func detailsToggle(_ ref: String) -> some View {
        let open = detailsOpen.contains(ref)
        return Button(L(open ? "Nascondi dettagli" : "Dettagli")) { if open { detailsOpen.remove(ref) } else { detailsOpen.insert(ref) } }
            .buttonStyle(DeckButtonStyle(small: true))
    }
    private func boxRow(_ title: String, _ value: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(D(title)).font(.system(size: 11, weight: .semibold)).foregroundStyle(DeckTheme.muted).frame(width: 110, alignment: .leading)
            Text(value ?? "—").font(.system(size: 12)).foregroundStyle(value == nil ? DeckTheme.muted : DeckTheme.foreground).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
    }
    private func boxHeading(_ title: String) -> some View {
        Text(D(title).uppercased()).font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(1).foregroundStyle(DeckTheme.mint).padding(.top, 4)
    }
    /// The live state of an MR the ticket links: the ticket's own block first, then the feed's MR row.
    private func linkedState(_ linked: CompanionFeed.LinkedMR) -> String? {
        CompanionFeed.text(linked.state) ?? CompanionFeed.text(store.companionFeed?.mrs.first { $0.ref == linked.ref }?.state)
    }
    private func ticketDetailsBox(_ ticket: BoardTicketRow) -> some View {
        let detail = ticket.detail
        return VStack(alignment: .leading, spacing: 8) {
            boxHeading("Linear")
            boxRow("Stato", ticket.status)
            boxRow("Assegnato a", CompanionFeed.text(detail?.assignee))
            boxRow("Priorità", CompanionFeed.text(detail?.priority))
            boxRow("Etichette", (detail?.labels ?? []).isEmpty ? nil : detail?.labels?.joined(separator: ", "))
            if let summary = CompanionFeed.text(detail?.summary) { boxHeading("Riepilogo"); Text(summary).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled) }
            if let items = detail?.acceptance, !items.isEmpty {
                boxHeading("Criteri di accettazione")
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: item.done == true ? "checkmark.square.fill" : "square").font(.system(size: 11)).foregroundStyle(item.done == true ? DeckTheme.mint : DeckTheme.muted)
                        Text(item.text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            let linked = detail?.mrs ?? ticket.linkedMrs.map { CompanionFeed.LinkedMR(ref: $0, url: nil, state: nil) }
            if !linked.isEmpty {
                boxHeading("MR collegate")
                ForEach(Array(linked.enumerated()), id: \.offset) { _, mr in
                    HStack(spacing: 8) {
                        if let url = mr.url.flatMap({ URL(string: $0) }) { Link(mr.ref, destination: url).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(DeckTheme.blue).underline().buttonStyle(.plain).pointerCursor() }
                        else { Text(mr.ref).font(.system(size: 11, design: .monospaced)) }
                        Text(linkedState(mr).map { D($0 == "opened" ? "aperta" : $0 == "merged" ? "unita" : $0 == "closed" ? "chiusa" : $0) } ?? L("stato non nel feed")).font(.system(size: 11)).foregroundStyle(DeckTheme.muted)
                    }
                }
            }
            if let comments = detail?.comments, !comments.isEmpty {
                boxHeading("Ultimi commenti")
                ForEach(Array(comments.prefix(5).enumerated()), id: \.offset) { _, comment in
                    VStack(alignment: .leading, spacing: 2) {
                        Text([CompanionFeed.text(comment.author), CompanionFeed.text(comment.at)].compactMap { $0 }.joined(separator: " · ")).font(.system(size: 10)).foregroundStyle(DeckTheme.muted)
                        Text(String(comment.text.prefix(300))).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                }
            }
            boxHeading("Cosa manca")
            boxRow("Passo", CompanionFeed.text(ticket.finish?.step))
            boxRow("Spetta a", CompanionFeed.text(ticket.finish?.owner))
            if detail == nil || !(detail?.missing.isEmpty ?? true) {
                Text(L("Non ancora nel feed: \((detail?.missing ?? ["detail"]).joined(separator: ", "))")).font(.system(size: 10)).foregroundStyle(DeckTheme.amber)
            }
            boxHeading("Storico")
            CardHistory(target: ticket.identifier, labels: Dictionary(ticket.actions.map { ($0.id, $0.label) }, uniquingKeysWith: { a, _ in a }), alwaysOpen: true).environmentObject(store)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(12).background(DeckTheme.subtle.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }
    private func mrDetailsBox(_ mr: BoardMR) -> some View {
        let row = mr.feedRow
        let ticketText = CompanionFeed.text(row?.ticket) ?? store.boardTickets.first { $0.linkedMrs.contains(mr.ref) }?.identifier
        return VStack(alignment: .leading, spacing: 8) {
            boxHeading("GitLab")
            boxRow("Stato", CompanionFeed.text(row?.state))
            boxRow("Ruolo", D(mr.role == "author" ? "Autore" : "Revisore"))
            boxRow("Autore", CompanionFeed.text(row?.author))
            boxRow("Pipeline", mr.pipeline)
            boxRow("Thread aperti", mr.openThreads.map(String.init))
            boxRow("Ticket", ticketText)
            boxHeading("Cosa manca")
            boxRow("Blocco", CompanionFeed.text(row?.blocker) ?? CompanionFeed.text(mr.label))
            boxRow("Passo", CompanionFeed.text(row?.next))
            boxRow("Spetta a", CompanionFeed.text(mr.nextOwner))
            boxRow("Ultima attività", (mr.updatedAt ?? CompanionFeed.date(row?.updatedAt)).map { $0.formatted(.relative(presentation: .named)) })
            boxHeading("Storico")
            CardHistory(target: mr.ref, labels: Dictionary(mr.actions.map { ($0.id, $0.label) }, uniquingKeysWith: { a, _ in a }), alwaysOpen: true).environmentObject(store)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(12).background(DeckTheme.subtle.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
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
                            detailsToggle(ticket.identifier)
                            detailsButton(ticket.identifier)
                        }
                        Button { open(ticket.identifier) } label: { Text(ticket.title).font(.system(size: 14, weight: .semibold)).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true) }
                            .buttonStyle(.plain).help(L("Apri i dettagli"))
                        if let finish = ticket.finish {
                            Text(L("Per chiudere: \(finish.step) · \(finish.owner)")).font(.system(size: 11)).foregroundStyle(DeckTheme.muted)
                        }
                        if !ticket.linkedMrs.isEmpty { Text(ticket.linkedMrs.joined(separator: " · ")).font(.system(size: 10, design: .monospaced)).foregroundStyle(DeckTheme.muted) }
                        actions(ticket.actions, target: ticket.identifier, locked: locked || ticket.finishStale, recommended: CompanionRecommendation.actionID(in: ticket.actions, texts: [ticket.finish?.step, ticket.status] + decisionTexts(ticket.decisionId)))
                        AddContextRow(ref: ticket.identifier).environmentObject(store)
                        CardStatusLine(target: ticket.identifier).environmentObject(store)
                        if detailsOpen.contains(ticket.identifier) || CommandLine.arguments.contains("--details-open") { ticketDetailsBox(ticket) }
                    }
                }
            }
        }
    }

    /// Role, blocker, next action, ticket, last activity and the top gotcha or open decision, from the feed and the dossier.
    @ViewBuilder private func mrContext(_ mr: BoardMR) -> some View {
        let dossier: Dossier? = { if case .loaded(let value) = store.dossier(for: mr.ref) { return value }; return nil }()
        let row = mr.feedRow
        let last = [mr.updatedAt, CompanionFeed.date(row?.updatedAt), dossier?.timeline.last?.at.flatMap { CompanionFeed.date($0) }].compactMap { $0 }.max()
        let blocker = CompanionFeed.text(row?.blocker) ?? CompanionFeed.text(mr.label)
        let next = CompanionFeed.text(row?.next) ?? CompanionFeed.text(dossier?.nextAction)
        VStack(alignment: .leading, spacing: 4) {
            if let headline = CompanionFeed.text(row?.headline) { Text(headline).font(.system(size: 12, weight: .medium)).fixedSize(horizontal: false, vertical: true) }
            if blocker != nil || !mr.nextOwner.isEmpty { contextLine("hourglass", L("Blocco: \(blocker ?? "—") · su \(mr.nextOwner.isEmpty ? "—" : mr.nextOwner)")) }
            if let next { contextLine("arrow.right.circle", L("Prossima azione: \(next)")) }
            if let last { contextLine("clock", L("Ultima attività \(last.formatted(.relative(presentation: .named)))")) }
            if let gotcha = dossier?.gotchas.first { contextLine("exclamationmark.triangle", gotcha, color: DeckTheme.amber) }
            if let decision = dossier?.openDecisions.first { contextLine("questionmark.circle", decision) }
        }
    }
    private func contextLine(_ symbol: String, _ text: String, color: Color = DeckTheme.muted) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol).font(.system(size: 10)).foregroundStyle(color).frame(width: 14)
            Text(text).font(.system(size: 11)).foregroundStyle(color).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
    }

    @ViewBuilder private func verdictPill(_ verdict: String?, stale: Bool) -> some View {
        if let verdict { StatusPill(text: verdictTitle(verdict), color: verdictColor(verdict)) } else { StatusPill(text: "Nessun verdetto", color: DeckTheme.muted) }
        if stale { StatusPill(text: "Verdetto superato", color: DeckTheme.amber) }
    }

    private func unknown<T>(_ value: T?) -> String { value.map { String(describing: $0) } ?? D("n/d") }
    /// The only way into the detail pane besides the title: buttons on the card never open it.
    private func detailsButton(_ ref: String) -> some View {
        Button { open(ref) } label: { Image(systemName: "chevron.right").foregroundStyle(DeckTheme.muted).padding(4) }.buttonStyle(.plain).help(L("Apri i dettagli"))
    }
    private func open(_ ref: String) { selected = ref; contextText = ""; feedback = nil }

    private func detail(_ row: Row) -> some View {
        let ref: String, title: String, url: URL
        switch row {
        case .mr(let mr): ref = mr.ref; title = mr.title; url = mr.url
        case .ticket(let ticket): ref = ticket.identifier; title = ticket.title; url = ticket.url
        }
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button { selected = nil } label: { Label(L("Indietro"), systemImage: "chevron.left") }.buttonStyle(DeckButtonStyle())
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
            DeckCard { AddContextRow(ref: ref, expanded: true).environmentObject(store) }
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

    private func actions(_ list: [CompanionFeed.Action], target: String, locked: Bool, recommended: String? = nil, draft: String? = nil, postID: String? = nil) -> some View {
        HStack(spacing: 10) {
            ForEach(CompanionRecommendation.ordered(list, recommended: recommended)) { action in
                let isPost = action.id == postID && draft != nil
                Button(action.label) {
                    if isPost { postClickRequest(action, target: target, text: draft ?? "") }
                    else { request(PendingClick(actionID: action.id, target: target, label: action.label), confirmFirst: action.outward) }
                }.buttonStyle(DeckButtonStyle(primary: action.id == recommended)).disabled(locked || !canRun(action.id, target))
            }
        }
    }

    /// Recommendation texts for a row: its own wording plus the linked decision's recommendation.
    private func decisionTexts(_ id: String?) -> [String?] {
        guard let id, let decision = store.companionFeed?.decisions.first(where: { $0.id == id }) else { return [] }
        return [decision.recommendation]
    }
    private func recommended(for mr: BoardMR) -> String? {
        CompanionRecommendation.actionID(in: mr.actions, texts: [mr.label, mr.feedRow?.next, mr.feedRow?.blocker, mr.feedRow?.headline] + decisionTexts(mr.feedRow?.decisionId))
    }
    private func postClickRequest(_ action: CompanionFeed.Action, target: String, text: String) {
        request(PendingClick(actionID: action.id, target: target, label: text, draft: text), confirmFirst: true)
    }
    private func postDraft(_ mr: BoardMR, text: String) {
        guard let row = mr.feedRow, let click = CompanionAnswer.postClick(mr: row, text: text) else { return }
        request(PendingClick(actionID: click.actionID, target: click.target, label: text, draft: text), confirmFirst: true)
    }
    /// False while another action of this card is sent or running; "Wait, what?" and Add context stay possible.
    private func canRun(_ actionID: String, _ target: String) -> Bool { CardActivity.canRun(actionID: actionID, target: target, ledger: store.commandLedger) }
    private func cardBusy(_ target: String) -> Bool { CardActivity.inFlight(target: target, ledger: store.commandLedger) != nil }
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
        feedback = store.sendCompanionClick(actionID: click.actionID, target: click.target, draftText: click.draft, label: click.draft == nil ? click.label : nil)
    }
}

/// "Add context" on a card: a button that opens a text box with Send and Cancel, like the Lavish board.
struct AddContextRow<Trailing: View>: View {
    @EnvironmentObject var store: DeckStore
    let ref: String
    var expanded = false
    var small = false
    let trailing: Trailing
    init(ref: String, expanded: Bool = false, small: Bool = false, @ViewBuilder trailing: () -> Trailing) {
        self.ref = ref; self.expanded = expanded; self.small = small; self.trailing = trailing()
    }
    @State private var open = false
    @State private var text = ""
    @State private var feedback: String?
    private var key: String { ref + ".add-context|" + ref }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if open || expanded {
                TextEditor(text: $text).font(.system(size: 12)).frame(minHeight: 60).scrollContentBackground(.hidden)
                    .padding(6).background(DeckTheme.subtle.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                HStack {
                    Button(L("Invia")) {
                        guard let click = CompanionAnswer.contextClick(ref: ref, text: text) else { return }
                        feedback = store.sendCompanionClick(actionID: click.actionID, target: click.target, draftText: click.draftText, label: L("Aggiungi contesto"))
                        if feedback == nil { text = ""; open = false }
                    }.buttonStyle(DeckButtonStyle(primary: true)).disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if !expanded { Button(L("Annulla")) { text = ""; open = false }.buttonStyle(DeckButtonStyle()) }
                }
            } else {
                HStack(spacing: 8) {
                    Button(L("Aggiungi contesto")) { open = true }.buttonStyle(DeckButtonStyle(small: small))
                    trailing
                }
            }
            if let feedback { Text(D(feedback)).font(.system(size: 10)).foregroundStyle(DeckTheme.amber) }
        }
    }
}

extension AddContextRow where Trailing == EmptyView {
    init(ref: String, expanded: Bool = false) { self.init(ref: ref, expanded: expanded, small: false) { EmptyView() } }
}

/// One status line for the card: its newest command in plain words (Sent, Firstmate is on it, Done, Failed: reason).
struct CardStatusLine: View {
    @EnvironmentObject var store: DeckStore
    let target: String
    var body: some View {
        let inFlight = CardActivity.inFlight(target: target, ledger: store.commandLedger)
        if let command = inFlight ?? store.commandLedger.latest(target: target) {
            let color = CardStyle.color(command.state)
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(CardStyle.title(command)).font(.system(size: 12, weight: .semibold)).foregroundStyle(color)
                Text(CardActivity.plainLabel(command)).font(.system(size: 12)).foregroundStyle(DeckTheme.muted).lineLimit(1)
                if inFlight != nil {
                    Text(L("Le altre azioni di questa scheda aspettano.")).font(.system(size: 11)).foregroundStyle(DeckTheme.muted)
                }
            }.padding(.horizontal, 10).padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading)
                .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

enum CardStyle {
    /// Localized plain status of a command; the failure reason follows "Failed".
    static func title(_ command: Command) -> String {
        switch command.state {
        case .queued: D("Inviato")
        case .pickedUp: D("Firstmate se ne sta occupando")
        case .done: D("Fatto")
        case .failed: command.note.map { D("Fallito") + ": " + String($0.prefix(160)) } ?? D("Fallito")
        }
    }
    static func color(_ state: CommandState) -> Color {
        switch state { case .queued: DeckTheme.muted; case .pickedUp: DeckTheme.blue; case .done: DeckTheme.mint; case .failed: .red }
    }
}

/// The card's own commands, newest first, collapsed by default.
struct CardHistory: View {
    @EnvironmentObject var store: DeckStore
    let target: String
    /// action id to the button text, for commands written without a label
    var labels: [String: String] = [:]
    /// Inside the Details box the list is always shown, without its own toggle.
    var alwaysOpen = false
    @State private var open = CommandLine.arguments.contains("--history-tab")
    var body: some View {
        let rows = CardActivity.history(target: target, ledger: store.commandLedger)
        if alwaysOpen {
            if rows.isEmpty { Text(L("Nessun comando ancora.")).font(.system(size: 11)).foregroundStyle(DeckTheme.muted) }
            historyList(rows)
        } else if !rows.isEmpty {
            DisclosureGroup(isExpanded: $open) {
                historyList(rows).padding(.top, 6)
            } label: {
                Text(L("Cronologia (\(rows.count))")).font(.system(size: 11, weight: .semibold)).foregroundStyle(DeckTheme.muted)
            }
        }
    }
    private func historyList(_ rows: [Command]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(rows) { command in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Circle().fill(CardStyle.color(command.state)).frame(width: 6, height: 6)
                        Text(labels[command.actionID] ?? CardActivity.plainLabel(command)).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Text(CardStyle.title(command)).font(.system(size: 11)).foregroundStyle(CardStyle.color(command.state))
                    }
                    Text(when(command)).font(.system(size: 10)).foregroundStyle(DeckTheme.muted)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func when(_ command: Command) -> String {
        func stamp(_ date: Date?) -> String? { date.map { $0.formatted(date: .abbreviated, time: .shortened) } }
        let parts = [stamp(command.queuedAt).map { L("inviato \($0)") }, stamp(command.pickedUpAt).map { L("preso in carico \($0)") },
                     stamp(command.finishedAt).map { (command.state == .failed ? L("fallito \($0)") : L("fatto \($0)")) }].compactMap { $0 }
        return parts.joined(separator: " · ")
    }
}
