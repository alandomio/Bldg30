import SwiftUI
import ModelDeckCore

struct ClaudeRefreshView: View {
    @EnvironmentObject var store: DeckStore
    @Environment(\.dismiss) private var dismiss
    @State private var installed = ClaudeBridge.isInstalled()
    @State private var feedback: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(L("Aggiornare le quote di Claude Code")).font(.system(size: 21, weight: .semibold))
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help(L("Chiudi"))
            }
            Text(L("ShipDeck riceve le quote dalle sessioni di Claude Code nel terminale. Le nuove percentuali arrivano dopo una risposta, se il piano e la versione di Claude Code le rendono disponibili."))
                .font(.system(size: 12)).foregroundStyle(DeckTheme.muted).fixedSize(horizontal: false, vertical: true)
            step("1", "Verifica il collegamento", installed ? "Claude Code è collegato a ShipDeck." : "Collega Claude Code per consentire l’arrivo dei dati delle quote.")
            if !installed {
                Button(L("Collega Claude Code")) {
                    do {
                        guard let executable = Bundle.main.executableURL else { return }
                        try ClaudeBridge.install(executable: executable); installed = ClaudeBridge.isInstalled()
                        feedback = "Collegato. Riapri la sessione Claude Code e attendi una risposta."
                    } catch { feedback = error.localizedDescription }
                }.buttonStyle(.bordered).disabled(store.demo)
            }
            step("2", "Usa Claude Code", "Apri o riprendi una sessione nel terminale. Se hai appena collegato ShipDeck, riapri la sessione. Invia una richiesta e attendi la risposta.")
            step("3", "Torna in ShipDeck", "Le quote vengono lette automaticamente. Puoi anche premere Rileggi dati: controlla i dati già ricevuti, senza avviare richieste a Claude.")
            if let date = store.claude.updatedAt {
                HStack { Text(L("Ultimi dati ricevuti:")); Text(date, style: .date); Text(date, style: .time) }
                    .font(.system(size: 11)).foregroundStyle(DeckTheme.muted)
            } else { Text(L("Nessun dato ricevuto finora.")).font(.system(size: 11)).foregroundStyle(DeckTheme.amber) }
            if let feedback { Text(D(feedback)).font(.system(size: 11)).foregroundStyle(DeckTheme.amber).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Link(L("Guida Claude Code"), destination: URL(string: "https://code.claude.com/docs/en/statusline#rate-limit-usage")!)
                Spacer()
                Button(L("Rileggi dati")) {
                    let previous = store.claude.updatedAt
                    if !store.demo { store.claude = ClaudeUsage.read() }
                    feedback = store.claude.updatedAt == previous ? "Nessun nuovo dato ricevuto. Attendi una risposta in Claude Code; se non cambia, verifica il collegamento e gli eventuali override della status line nel progetto." : "Dati aggiornati da Claude Code."
                }.buttonStyle(.borderedProminent)
            }.font(.system(size: 11))
        }.padding(26).frame(width: 620).background(DeckTheme.background).foregroundStyle(DeckTheme.foreground).tint(DeckTheme.mint)
    }
    private func step(_ number: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number).font(.system(size: 12, weight: .semibold)).frame(width: 24, height: 24).background(DeckTheme.mint.opacity(0.1), in: Circle()).foregroundStyle(DeckTheme.mint)
            VStack(alignment: .leading, spacing: 5) { Text(D(title)).font(.system(size: 12, weight: .semibold)); Text(D(detail)).font(.system(size: 11)).foregroundStyle(DeckTheme.muted).fixedSize(horizontal: false, vertical: true) }
        }
    }
}
