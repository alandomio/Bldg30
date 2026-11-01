import SwiftUI
import ServiceManagement
import ModelDeckCore

struct SettingsView: View {
    @EnvironmentObject var store: DeckStore
    @State private var ollamaURL = UserDefaults.standard.string(forKey: "ollamaURL") ?? "http://127.0.0.1:11434"
    @State private var lmStudioURL = UserDefaults.standard.string(forKey: "lmStudioURL") ?? "http://127.0.0.1:1234"
    @State private var unslothURL = UserDefaults.standard.string(forKey: "unslothURL") ?? "http://127.0.0.1:8888"
    @AppStorage("sampleInterval") private var interval = 2.0
    @AppStorage("appearance") private var appearance = DeckAppearance.system.rawValue
    @AppStorage("interfaceLanguage") private var language = DeckLanguage.automatic.rawValue
    @State private var token = ""
    @State private var tokenEdited = false
    @State private var unslothToken = ""
    @State private var unslothTokenEdited = false
    @AppStorage("boardEnabled") private var boardEnabled = false
    @AppStorage("companionEnabled") private var companionEnabled = false
    @AppStorage("companionFeedPath") private var companionFeedPath = ""
    @AppStorage("companionInboxPath") private var companionInboxPath = ""
    @State private var linearKey = ""
    @State private var linearKeyEdited = false
    @State private var linearKeySaved = DeckKeychain.read(account: "linear") != nil
    @State private var folders: [String] = UserDefaults.standard.stringArray(forKey: "modelFolders") ?? []
    @State private var unslothFolders: [String] = UserDefaults.standard.stringArray(forKey: "unslothFolders") ?? []
    @State private var bridgeInstalled = ClaudeBridge.isInstalled()
    @State private var loginEnabled = SMAppService.mainApp.status == .enabled
    @State private var feedback: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            DeckCard {
                HStack {
                    Text(L("Aspetto")).font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Picker(L("Tema"), selection: $appearance) {
                        ForEach(DeckAppearance.allCases, id: \.rawValue) { Text(D($0.title)).tag($0.rawValue) }
                    }.pickerStyle(.segmented).frame(width: 280, height: 26)
                }
            }
            DeckCard {
                HStack {
                    Text(L("Lingua")).font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Picker(L("Lingua dell’interfaccia"), selection: $language) {
                        ForEach(DeckLanguage.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                    }.labelsHidden().pickerStyle(.segmented).frame(width: 280, height: 26)
                }
            }
            MenuBarSettingsView()
            DeckCard {
                VStack(alignment: .leading, spacing: 16) {
                    Text(L("Server locali")).font(.system(size: 15, weight: .semibold))
                    field("Ollama", value: $ollamaURL)
                    field("LM Studio", value: $lmStudioURL)
                    field("Unsloth", value: $unslothURL)
                    HStack {
                        Text(L("Token LM Studio")).frame(width: 115, alignment: .leading)
                        SecureField(L("Opzionale · salvato nel Portachiavi"), text: $token).textFieldStyle(.roundedBorder).onChange(of: token) { _, _ in tokenEdited = true }
                    }.font(.system(size: 11))
                    HStack {
                        Text(L("API key Unsloth")).frame(width: 115, alignment: .leading)
                        SecureField(L("Opzionale · salvata nel Portachiavi"), text: $unslothToken).textFieldStyle(.roundedBorder).onChange(of: unslothToken) { _, _ in unslothTokenEdited = true }
                    }.font(.system(size: 11))
                    Text(L("Sono ammessi solo localhost e indirizzi loopback. Nessuna scansione della rete."))
                        .font(.system(size: 10)).foregroundStyle(DeckTheme.muted)
                    Button(L("Salva e verifica")) {
                        do {
                            _ = try LocalHTTP.endpoint(ollamaURL); _ = try LocalHTTP.endpoint(lmStudioURL)
                            _ = try LocalHTTP.endpoint(unslothURL)
                            if tokenEdited { try DeckKeychain.save(token); tokenEdited = false }
                            if unslothTokenEdited { try DeckKeychain.save(unslothToken, account: "unsloth"); unslothTokenEdited = false }
                            UserDefaults.standard.set(ollamaURL, forKey: "ollamaURL")
                            UserDefaults.standard.set(lmStudioURL, forKey: "lmStudioURL")
                            UserDefaults.standard.set(unslothURL, forKey: "unslothURL")
                            feedback = "Impostazioni salvate."
                            Task { await store.refreshModels() }
                        } catch { feedback = error.localizedDescription }
                    }.buttonStyle(.bordered)
                }
            }
            DeckCard {
                VStack(alignment: .leading, spacing: 14) {
                    Toggle(L("Bacheca Linear"), isOn: $boardEnabled).font(.system(size: 15, weight: .semibold))
                    Text(L("Spenta di default. Se attiva, legge i tuoi ticket aperti da api.linear.app con una API key personale."))
                        .font(.system(size: 11)).foregroundStyle(DeckTheme.muted).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Text(L("API key Linear")).frame(width: 115, alignment: .leading)
                        SecureField(D(linearKeySaved ? "Salvata nel Portachiavi" : "Incolla la chiave · salvata nel Portachiavi"), text: $linearKey).textFieldStyle(.roundedBorder).onChange(of: linearKey) { _, _ in linearKeyEdited = true }
                    }.font(.system(size: 11)).disabled(!boardEnabled)
                    HStack {
                        Button(L("Salva chiave")) {
                            do {
                                if linearKeyEdited { try DeckKeychain.save(linearKey.trimmingCharacters(in: .whitespacesAndNewlines), account: "linear") }
                                linearKey = ""; linearKeyEdited = false
                                linearKeySaved = DeckKeychain.read(account: "linear") != nil
                                feedback = linearKeySaved ? "Chiave Linear salvata." : "Chiave Linear rimossa."
                            } catch { feedback = error.localizedDescription }
                        }
                        Button(L("Rimuovi chiave")) {
                            do {
                                try DeckKeychain.save("", account: "linear")
                                linearKey = ""; linearKeyEdited = false; linearKeySaved = false
                                feedback = "Chiave Linear rimossa."
                            } catch { feedback = error.localizedDescription }
                        }.disabled(!linearKeySaved)
                    }.buttonStyle(.bordered).disabled(!boardEnabled)
                }
            }
            DeckCard {
                VStack(alignment: .leading, spacing: 14) {
                    Toggle(L("Companion"), isOn: $companionEnabled).font(.system(size: 15, weight: .semibold))
                    Text(L("Spento di default. Legge un file feed JSON scritto dal tuo assistente e scrive note JSON in una cartella inbox. Non contatta nessun servizio."))
                        .font(.system(size: 11)).foregroundStyle(DeckTheme.muted).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Text(L("File feed")).frame(width: 115, alignment: .leading)
                        TextField(CompanionFeed.defaultPath, text: $companionFeedPath).textFieldStyle(.roundedBorder)
                    }.font(.system(size: 11)).disabled(!companionEnabled)
                    HStack {
                        Text(L("Cartella inbox")).frame(width: 115, alignment: .leading)
                        TextField(L("Obbligatoria per inviare azioni"), text: $companionInboxPath).textFieldStyle(.roundedBorder)
                    }.font(.system(size: 11)).disabled(!companionEnabled)
                }
            }
            DeckCard {
                VStack(alignment: .leading, spacing: 14) {
                    Text(L("Cartelle dei modelli")).font(.system(size: 15, weight: .semibold))
                    Text(L("Incluse le cartelle standard di Ollama, LM Studio, Unsloth Studio e la cache Hugging Face condivisa. Aggiungi qui percorsi personalizzati o dischi esterni."))
                        .font(.system(size: 11)).foregroundStyle(DeckTheme.muted)
                    ForEach(folders, id: \.self) { folder in
                        HStack {
                            Image(systemName: "folder").foregroundStyle(DeckTheme.purple)
                            Text(folder.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")).font(.system(size: 10, design: .monospaced)).lineLimit(1)
                            Spacer()
                            Button { folders.removeAll { $0 == folder }; saveFolders() } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain).help(L("Rimuovi cartella dall’inventario"))
                        }
                    }
                    ForEach(unslothFolders, id: \.self) { folder in
                        HStack {
                            Text(L("Unsloth")).foregroundStyle(DeckTheme.amber)
                            Text(folder.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")).lineLimit(1)
                            Spacer()
                            Button { unslothFolders.removeAll { $0 == folder }; saveFolders() } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain)
                        }.font(.system(size: 10, design: .monospaced))
                    }
                    HStack {
                        Button(L("Aggiungi cartella…")) { chooseFolder(unsloth: false) }
                        Button(L("Aggiungi cartella Unsloth…")) { chooseFolder(unsloth: true) }
                    }.buttonStyle(.bordered)
                    Text(L("La cache Hugging Face può essere usata da più applicazioni; i suoi pesi sono raggruppati sotto Unsloth."))
                        .font(.system(size: 10)).foregroundStyle(DeckTheme.muted)
                }
            }
            DeckCard {
                VStack(alignment: .leading, spacing: 14) {
                    Text(L("Quote degli abbonamenti")).font(.system(size: 15, weight: .semibold))
                    Text(L("Codex usa l’account già collegato alla CLI. Accedi con codex login se la quota non compare. Non vengono avviate conversazioni né richieste ai modelli."))
                        .font(.system(size: 11)).foregroundStyle(DeckTheme.muted).fixedSize(horizontal: false, vertical: true)
                    Divider()
                    Text(L("Claude Code aggiorna le quote dopo le risposte. Il collegamento modifica ~/.claude/settings.json, conserva la status line attuale e salva solo percentuali e orari di reset. Il ripristino rimuove il collegamento."))
                        .font(.system(size: 11)).foregroundStyle(DeckTheme.muted).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button(D(bridgeInstalled ? "Ripristina status line" : "Collega Claude Code")) {
                            do {
                                if bridgeInstalled { try ClaudeBridge.uninstall() }
                                else { try ClaudeBridge.install(executable: Bundle.main.executableURL!) }
                                bridgeInstalled = ClaudeBridge.isInstalled()
                                feedback = bridgeInstalled ? "Collegato. Riavvia la sessione Claude Code e invia un messaggio." : "Status line precedente ripristinata."
                            } catch { feedback = error.localizedDescription }
                        }.buttonStyle(.bordered)
                        Link(L("Documentazione"), destination: URL(string: "https://code.claude.com/docs/en/statusline")!).font(.system(size: 11))
                    }
                    Text(L("Le quote di Codex non rappresentano tutti i limiti dell’app ChatGPT. Non sono costi API né percentuali di contesto."))
                        .font(.system(size: 10)).foregroundStyle(DeckTheme.muted)
                }
            }
            DeckCard {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text(L("Aggiornamento metriche")).font(.system(size: 11)); Spacer()
                        Picker(L("Intervallo"), selection: $interval) { Text(L("2 secondi")).tag(2.0); Text(L("5 secondi")).tag(5.0); Text(L("10 secondi")).tag(10.0) }.labelsHidden().frame(width: 150)
                    }
                    Toggle(L("Apri all’accesso al Mac"), isOn: $loginEnabled).font(.system(size: 11)).onChange(of: loginEnabled) { _, value in
                        do { if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                        catch { feedback = error.localizedDescription; loginEnabled = SMAppService.mainApp.status == .enabled }
                    }
                    Text(L("Modelli: ogni 30 s. Quote Codex: ogni 90 s. La disponibilità della metrica GPU dipende dal Mac; temperature e consumi non vengono stimati."))
                        .font(.system(size: 10)).foregroundStyle(DeckTheme.muted)
                }
            }
            if let feedback { Text(D(feedback)).font(.system(size: 12)).foregroundStyle(DeckTheme.amber).textSelection(.enabled) }
        }.tint(DeckTheme.mint)
    }
    private func field(_ label: String, value: Binding<String>) -> some View {
        HStack { Text(D(label)).frame(width: 115, alignment: .leading); TextField(L(""), text: value).textFieldStyle(.roundedBorder) }.font(.system(size: 11))
    }
    private func chooseFolder(unsloth: Bool) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            if unsloth { unslothFolders = Array(Set(unslothFolders + panel.urls.map(\.path))).sorted() }
            else { folders = Array(Set(folders + panel.urls.map(\.path))).sorted() }
            saveFolders()
        }
    }
    private func saveFolders() {
        UserDefaults.standard.set(folders, forKey: "modelFolders"); UserDefaults.standard.set(unslothFolders, forKey: "unslothFolders")
        Task { await store.refreshModels() }
    }
}
