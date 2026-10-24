import SwiftUI
import ModelDeckCore

struct MenuBarSettingsView: View {
    @EnvironmentObject var store: DeckStore
    @AppStorage(MenuBarOptions.defaultsKey) private var rawOptions = MenuBarOptions().encoded
    private var options: MenuBarOptions { .decode(rawOptions) }
    private var summary: MenuBarSummary { .render(options: options, snapshot: store.snapshot, claude: store.claude, openAI: store.codex) }

    var body: some View {
        DeckCard {
            VStack(alignment: .leading, spacing: 14) {
                Text(L("Barra dei menu")).font(.system(size: 15, weight: .semibold))
                Text(L("Scegli i valori da affiancare all’icona. Disattivali tutti per mostrare solo l’icona."))
                    .font(.system(size: 11)).foregroundStyle(DeckTheme.muted)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3), alignment: .leading, spacing: 10) {
                    ForEach(MenuBarMetric.allCases, id: \.self) { metric in Toggle(D(metric.title), isOn: metricBinding(metric)).toggleStyle(.checkbox) }
                }.font(.system(size: 11))
                HStack {
                    Text(L("Disposizione")).frame(width: 115, alignment: .leading)
                    Picker(L("Disposizione"), selection: optionBinding(\.layout)) {
                        ForEach(MenuBarLayout.allCases, id: \.self) { Text(D($0.title)).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 300)
                }.font(.system(size: 11))
                HStack {
                    Text(L("Valore RAM")).frame(width: 115, alignment: .leading)
                    Picker(L("Valore RAM"), selection: optionBinding(\.memoryStyle)) {
                        ForEach(MenuBarMemoryStyle.allCases, id: \.self) { Text(D($0.title)).tag($0) }
                    }.labelsHidden().disabled(!options.metrics.contains(.memory))
                }.font(.system(size: 11))
                HStack {
                    Text(L("Percentuale quote")).frame(width: 115, alignment: .leading)
                    Picker(L("Percentuale quote"), selection: optionBinding(\.quotaStyle)) {
                        ForEach(MenuBarQuotaStyle.allCases, id: \.self) { Text(D($0.title)).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 240)
                }.font(.system(size: 11))
                windowPicker("Finestra Claude", metric: .claude, usage: store.claude, selection: optionBinding(\.claudeWindowID))
                windowPicker("Finestra OpenAI", metric: .openAI, usage: store.codex, selection: optionBinding(\.openAIWindowID))
                HStack(spacing: 9) {
                    if options.layout == .twoRows && !summary.readings.isEmpty {
                        Image(nsImage: MenuBarBadge.image(for: summary)).renderingMode(.template).fixedSize()
                    } else {
                        Image(systemName: "square.stack.3d.up")
                        if !summary.title.isEmpty { Text(D(summary.title)).monospacedDigit() }
                    }
                    Spacer(minLength: 0)
                }.font(.system(size: 11, weight: .medium)).padding(12)
                    .background(DeckTheme.subtle.opacity(0.04), in: RoundedRectangle(cornerRadius: 9)).help(D(summary.tooltip))
                    .accessibilityLabel(D("Anteprima barra dei menu. " + summary.tooltip))
                Text(L("Automatica mostra il limite più restrittivo disponibile. h = ore · g = giorni. * = ultimo dato da aggiornare; — = non disponibile. Il clic sull’icona apre il pannello; i valori restano nella barra."))
                    .font(.system(size: 10)).foregroundStyle(DeckTheme.muted).fixedSize(horizontal: false, vertical: true)
                Text(L("Quote \(options.quotaStyle == .used ? "utilizzate" : "rimanenti"). Nelle viste compatta e su due righe, finestra e dettagli compaiono passando il puntatore sull’icona."))
                    .font(.system(size: 10)).foregroundStyle(DeckTheme.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func metricBinding(_ metric: MenuBarMetric) -> Binding<Bool> {
        Binding(get: { options.metrics.contains(metric) }, set: { enabled in
            var next = options
            if enabled { next.metrics.insert(metric) } else { next.metrics.remove(metric) }
            rawOptions = next.encoded
        })
    }
    private func optionBinding<T>(_ keyPath: WritableKeyPath<MenuBarOptions, T>) -> Binding<T> {
        Binding(get: { options[keyPath: keyPath] }, set: { value in
            var next = options; next[keyPath: keyPath] = value; rawOptions = next.encoded
        })
    }
    private func windowPicker(_ title: String, metric: MenuBarMetric, usage: SubscriptionUsage, selection: Binding<String>) -> some View {
        let automatic = MenuBarSummary.selectedWindow(in: usage, id: "", provider: metric)
        return HStack {
            Text(D(title)).frame(width: 115, alignment: .leading)
            Picker(D(title), selection: selection) {
                Text(D("Automatica · più restrittiva" + (automatic.map { " · " + $0.title } ?? ""))).tag("")
                ForEach(usage.windows) { window in Text(D(window.title)).tag(window.id) }
                if !selection.wrappedValue.isEmpty, !usage.windows.contains(where: { $0.id == selection.wrappedValue }) {
                    Text(L("Finestra salvata · in attesa di dati")).tag(selection.wrappedValue)
                }
            }.labelsHidden().disabled(!options.metrics.contains(metric))
        }.font(.system(size: 11))
    }
}
