import SwiftUI
import ModelDeckCore

private struct DeckLanguageModifier: ViewModifier {
    @AppStorage("interfaceLanguage") private var language = DeckLanguage.automatic.rawValue
    func body(content: Content) -> some View {
        content.environment(\.locale, DeckLanguage.current.locale).id(language)
    }
}
extension View {
    func deckLanguage() -> some View { modifier(DeckLanguageModifier()) }
}
