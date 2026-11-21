import Testing
import Foundation
@testable import ModelDeckCore

@Suite struct LocalizationCoverageTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let catalog: [String: String] = {
        let data = try! Data(contentsOf: root.appendingPathComponent("Sources/ModelDeckCore/Resources/English.json"))
        return try! JSONDecoder().decode([String: String].self, from: data)
    }()
    @Test func everyKeyHasAnEnglishValueWithTheSameInterpolations() {
        for (key, value) in Self.catalog {
            #expect(!key.isEmpty && !value.trimmingCharacters(in: .whitespaces).isEmpty, "empty value for \(key)")
            #expect(key.components(separatedBy: "%@").count == value.components(separatedBy: "%@").count, "interpolation count differs for \(key)")
        }
    }

    @Test func everyPlainKeyLooksUpToItsEnglishValue() {
        for (key, value) in Self.catalog where !key.contains("%@") {
            #expect(DeckLocalization.dynamic(key, language: .english) == value, "lookup of \(key)")
            #expect(DeckLocalization.dynamic(key, language: .italian) == key, "Italian keeps \(key)")
        }
    }

    @Test func interpolatedKeysFillArgumentsAndUnknownTextFallsBackToItself() throws {
        let (key, value) = try #require(Self.catalog.first { $0.key.components(separatedBy: "%@").count == 2 && $0.key.filter(\.isLetter).count >= 4 })
        let sample = key.replacingOccurrences(of: "%@", with: "42")
        #expect(DeckLocalization.dynamic(sample, language: .english) == value.replacingOccurrences(of: "%@", with: "42"))
        #expect(DeckLocalization.dynamic("Not in the catalog 9f3a", language: .english) == "Not in the catalog 9f3a")
        let missing: DeckLocalizedString = "Chiave inesistente \(7)"
        #expect(DeckLocalization.text(missing, language: .english) == "Chiave inesistente 7")
    }
}
