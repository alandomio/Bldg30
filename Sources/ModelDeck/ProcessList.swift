import SwiftUI
import ModelDeckCore

enum ProcessSectionAnchor: Hashable { case resourceSelector, table }

struct ProcessList: View {
    @EnvironmentObject var store: DeckStore
    @Binding var sort: ProcessSort
    var selectGroupAction: () -> Void = {}
    @State private var descending = true
    @State private var query = ""
    @State private var onlyMine = false
    @State private var onlyHighUsage = false
    @State private var focusedGroupID: String?
    @State private var focusedGroupName = ""
    @State private var selection: ProcessIdentity?
    @State private var pending: RunningProcess?
    @State private var force = false
    @State private var error: String?
    private let thresholds = "Consumi elevati: CPU ≥80% di un core · memoria ≥10% della RAM totale · GPU ≥50%."
    private var filtered: [RunningProcess] {
        store.processes.filter { (focusedGroupID == nil || $0.resourceGroupID == focusedGroupID) && (!onlyMine || $0.isMine) && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || String($0.pid).contains(query)) }
    }
    private var highUsageCount: Int {
        filtered.filter { !$0.highUsageResources(totalMemory: store.snapshot.memoryTotal).isEmpty }.count
    }
    private var rows: [RunningProcess] {
        sort.sorted(filtered.filter { !onlyHighUsage || !$0.highUsageResources(totalMemory: store.snapshot.memoryTotal).isEmpty }, descending: descending)
    }
    private var selected: RunningProcess? { store.processes.first { $0.id == selection } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            resourceSelector.id(ProcessSectionAnchor.resourceSelector)
            ProcessResourceOverview(resource: sort, snapshot: store.snapshot, cores: store.machine.cores, processes: store.processes, focusedGroupID: focusedGroupID) { group in
                focusedGroupID = group.id; focusedGroupName = group.name
                descending = true; query = ""; onlyMine = false; onlyHighUsage = false; selection = nil
                selectGroupAction()
            }
            DeckCard {
                VStack(alignment: .leading, spacing: 14) {
                    if focusedGroupID != nil {
                        HStack {
                            Label(L("Processi di \(focusedGroupName)"), systemImage: "app.badge")
                                .font(.system(size: 11, weight: .medium)).foregroundStyle(DeckTheme.mint)
                            Spacer()
                            Button(L("Mostra tutti i processi")) { focusedGroupID = nil }.font(.system(size: 10)).buttonStyle(.bordered)
                        }
                    }
                    HStack {
                        Text(L("PROCESSI · \(sort.rawValue.uppercased())")).font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(DeckTheme.muted)
                        Button { descending.toggle() } label: {
                            Image(systemName: descending ? "arrow.down" : "arrow.up").frame(width: 24, height: 24)
                        }.buttonStyle(.plain)
                            .help(D(descending ? "Dal consumo maggiore al minore. Clicca per invertire." : "Dal consumo minore al maggiore. Clicca per invertire."))
                            .accessibilityLabel(L("Ordine \(descending ? "decrescente" : "crescente") per \(sort.rawValue)"))
                        Spacer()
                        Toggle(L("Solo miei"), isOn: $onlyMine).toggleStyle(.checkbox).font(.system(size: 11))
                        TextField(L("Cerca nome o PID"), text: $query).textFieldStyle(.roundedBorder).frame(width: 180)
                    }.frame(height: 28)
                    Text(D(sort == .gpu ? "GPU: le percentuali compaiono solo con contatori validi. «Client» indica una connessione, non un consumo misurato. I valori non disponibili restano in fondo." : "Clicca CPU, Memoria o GPU per ordinare; clicca di nuovo per invertire. CPU: 100% equivale a un core. Memoria: RAM residente."))
                        .font(.system(size: 10)).foregroundStyle(DeckTheme.muted).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Label(L("\(highUsageCount) \(highUsageCount == 1 ? "processo con consumi elevati" : "processi con consumi elevati")"), systemImage: "exclamationmark.triangle")
                            .foregroundStyle(highUsageCount > 0 ? DeckTheme.amber : DeckTheme.muted)
                        Spacer()
                        Toggle(L("Solo consumi elevati"), isOn: $onlyHighUsage).toggleStyle(.checkbox)
                    }.font(.system(size: 10)).help(D(thresholds))
                    HStack {
                        Text(L("PROCESSO")).frame(maxWidth: .infinity, alignment: .leading)
                        Text(L("PID")).frame(width: 52, alignment: .trailing)
                        sortHeader(.cpu, width: 65)
                        sortHeader(.memory, width: 90)
                        sortHeader(.gpu, width: 85)
                    }.font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundStyle(DeckTheme.muted)
                        .padding(.horizontal, 8)
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(rows) { process in
                                processRow(process)
                            }
                            if rows.isEmpty { Text(D(store.processes.isEmpty ? "Lettura processi…" : "Nessun processo corrispondente")).font(.system(size: 12)).foregroundStyle(DeckTheme.muted).padding(30) }
                        }
                    }.frame(height: 390)
                    Text(L("\(rows.count) processi · aggiornamento ogni 3 secondi")).font(.system(size: 10)).foregroundStyle(DeckTheme.muted)
                    Text(D(thresholds)).font(.system(size: 9)).foregroundStyle(DeckTheme.muted).fixedSize(horizontal: false, vertical: true)
                }
            }.id(ProcessSectionAnchor.table)
            if let process = selected {
                DeckCard {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(process.name).font(.system(size: 16, weight: .semibold))
                                Text("PID \(process.pid) · UID \(process.userID) · \(process.threads.map(String.init) ?? "—") thread").font(.system(size: 11)).foregroundStyle(DeckTheme.muted)
                            }
                            Spacer()
                            Menu(L("Arresta…")) {
                                Button(L("Termina (SIGTERM)")) { force = false; pending = process }
                                Button(L("Forza arresto (SIGKILL)"), role: .destructive) { force = true; pending = process }
                            }.disabled(!process.canTerminate || store.demo)
                        }
                        let resources = process.highUsageResources(totalMemory: store.snapshot.memoryTotal)
                        if !resources.isEmpty {
                            Label(L("Consumi elevati: \(resources.map { D($0.rawValue) }.joined(separator: ", "))"), systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 11, weight: .medium)).foregroundStyle(DeckTheme.amber)
                        }
                        if let memory = process.memory {
                            Text(L("Memoria residente: \(DeckFormat.bytes(memory))") + (process.memoryPercent(totalMemory: store.snapshot.memoryTotal).map { L(" · \(DeckFormat.percent($0)) della RAM totale") } ?? ""))
                                .font(.system(size: 11)).foregroundStyle(DeckTheme.muted)
                        }
                        if let path = process.path { Text(D(path)).font(.system(size: 10, design: .monospaced)).foregroundStyle(DeckTheme.muted).textSelection(.enabled) }
                        if process.gpuClient, process.gpu == nil { Text(L("Client GPU rilevato; macOS non espone una percentuale valida per questo processo.")).font(.system(size: 11)).foregroundStyle(DeckTheme.muted) }
                        if !process.canTerminate { Text(L("Arresto non disponibile per processi protetti, altri utenti o ModelDeck.")).font(.system(size: 11)).foregroundStyle(DeckTheme.muted) }
                    }
                }
            }
            if let error { Text(D(error)).font(.system(size: 12)).foregroundStyle(.red) }
        }.tint(DeckTheme.mint)
            .onChange(of: sort) { _, _ in descending = true; focusedGroupID = nil; selection = nil }
            .confirmationDialog(D(force ? "Forzare l’arresto del processo?" : "Terminare il processo?"), isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible) {
                if let process = pending {
                    Button(L("\(force ? "Forza arresto" : "Termina") \(process.name) (PID \(process.pid))"), role: .destructive) {
                        do { try ProcessMonitor.terminate(process, force: force); error = nil; Task { await store.refreshProcesses() } }
                        catch { self.error = error.localizedDescription }
                        pending = nil
                    }
                }
                Button(L("Annulla"), role: .cancel) { pending = nil }
            } message: { Text(L("Eventuali modifiche non salvate del processo possono andare perse.")) }
            .task {
                if store.demo { selection = store.processes.first?.id }
                while !Task.isCancelled { await store.refreshProcesses(); try? await Task.sleep(for: .seconds(3)) }
            }
    }

    private var resourceSelector: some View {
        HStack(spacing: 12) {
            ForEach(ProcessSort.allCases, id: \.self) { resource in
                let color = resourceColor(resource)
                Button {
                    sort = resource; descending = true; focusedGroupID = nil; selection = nil
                } label: {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label(D(resource == .memory ? "RAM" : resource.rawValue), systemImage: resourceSymbol(resource))
                                .font(.system(size: 11, weight: .medium))
                            Spacer()
                            if sort == resource { Image(systemName: "checkmark.circle.fill").font(.system(size: 12)) }
                        }.foregroundStyle(sort == resource ? color : DeckTheme.muted)
                        Text(D(DeckFormat.percent(resource == .cpu ? store.snapshot.cpu : resource == .gpu ? store.snapshot.gpu : store.snapshot.memorySampleAvailable ? store.snapshot.memoryPercent : nil)))
                            .font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
                    }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                        .background(sort == resource ? color.opacity(0.08) : DeckTheme.card, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(sort == resource ? color.opacity(0.5) : DeckTheme.subtle.opacity(0.065), lineWidth: 1))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).help(L("Mostra dove va \(resource == .memory ? "la RAM" : "la " + resource.rawValue)"))
                    .accessibilityAddTraits(sort == resource ? .isSelected : [])
            }
        }
    }

    private func sortHeader(_ resource: ProcessSort, width: CGFloat) -> some View {
        Button {
            if sort == resource { descending.toggle() }
            else { sort = resource; descending = true }
        } label: {
            HStack(spacing: 3) {
                Text(D(resource.rawValue.uppercased()))
                Image(systemName: sort == resource ? (descending ? "arrow.down" : "arrow.up") : "arrow.up.arrow.down")
                    .font(.system(size: 8)).opacity(sort == resource ? 1 : 0.5)
            }.frame(width: width, alignment: .trailing).contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(sort == resource ? DeckTheme.mint : DeckTheme.muted)
            .help(L("Ordina per \(resource.rawValue); clicca di nuovo per invertire"))
            .accessibilityLabel(L("\(resource.rawValue)\(sort == resource ? (descending ? ", ordine decrescente" : ", ordine crescente") : ", ordina dal consumo maggiore")"))
    }

    private func processRow(_ process: RunningProcess) -> some View {
        let resources = process.highUsageResources(totalMemory: store.snapshot.memoryTotal)
        return Button { selection = process.id } label: {
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: resources.isEmpty ? (process.gpuClient ? "square.3.layers.3d" : "app") : "exclamationmark.triangle.fill")
                        .foregroundStyle(resources.isEmpty ? (process.gpuClient ? DeckTheme.purple : DeckTheme.muted) : DeckTheme.amber)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(process.name).lineLimit(1).help(D(process.name))
                        if !resources.isEmpty {
                            Text(L("Consumi elevati: \(resources.map { D($0.rawValue) }.joined(separator: ", "))"))
                                .font(.system(size: 9)).foregroundStyle(DeckTheme.amber).lineLimit(2)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                Text("\(process.pid)").frame(width: 52, alignment: .trailing).foregroundStyle(DeckTheme.muted)
                Text(D(DeckFormat.percent(process.cpu))).frame(width: 65, alignment: .trailing)
                    .foregroundStyle(resources.contains(.cpu) ? DeckTheme.amber : DeckTheme.foreground)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(D(process.memory.map(DeckFormat.bytes) ?? "—"))
                    if let percent = process.memoryPercent(totalMemory: store.snapshot.memoryTotal) {
                        Text(D(DeckFormat.percent(percent))).font(.system(size: 9)).foregroundStyle(DeckTheme.muted)
                    }
                }.frame(width: 90, alignment: .trailing)
                    .foregroundStyle(resources.contains(.memory) ? DeckTheme.amber : DeckTheme.foreground)
                Text(D(process.gpu.map { DeckFormat.percent($0) } ?? (process.gpuClient ? "Client" : "—")))
                    .frame(width: 85, alignment: .trailing).foregroundStyle(resources.contains(.gpu) ? DeckTheme.amber : DeckTheme.purple)
            }.font(.system(size: 11)).monospacedDigit().padding(.horizontal, 8).padding(.vertical, 9)
                .background(selection == process.id ? DeckTheme.mint.opacity(0.10) : resources.isEmpty ? .clear : DeckTheme.amber.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

private func resourceColor(_ resource: ProcessSort) -> Color {
    resource == .cpu ? DeckTheme.blue : resource == .memory ? DeckTheme.mint : DeckTheme.purple
}

private func resourceSymbol(_ resource: ProcessSort) -> String {
    resource == .cpu ? "cpu" : resource == .memory ? "memorychip" : "square.3.layers.3d"
}

private struct ProcessResourceOverview: View {
    let resource: ProcessSort
    let snapshot: SystemSnapshot
    let cores: Int
    let processes: [RunningProcess]
    let focusedGroupID: String?
    var selectGroup: (ProcessResourceGroup) -> Void

    var body: some View {
        let groups = ProcessResourceGroup.groups(processes, sortedBy: resource).filter { $0.isRelevant(for: resource) }
        let unavailableCount = processes.filter { (resource != .gpu || $0.gpuClient) && resource.value(for: $0) == nil }.count
        DeckCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Label(L("DOVE VA LA \(resource == .memory ? "RAM" : resource.rawValue)"), systemImage: resourceSymbol(resource)).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(DeckTheme.muted)
                    Spacer()
                    Text(D(totalLabel)).font(.system(size: 12, weight: .semibold)).monospacedDigit()
                }
                resourceBreakdown
                Divider()
                HStack {
                    Text(D(resource == .memory ? "CHI NE OCCUPA DI PIÙ" : resource == .gpu && !groups.contains(where: { $0.value(for: .gpu) != nil }) ? "APP CON CLIENT GPU RILEVATI" : "CHI LA USA DI PIÙ")).font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(DeckTheme.muted)
                    Spacer()
                    Text(D(resource == .cpu ? "CPU app / quota del Mac" : resource == .memory ? "Memoria / quota della RAM" : "Percentuali disponibili e client rilevati")).font(.system(size: 10)).foregroundStyle(DeckTheme.muted)
                }
                if groups.isEmpty {
                    Text(D(processes.isEmpty ? "Lettura dei processi…" : resource == .gpu ? "Nessun client GPU o contatore valido rilevato in questo campione." : resource == .cpu ? "Percentuali CPU non ancora disponibili. Al primo campione occorre attendere il prossimo aggiornamento." : "macOS non rende disponibili i consumi di memoria dei processi."))
                        .font(.system(size: 11)).foregroundStyle(DeckTheme.muted)
                } else {
                    VStack(spacing: 3) {
                        ForEach(Array(groups.prefix(5))) { group in
                            groupRow(group)
                        }
                    }
                    Text(L("App e processi di supporto riuniti, fino a 5 voci di tutti gli utenti. Clicca una voce per vedere i processi ordinati per \(resource.rawValue.lowercased())."))
                        .font(.system(size: 10)).foregroundStyle(DeckTheme.muted).fixedSize(horizontal: false, vertical: true)
                }
                Text(D(rankingExplanation) + (unavailableCount > 0 ? L(" \(unavailableCount) \(resource == .gpu ? "client senza percentuale" : "processi senza misura") esclusi dai totali; i valori parziali sono indicati con ≥.") : ""))
                    .font(.system(size: 9)).foregroundStyle(DeckTheme.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var totalLabel: String {
        switch resource {
        case .cpu: return DeckFormat.percent(snapshot.cpu) + " utilizzo del Mac · \(cores) core"
        case .gpu: return DeckFormat.percent(snapshot.gpu) + " utilizzo del dispositivo"
        case .memory:
            guard let memory = snapshot.memoryBreakdown else { return "Ripartizione non disponibile" }
            return "\(DeckFormat.percent(memory.percent(memory.used))) usata · \(DeckFormat.bytes(memory.used)) di \(DeckFormat.bytes(memory.total))"
        }
    }

    private var rankingExplanation: String {
        switch resource {
        case .cpu:
            return "La CPU di ogni app somma i suoi processi: 100% equivale a un core e può essere superato. La quota del Mac divide questo valore per \(cores) core. Le letture dei processi e del sistema coprono intervalli diversi: la somma può differire dall’utilizzo totale."
        case .memory:
            return "La classifica somma la memoria residente: alcune pagine sono condivise e la memoria compressa non è inclusa. I valori non si sommano per ottenere la RAM usata e non indicano quanta RAM si libererebbe chiudendo un’app."
        case .gpu:
            return "Le percentuali aggregano solo contatori validi. «Client» indica una connessione alla GPU, non un consumo misurato. I valori disponibili vengono prima dei client senza percentuale; la loro somma non ricostruisce l’utilizzo del dispositivo."
        }
    }

    @ViewBuilder private var resourceBreakdown: some View {
        if resource == .memory {
            if let memory = snapshot.memoryBreakdown { memoryBreakdown(memory) }
            else { Text(L("Ripartizione della memoria non ancora disponibile.")).font(.system(size: 11)).foregroundStyle(DeckTheme.muted) }
        } else if resource == .cpu {
            VStack(alignment: .leading, spacing: 12) {
                Text(L("Utilizzo complessivo da 0 a 100%, considerando tutti i core. Nella classifica sotto, la CPU delle app usa invece 100% per core."))
                    .font(.system(size: 11)).foregroundStyle(DeckTheme.muted).fixedSize(horizontal: false, vertical: true)
                if let used = snapshot.cpu {
                    if let user = snapshot.cpuUser, let system = snapshot.cpuSystem {
                        utilizationBar([(user, DeckTheme.blue), (system, DeckTheme.purple), (max(0, 100 - used), DeckTheme.mint.opacity(0.25))])
                    } else { utilizationBar([(used, DeckTheme.blue), (max(0, 100 - used), DeckTheme.mint.opacity(0.25))]) }
                }
                HStack(alignment: .top, spacing: 12) {
                    summaryPart("App e servizi", value: DeckFormat.percent(snapshot.cpuUser), color: DeckTheme.blue, detail: "Tempo CPU in modalità utente, comprese le attività in background.")
                    summaryPart("Sistema", value: DeckFormat.percent(snapshot.cpuSystem), color: DeckTheme.purple, detail: "Tempo CPU impiegato dal kernel del sistema operativo.")
                    summaryPart("Capacità libera", value: DeckFormat.percent(snapshot.cpu.map { max(0, 100 - $0) }), color: DeckTheme.mint, detail: "Percentuale del tempo CPU complessivo non utilizzata nell’ultimo intervallo.")
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Text(D(snapshot.gpu == nil ? "macOS non espone l’utilizzo complessivo della GPU su questo Mac. I client rilevati restano consultabili." : "Utilizzo complessivo del dispositivo. L’attribuzione alle app dipende dai contatori che macOS rende disponibili."))
                    .font(.system(size: 11)).foregroundStyle(DeckTheme.muted).fixedSize(horizontal: false, vertical: true)
                if let used = snapshot.gpu { utilizationBar([(used, DeckTheme.purple), (max(0, 100 - used), DeckTheme.subtle.opacity(0.06))]) }
                HStack(alignment: .top, spacing: 12) {
                    summaryPart("Utilizzo dispositivo", value: DeckFormat.percent(snapshot.gpu), color: DeckTheme.purple, detail: "Lettura totale della GPU, indipendente dalle misure dei singoli processi.")
                    summaryPart("Processi con misura", value: String(processes.filter { ProcessSort.gpu.value(for: $0) != nil }.count), color: DeckTheme.blue, detail: "Processi per cui è disponibile una percentuale GPU valida. Zero significa nessuna misura attribuibile, non GPU inattiva.")
                    summaryPart("Client rilevati", value: String(processes.filter(\.gpuClient).count), color: DeckTheme.mint, detail: "Processi con una connessione GPU rilevata. La connessione non implica attività.")
                }
                if !processes.contains(where: { ProcessSort.gpu.value(for: $0) != nil }) {
                    Label(L("Percentuali per app non disponibili: mostro i client rilevati senza stimarne il consumo."), systemImage: "info.circle")
                        .font(.system(size: 10)).foregroundStyle(DeckTheme.amber).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func utilizationBar(_ parts: [(Double, Color)]) -> some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                ForEach(parts.indices, id: \.self) { index in
                    Rectangle().fill(parts[index].1).frame(width: geometry.size.width * min(100, max(0, parts[index].0)) / 100)
                }
            }.clipShape(Capsule())
        }.frame(height: 8).accessibilityHidden(true)
    }

    private func memoryBreakdown(_ memory: MemoryBreakdown) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("La RAM usata comprende app, servizi di sistema e dati compressi. La percentuale da sola non misura un rallentamento."))
                .font(.system(size: 11)).foregroundStyle(DeckTheme.muted).fixedSize(horizontal: false, vertical: true)
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    Rectangle().fill(DeckTheme.blue).frame(width: geometry.size.width * memory.percent(memory.appAndServices) / 100)
                    Rectangle().fill(DeckTheme.purple).frame(width: geometry.size.width * memory.percent(memory.wired) / 100)
                    Rectangle().fill(DeckTheme.amber).frame(width: geometry.size.width * memory.percent(memory.compressed) / 100)
                    Rectangle().fill(DeckTheme.mint.opacity(0.25))
                }.clipShape(Capsule())
            }.frame(height: 8).accessibilityHidden(true)
            HStack(alignment: .top, spacing: 12) {
                memoryPart("App e servizi (stima)", bytes: memory.appAndServices, color: DeckTheme.blue, detail: "Parte della RAM usata che resta dopo aver sottratto sistema wired e memoria compressa. Comprende anche attività in background.")
                memoryPart("Sistema (wired)", bytes: memory.wired, color: DeckTheme.purple, detail: "Memoria che deve restare nella RAM per il funzionamento del sistema; non può essere compressa o spostata su disco.")
                memoryPart("Compressa", bytes: memory.compressed, color: DeckTheme.amber, detail: "Spazio fisico occupato dai dati che macOS ha compresso per fare posto nella RAM.")
                memoryPart("Libera / recuperabile", bytes: memory.reusable, color: DeckTheme.mint, detail: "Il resto della RAM: libera o recuperabile, inclusa la cache dei file esclusa dalla memoria usata.")
            }
            Text(L("Swap su disco: \(DeckFormat.bytes(snapshot.swapUsed)). È spazio sul disco, separato dalla RAM. La quantità già presente non indica da sola un problema in corso."))
                .font(.system(size: 10)).foregroundStyle(DeckTheme.muted).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func memoryPart(_ title: String, bytes: UInt64, color: Color, detail: String) -> some View {
        summaryPart(title, value: DeckFormat.bytes(bytes), color: color, detail: detail)
    }

    private func summaryPart(_ title: String, value: String, color: Color, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 4) {
                Circle().fill(color).frame(width: 5, height: 5).padding(.top, 3)
                Text(D(title)).font(.system(size: 9)).foregroundStyle(DeckTheme.muted).fixedSize(horizontal: false, vertical: true)
            }
            Text(value).font(.system(size: 15, weight: .semibold)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading).help(D(detail)).accessibilityElement(children: .combine).accessibilityHint(D(detail))
    }

    private func groupRow(_ group: ProcessResourceGroup) -> some View {
        let value = group.value(for: resource)
        let percent = group.capacityPercent(for: resource, totalMemory: snapshot.memoryTotal, cores: cores)
        let highUsage = resource == .memory ? (percent ?? 0) >= 10 : (value ?? 0) >= (resource == .cpu ? 80 : 50)
        let color = highUsage ? DeckTheme.amber : resourceColor(resource)
        let partial = value != nil && group.unavailableCount(for: resource) > 0
        let formatted = resource == .memory ? group.memory.map(DeckFormat.bytes) ?? "—" : value.map { DeckFormat.percent($0) } ?? "Client"
        return Button { selectGroup(group) } label: {
            HStack(spacing: 10) {
                Image(systemName: group.bundlePath == nil ? "gearshape" : "app").foregroundStyle(color).frame(width: 16)
                Text(group.name).font(.system(size: 11, weight: .medium)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                Text(L("\(group.processes.count) \(group.processes.count == 1 ? "processo" : "processi")")).font(.system(size: 10)).foregroundStyle(DeckTheme.muted).frame(width: 70, alignment: .trailing)
                if let percent {
                    GeometryReader { geometry in
                        Capsule().fill(DeckTheme.subtle.opacity(0.06))
                        Capsule().fill(color).frame(width: geometry.size.width * min(100, percent) / 100)
                    }.frame(width: 70, height: 4).accessibilityHidden(true)
                }
                Text(D((partial ? "≥ " : "") + formatted))
                    .font(.system(size: 11, weight: .semibold)).monospacedDigit().frame(width: 85, alignment: .trailing)
                if resource == .gpu {
                    Text(D(value == nil ? "Senza %" : partial ? "Parziale" : "Misurata")).font(.system(size: 9)).foregroundStyle(DeckTheme.muted).frame(width: 50, alignment: .trailing)
                } else {
                    Text(D(percent.map { (partial ? "≥ " : "") + DeckFormat.percent($0) } ?? "—"))
                        .font(.system(size: 10)).monospacedDigit().foregroundStyle(DeckTheme.muted).frame(width: 40, alignment: .trailing)
                        .help(D(resource == .cpu ? "Quota della capacità totale del Mac" : "Percentuale della RAM fisica"))
                }
                Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(DeckTheme.muted)
            }.padding(.horizontal, 8).padding(.vertical, 7)
                .background(focusedGroupID == group.id ? DeckTheme.mint.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
            .help(L("Mostra i processi di \(group.name) ordinati per \(resource.rawValue.lowercased()).\(partial ? " Totale parziale: alcune misure non sono disponibili." : "")"))
    }
}
