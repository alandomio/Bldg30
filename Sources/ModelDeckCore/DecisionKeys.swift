import Foundation

/// Keyboard shortcuts of the decision card: a letter picks an option, the arrows move between cards.
public enum DecisionKeys {
    public enum Command: Equatable, Sendable { case pick(Int), previous, next, selectUp, selectDown, confirm }
    public enum Key: Equatable, Sendable { case character(String), left, right, up, down, enter }

    /// A decision card carries up to five lettered options (A to E); more rows stay clickable but have no keycap.
    public static let maxLettered = 5
    /// Keycap of the n-th specific option, nil past the fifth.
    public static func keycap(_ index: Int) -> String? { (0..<maxLettered).contains(index) ? letter(index) : nil }
    /// Keycap letter of the n-th specific option: A, B, C ...
    public static func letter(_ index: Int) -> String { String(UnicodeScalar(UInt8(65 + min(max(index, 0), 25)))) }
    /// The selected option after Up or Down: stays inside the list, starts on the recommended one (or the first).
    public static func moved(selected: Int?, recommended: Int?, by step: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let start = min(max(selected ?? recommended ?? 0, 0), count - 1)
        return min(max(start + step, 0), count - 1)
    }
    /// The command for a key press, nil for keys that mean nothing here or while the user types.
    public static func command(_ key: Key, optionCount: Int, typing: Bool) -> Command? {
        guard !typing else { return nil }
        switch key {
        case .left: return .previous
        case .right: return .next
        case .up: return .selectUp
        case .down: return .selectDown
        case .enter: return .confirm
        case .character(let text):
            guard text.count == 1, let scalar = text.uppercased().unicodeScalars.first, ("A"..."Z").contains(Character(scalar)) else { return nil }
            let index = Int(scalar.value) - 65
            return index < min(optionCount, maxLettered) ? .pick(index) : nil
        }
    }
}
