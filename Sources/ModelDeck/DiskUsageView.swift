import SwiftUI
import ModelDeckCore

struct DiskUsageView: View {
    @EnvironmentObject var store: DeckStore
    @State private var folder = DiskUsageScanner.defaultRoot
    @State private var result: DiskUsageResult?
    @State private var busy = false
    @State private var error: String?
    @State private var scanTask: Task<Void, Never>?
    @State private var scanID = UUID()
    @State private var volumeTotal: UInt64?
    @State private var volumeAvailable: UInt64?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            DeckCard {
                VStack(alignment: .leading, spacing: 14) {
                    SectionLabel(title: L("DOVE VA LO SPAZIO"), trailing: L("\(volumeAvailable.map(DeckFormat.bytes) ?? "—") liberi di \(volumeTotal.map(DeckFormat.bytes) ?? "—")"))
                    Text(L("Esplora cartelle e file dal più grande al più piccolo. Le dimensioni sono una stima dello spazio allocato leggibile."))
                        .font(.system(size: 11)).foregroundStyle(DeckTheme.muted).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button(L("Questo disco")) { folder = DiskUsageScanner.defaultRoot; startScan() }
                        Button(L("Cartella utente")) { folder = FileManager.default.homeDirectoryForCurrentUser; startScan() }
                        Button(L("Scegli cartella…")) { chooseFolder() }
                        Spacer()
                        if busy { Button(L("Interrompi")) { scanTask?.cancel(); busy = false } }
                        else { Button(L("Analizza di nuovo")) { startScan() } }
                    }.buttonStyle(.bordered).font(.system(size: 11))
                    HStack {
                        Button { folder.deleteLastPathComponent(); startScan() } label: { Image(systemName: "arrow.up") }
                            .disabled(folder.path == "/" || busy).help(L("Cartella superiore"))
                        Text(folder.path).font(.system(size: 11, design: .monospaced)).lineLimit(2).textSelection(.enabled)
                        Spacer()
                        Button(L("Mostra nel Finder")) { NSWorkspace.shared.open(folder) }
                    }.font(.system(size: 10))
                    if busy { HStack { ProgressView().controlSize(.small); Text(L("Analisi in corso… Puoi interromperla. Ogni passaggio è limitato a 30 secondi.")).font(.system(size: 11)).foregroundStyle(DeckTheme.muted) } }
                    if let error { Text(D(error)).font(.system(size: 11)).foregroundStyle(DeckTheme.amber) }
                    if let result {
                        Text(L("\(DeckFormat.bytes(result.bytes)) rilevati · \(result.visitedCount) elementi letti\(result.limited ? " · analisi parziale: limite raggiunto" : "")"))
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(result.limited ? DeckTheme.amber : DeckTheme.foreground)
                        if result.inaccessibleCount > 0 {
                            Text(L("\(result.inaccessibleCount) percorsi non leggibili. I relativi totali sono parziali; puoi analizzare una cartella più specifica."))
                                .font(.system(size: 10)).foregroundStyle(DeckTheme.amber).fixedSize(horizontal: false, vertical: true)
                        }
                        if result.entries.isEmpty { Text(L("Questa cartella è vuota.")).font(.system(size: 11)).foregroundStyle(DeckTheme.muted) }
                        ForEach(result.entries.prefix(80)) { entry in entryRow(entry, total: result.bytes) }
                        if result.entries.count > 80 { Text(L("Mostrate le prime 80 di \(result.entries.count) voci, ordinate per dimensione.")).font(.system(size: 10)).foregroundStyle(DeckTheme.muted) }
                    }
                    Text(L("Snapshot APFS, file clonati, spazio condiviso e cartelle protette possono impedire di ricostruire il totale del disco. I collegamenti simbolici e gli altri volumi non vengono attraversati. Nessun file viene eliminato."))
                        .font(.system(size: 10)).foregroundStyle(DeckTheme.muted).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let result, !result.largestFiles.isEmpty {
                DeckCard {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionLabel(title: L("FILE PIÙ GRANDI"), trailing: L("Nella cartella analizzata"))
                        ForEach(result.largestFiles) { entry in
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(entry.url.lastPathComponent).font(.system(size: 11, weight: .medium)).lineLimit(1)
                                    Text(entry.url.path).font(.system(size: 9)).foregroundStyle(DeckTheme.muted).lineLimit(1).help(D(entry.url.path))
                                }
                                Spacer()
                                Text(D(DeckFormat.bytes(entry.bytes))).font(.system(size: 11, design: .monospaced))
                                Button { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) } label: { Image(systemName: "folder") }.buttonStyle(.plain).help(L("Mostra nel Finder"))
                            }.padding(.vertical, 4)
                        }
                    }
                }
            }
        }.onAppear { if result == nil { startScan() } }.onDisappear { scanTask?.cancel() }
    }
    private func entryRow(_ entry: DiskUsageEntry, total: UInt64) -> some View {
        Button {
            if entry.isDirectory { folder = entry.url; startScan() }
            else { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: entry.isDirectory ? "folder" : "doc").foregroundStyle(DeckTheme.amber).frame(width: 18)
                Text(entry.url.lastPathComponent).font(.system(size: 11, weight: .medium)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                GeometryReader { geometry in
                    Capsule().fill(DeckTheme.subtle.opacity(0.06))
                    Capsule().fill(DeckTheme.amber).frame(width: total > 0 ? geometry.size.width * Double(entry.bytes) / Double(total) : 0)
                }.frame(width: 110, height: 4)
                Text(D((entry.partial ? "≥ " : "") + DeckFormat.bytes(entry.bytes))).font(.system(size: 11, design: .monospaced)).frame(width: 95, alignment: .trailing)
                Image(systemName: entry.isDirectory ? "chevron.right" : "arrow.up.right").font(.system(size: 9)).foregroundStyle(DeckTheme.muted)
            }.padding(.vertical, 8).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(busy)
    }
    private func startScan() {
        scanTask?.cancel(); error = nil; result = nil; busy = true
        if store.demo {
            volumeTotal = store.snapshot.diskTotal; volumeAvailable = store.snapshot.diskAvailable
            folder = URL(fileURLWithPath: "/Users/demo")
            let entries = [DiskUsageEntry(url: folder.appendingPathComponent("Library"), bytes: 94_000_000_000, isDirectory: true), DiskUsageEntry(url: folder.appendingPathComponent("Models"), bytes: 63_000_000_000, isDirectory: true), DiskUsageEntry(url: folder.appendingPathComponent("Downloads"), bytes: 18_000_000_000, isDirectory: true)]
            result = DiskUsageResult(root: folder, entries: entries, largestFiles: [DiskUsageEntry(url: folder.appendingPathComponent("Models/demo-model.gguf"), bytes: 21_000_000_000, isDirectory: false)], visitedCount: 12345, inaccessibleCount: 2, excludedCount: 4, limited: false)
            busy = false; return
        }
        let capacity = try? folder.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey])
        volumeTotal = capacity?.volumeTotalCapacity.map { UInt64(max(0, $0)) }
        volumeAvailable = capacity?.volumeAvailableCapacity.map { UInt64(max(0, $0)) }
        let id = UUID(); scanID = id; let target = folder
        scanTask = Task {
            do {
                let scanned = try await DiskUsageScanner.scan(target)
                guard !Task.isCancelled, scanID == id else { return }
                result = scanned; busy = false
            } catch is CancellationError { }
            catch { guard scanID == id else { return }; self.error = error.localizedDescription; busy = false }
        }
    }
    private func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { folder = url; startScan() }
    }
}
