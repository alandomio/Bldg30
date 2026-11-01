import Foundation

/// Summed CPU and memory of Microsoft Defender for Endpoint daemons, read from the process list only; Defender itself is never called.
public struct DefenderUsage: Equatable, Sendable {
    public static let namePrefix = "wdavdaemon"
    public let cpu: Double?
    public let memory: UInt64
    public let processCount: Int
    public init(cpu: Double?, memory: UInt64, processCount: Int) { self.cpu = cpu; self.memory = memory; self.processCount = processCount }

    /// Returns nil when no Defender process runs. CPU stays nil until a sample has a baseline, so it never reads as 0%.
    public static func summarize(_ processes: [RunningProcess]) -> DefenderUsage? {
        let matches = processes.filter { $0.name.lowercased().hasPrefix(namePrefix) }
        guard !matches.isEmpty else { return nil }
        let values = matches.compactMap(\.cpu)
        return DefenderUsage(cpu: values.isEmpty ? nil : values.reduce(0, +), memory: matches.reduce(0) { $0 + ($1.memory ?? 0) }, processCount: matches.count)
    }
}
