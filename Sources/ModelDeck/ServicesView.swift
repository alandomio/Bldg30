import SwiftUI
import ModelDeckCore

struct ServicesView: View {
    @EnvironmentObject var store: DeckStore
    @State private var snapshot = PortInspectorSnapshot(ports: [], services: [])
    @State private var query = ""
    @State private var state = "all"
    @State private var busy = false
    @State private var updatedAt: Date?
    private var ports: [ListeningPort] {
        snapshot.ports.filter { query.isEmpty || String($0.port).contains(query) || String($0.pid).contains(query) || $0.process.localizedCaseInsensitiveContains(query) || $0.address.localizedCaseInsensitiveContains(query) }
    }
    private var services: [LaunchService] {
        snapshot.services.filter { (query.isEmpty || $0.label.localizedCaseInsensitiveContains(query) || $0.pid.map { String($0).contains(query) } == true) && (state == "all" || state == "running" && $0.running || state == "idle" && !$0.running || state == "disabled" && $0.disabled == true) }
            .sorted { $0.running != $1.running ? $0.running : $0.id < $1.id }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                TextField(L("Cerca porta, processo o servizio"), text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 350)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button(L("Aggiorna")) { Task { await refresh() } }.disabled(busy)
            }
            ForEach(snapshot.errors, id: \.self) { Text(D($0)).font(.system(size: 11)).foregroundStyle(DeckTheme.amber) }
            DeckCard {
                VStack(alignment: .leading, spacing: 14) {
                    SectionLabel(title: L("PORTE OCCUPATE"), trailing: L("\(ports.count) porte visibili"))
                    Text(L("TCP in ascolto e porte UDP. L’indirizzo indica le interfacce associate; il processo mostra chi possiede la porta. I dati di altri utenti possono essere limitati da macOS."))
                        .font(.system(size: 11)).foregroundStyle(DeckTheme.muted).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Text(L("PORTA")).frame(width: 55, alignment: .leading)
                        Text(L("PROTOCOLLO")).frame(width: 85, alignment: .leading)
                        Text(L("INDIRIZZO")).frame(width: 150, alignment: .leading)
                        Text(L("PROCESSO")).frame(maxWidth: .infinity, alignment: .leading)
                        Text("PID").frame(width: 55, alignment: .trailing)
                    }.font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundStyle(DeckTheme.muted)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(ports) { port in
                                HStack {
                                    Text(String(port.port)).fontWeight(.semibold).foregroundStyle(DeckTheme.blue).frame(width: 55, alignment: .leading)
                                    Text(port.transport + "/" + port.family.replacingOccurrences(of: "IPv", with: "v")).frame(width: 85, alignment: .leading)
                                    Text(port.address).lineLimit(1).help(port.address).frame(width: 150, alignment: .leading)
                                    Text(port.process).lineLimit(1).help(port.process).frame(maxWidth: .infinity, alignment: .leading)
                                    Text(String(port.pid)).frame(width: 55, alignment: .trailing)
                                }.font(.system(size: 11, design: .monospaced)).padding(.vertical, 8).textSelection(.enabled)
                            }
                            if ports.isEmpty { Text(L("Nessuna porta visibile corrispondente.")).font(.system(size: 11)).foregroundStyle(DeckTheme.muted).padding(.vertical, 12) }
                        }
                    }.frame(height: 250)
                }
            }
            DeckCard {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        SectionLabel(title: L("SERVIZI DI MACOS"), trailing: L("\(services.count) servizi"))
                        Picker(L("Stato"), selection: $state) {
                            Text(L("Tutti")).tag("all"); Text(L("In esecuzione")).tag("running"); Text(L("Fermi / in attesa")).tag("idle"); Text(L("Disabilitati")).tag("disabled")
                        }.labelsHidden().frame(width: 160)
                    }
                    Text(L("Un servizio in attesa è caricato e può partire quando serve. Disabilitato indica una configurazione esplicita di launchd; non caricato indica che non è presente nell’elenco dei servizi caricati. La lettura non modifica i servizi."))
                        .font(.system(size: 11)).foregroundStyle(DeckTheme.muted).fixedSize(horizontal: false, vertical: true)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(services) { service in
                                HStack(spacing: 12) {
                                    Circle().fill(service.running ? DeckTheme.mint : service.disabled == true ? DeckTheme.muted : DeckTheme.blue).frame(width: 5, height: 5)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(service.label).font(.system(size: 11, design: .monospaced)).lineLimit(1).help(service.label)
                                        Text(D(service.domain == "system" ? "Sistema" : "Utente")).font(.system(size: 9)).foregroundStyle(DeckTheme.muted)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                    Text(D(service.status)).font(.system(size: 10)).foregroundStyle(DeckTheme.muted)
                                    Text(service.pid.map(String.init) ?? "—").font(.system(size: 11, design: .monospaced)).frame(width: 55, alignment: .trailing)
                                }.padding(.vertical, 8).textSelection(.enabled)
                            }
                            if services.isEmpty { Text(L("Nessun servizio visibile corrispondente.")).font(.system(size: 11)).foregroundStyle(DeckTheme.muted).padding(.vertical, 12) }
                        }
                    }.frame(height: 300)
                }
            }
            HStack {
                Text(L("Aggiornamento ogni 5 secondi, solo mentre questa pagina è aperta.")).font(.system(size: 10)).foregroundStyle(DeckTheme.muted)
                Spacer()
                if let updatedAt { Text(updatedAt, style: .time).font(.system(size: 10)).foregroundStyle(DeckTheme.muted) }
            }
        }.task {
            while !Task.isCancelled { await refresh(); try? await Task.sleep(for: .seconds(5)) }
        }
    }
    private func refresh() async {
        guard !busy else { return }; busy = true
        defer { busy = false }
        if store.demo {
            snapshot = PortInspectorSnapshot(ports: PortInspector.parsePorts("p101\ncLocal Inference\nu501\nf1\ntIPv4\nPTCP\nn127.0.0.1:1234\np102\ncWeb Server\nu501\nf1\ntIPv6\nPTCP\nn*:8080\n"), services: PortInspector.parseServices("services = {\n101 - demo.inference\n0 0 demo.on-demand\n}\ndisabled services = {\n\"demo.disabled\" => disabled\n}\n", domain: "gui/501"))
        } else {
            let current = await PortInspector.read(); guard !Task.isCancelled else { return }; snapshot = current
        }
        updatedAt = Date()
    }
}
