import Foundation

/// Summed CPU and memory of Microsoft Defender for Endpoint processes, read from the process list only; Defender itself is never called.
public struct DefenderUsage: Equatable, Sendable {
    public static let namePrefix = "wdavdaemon"
    public let cpu: Double?
    public let memory: UInt64
    public let processCount: Int
    /// False unless every Defender process could be read: root ones are hidden, and a partial sum would understate the load.
    public let usageAvailable: Bool
    public init(cpu: Double?, memory: UInt64, processCount: Int, usageAvailable: Bool? = nil) {
        self.cpu = cpu; self.memory = memory; self.processCount = processCount; self.usageAvailable = usageAvailable ?? (cpu != nil || memory > 0)
    }

    /// The daemons (`wdavdaemon*`), anything inside Microsoft Defender.app, and the `com.microsoft.wdav.*` system extensions (epsext, netext).
    public static func isDefender(_ process: RunningProcess) -> Bool {
        let name = process.name.lowercased()
        if name.hasPrefix(namePrefix) { return true }
        let path = process.path?.lowercased() ?? ""
        return path.contains("/microsoft defender.app/") || path.contains("com.microsoft.wdav.")
            || URL(fileURLWithPath: path).lastPathComponent.hasPrefix(namePrefix)
    }

    /// Returns nil when no Defender process runs. CPU stays nil until a sample has a baseline, so it never reads as 0%.
    public static func summarize(_ processes: [RunningProcess]) -> DefenderUsage? {
        let matches = processes.filter(isDefender)
        guard !matches.isEmpty else { return nil }
        let values = matches.compactMap(\.cpu)
        return DefenderUsage(cpu: values.isEmpty ? nil : values.reduce(0, +), memory: matches.compactMap(\.memory).reduce(0, +), processCount: matches.count,
                             usageAvailable: matches.allSatisfy { $0.memory != nil })
    }
}
