import XCTest
@testable import ModelDeckCore

final class LocalizationTests: XCTestCase {
    func testBothLanguagesPreserveArgumentsAndTranslateInterfaceLabels() {
        let value: DeckLocalizedString = "\(12) processi · aggiornamento ogni 3 secondi"
        XCTAssertEqual(DeckLocalization.text(value, language: .italian), "12 processi · aggiornamento ogni 3 secondi")
        XCTAssertEqual(DeckLocalization.text(value, language: .english), "12 processes · refreshed every 3 seconds")
        XCTAssertEqual(DeckLocalization.dynamic("Impostazioni", language: .english), "Settings")
        XCTAssertEqual(DeckLocalization.dynamic("Automatica · più restrittiva · 7 giorni", language: .english), "Automatic · most restrictive · 7 days")
        XCTAssertEqual(DeckLocalization.dynamic("/Users/example/models/weights.gguf", language: .english), "/Users/example/models/weights.gguf")
        XCTAssertEqual(DeckLocalization.dynamic("Unknown model name", language: .english), "Unknown model name")
    }
    func testExpiredWindowsRequireAnExplanationEvenWithFreshData() {
        let usage = SubscriptionUsage(provider: "Claude", windows: [.init(id: "past", title: "5 ore", usedPercent: 10, resetsAt: .distantPast)], updatedAt: Date(), source: "test")
        XCTAssertFalse(usage.stale)
        XCTAssertTrue(usage.needsRefresh)
    }
    func testMenuTooltipTranslatesDurationsAndFreshnessWithoutChangingItalian() {
        let source = "Claude · 7 giorni · 58% utilizzato · ultimo dato, da aggiornare"
        XCTAssertEqual(DeckLocalization.menuText(source, language: .italian), source)
        XCTAssertEqual(DeckLocalization.menuText(source, language: .english), "Claude · 7 days · 58% used · last reading, needs refresh")
        XCTAssertEqual(DeckLocalization.menuText("Claude · quota selezionata · non disponibile o in attesa di aggiornamento", language: .english), "Claude · selected quota · unavailable or awaiting refresh")
    }
}
