import Foundation

/// ShipDeck uses a new bundle identifier, so UserDefaults start empty. Copy the old ModelDeck settings once.
/// Application Support and Keychain items keep their old names, so they need no migration.
enum DeckMigration {
    static let oldDomain = "io.github.tommasinigiovanni.ModelDeck"
    static func run(defaults: UserDefaults = .standard, oldValues: [String: Any]? = nil) {
        guard !defaults.bool(forKey: "migratedFromModelDeck") else { return }
        let old = oldValues ?? defaults.persistentDomain(forName: oldDomain) ?? [:]
        for (key, value) in old where defaults.object(forKey: key) == nil { defaults.set(value, forKey: key) }
        defaults.set(true, forKey: "migratedFromModelDeck")
    }
}
