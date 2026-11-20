import Testing
import Foundation
@testable import ModelDeckCore

@Suite struct LocalizationCoverageTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let catalog: [String: String] = {
        let data = try! Data(contentsOf: root.appendingPathComponent("Sources/ModelDeckCore/Resources/English.json"))
        return try! JSONDecoder().decode([String: String].self, from: data)
    }()
    /// Brand names and acronyms that read the same in English.
    static let sameInEnglish: Set<String> = ["PID", "Unsloth", "ShipDeck", "CPU", "GPU", "Hugging Face"]

    @Test func everyKeyHasAnEnglishValueWithTheSameInterpolations() {
        for (key, value) in Self.catalog {
            #expect(!key.isEmpty && !value.trimmingCharacters(in: .whitespaces).isEmpty, "empty value for \(key)")
            #expect(key.components(separatedBy: "%@").count == value.components(separatedBy: "%@").count, "interpolation count differs for \(key)")
        }
    }

    /// Literals passed straight to L("…") or D("…"), with `\(…)` interpolations turned into %@.
    static func literals(in text: String) -> [String] {
        let chars = Array(text); var found: [String] = []; var i = 0
        while i + 2 < chars.count {
            guard (chars[i] == "L" || chars[i] == "D"), chars[i + 1] == "(", chars[i + 2] == "\"", i == 0 || !(chars[i - 1].isLetter || chars[i - 1].isNumber || chars[i - 1] == "_") else { i += 1; continue }
            var j = i + 3, result = "", ok = false
            while j < chars.count, chars[j] != "\n" {
                if chars[j] == "\\", j + 1 < chars.count, chars[j + 1] == "(" {
                    var depth = 1; j += 2
                    while j < chars.count, depth > 0 { if chars[j] == "(" { depth += 1 } else if chars[j] == ")" { depth -= 1 }; j += 1 }
                    result += "%@"
                } else if chars[j] == "\\", j + 1 < chars.count { result.append(chars[j + 1] == "n" ? "\n" : chars[j + 1]); j += 2 }
                else if chars[j] == "\"" { ok = j + 1 < chars.count && chars[j + 1] == ")"; break }
                else { result.append(chars[j]); j += 1 }
            }
            if ok { found.append(result) }
            i = max(j, i + 1)
        }
        return found
    }

    @Test func everyLocalizedLiteralInTheSourcesHasAnEnglishTranslation() throws {
        let sources = Self.root.appendingPathComponent("Sources").resolvingSymlinksInPath()
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var checked = 0
        for case let url as URL in files where url.pathExtension == "swift" {
            for key in Self.literals(in: try String(contentsOf: url, encoding: .utf8)) where key.contains(where: \.isLetter) {
                checked += 1
                #expect(Self.catalog[key] != nil || Self.sameInEnglish.contains(key), "no English for \(key) in \(url.lastPathComponent)")
            }
        }
        #expect(checked > 100)
    }
}
