import Foundation

public enum DeckLanguage: String, CaseIterable, Sendable {
    case automatic = "system", italian = "it", english = "en"
    public static var current: DeckLanguage {
        if CommandLine.arguments.contains("--english") { return .english }
        if CommandLine.arguments.contains("--italian") { return .italian }
        return DeckLanguage(rawValue: UserDefaults.standard.string(forKey: "interfaceLanguage") ?? "system") ?? .automatic
    }
    public var code: String {
        if self == .automatic { return Locale.preferredLanguages.first?.hasPrefix("it") == true ? "it" : "en" }
        return rawValue
    }
    public var locale: Locale { Locale(identifier: code) }
    public var title: String { self == .automatic ? D("Automatica") : self == .italian ? "Italiano" : "English" }
}

public struct DeckLocalizedString: ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
    public let key: String
    public let arguments: [String]
    public init(stringLiteral value: String) { key = value; arguments = [] }
    public init(stringInterpolation: StringInterpolation) { key = stringInterpolation.key; arguments = stringInterpolation.arguments }
    public struct StringInterpolation: StringInterpolationProtocol {
        var key = ""
        var arguments: [String] = []
        public init(literalCapacity: Int, interpolationCount: Int) { key.reserveCapacity(literalCapacity) }
        public mutating func appendLiteral(_ literal: String) { key += literal }
        public mutating func appendInterpolation<T>(_ value: T) { key += "%@"; arguments.append(String(describing: value)) }
    }
}

public enum DeckLocalization {
    private static let translations: [String: String] = {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle(for: BundleMarker.self)
        #endif
        guard let url = bundle.url(forResource: "English", withExtension: "json"), let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }()
    private final class BundleMarker: NSObject { }
    private static let patterns: [(NSRegularExpression, String)] = translations.compactMap { source, target in
        guard source.contains("%@"), source.filter({ $0.isLetter }).count >= 4 else { return nil }
        let expression = source.components(separatedBy: "%@").map(NSRegularExpression.escapedPattern(for:)).joined(separator: "([\\s\\S]*?)")
        guard let regex = try? NSRegularExpression(pattern: "^" + expression + "$") else { return nil }
        return (regex, target)
    }.sorted { $0.0.pattern.count > $1.0.pattern.count }
    public static func text(_ value: DeckLocalizedString, language: DeckLanguage = .current) -> String {
        let format = language.code == "en" ? translations[value.key] ?? value.key : value.key
        return substitute(format, arguments: value.arguments.map { dynamic($0, language: language, matchTemplates: false) })
    }
    public static func dynamic(_ value: String, language: DeckLanguage = .current, matchTemplates: Bool = true) -> String {
        guard language.code == "en" else { return value }
        if let translated = translations[value] { return translated }
        guard matchTemplates, value.count < 3000, value.contains(where: \.isLetter) else { return value }
        let range = NSRange(value.startIndex..., in: value)
        for (regex, target) in patterns {
            if let match = regex.firstMatch(in: value, range: range) {
                let arguments = (1..<match.numberOfRanges).map { index in Range(match.range(at: index), in: value).map { dynamic(String(value[$0]), language: language, matchTemplates: false) } ?? "" }
                return substitute(target, arguments: arguments)
            }
        }
        return value
    }
    private static func substitute(_ template: String, arguments: [String]) -> String {
        let parts = template.components(separatedBy: "%@")
        guard parts.count == arguments.count + 1 else { return template }
        return parts.enumerated().reduce("") { $0 + ($1.offset > 0 ? arguments[$1.offset - 1] : "") + $1.element }
    }
    public static func menuText(_ value: String) -> String {
        guard DeckLanguage.current.code == "en" else { return value }
        var text = value.components(separatedBy: "\n").map { dynamic($0) }.joined(separator: "\n")
        for (source, target) in [("rimanente", "remaining"), ("usato", "used"), ("non disponibile", "unavailable"), ("da aggiornare", "needs refresh"), ("scaduto", "expired")] {
            text = text.replacingOccurrences(of: source, with: target)
        }
        text = text.replacingOccurrences(of: "(?<=\\d)g\\b", with: "d", options: .regularExpression)
        return text
    }
}

public func L(_ value: DeckLocalizedString) -> String { DeckLocalization.text(value) }
public func D(_ value: String) -> String { DeckLocalization.dynamic(value) }
