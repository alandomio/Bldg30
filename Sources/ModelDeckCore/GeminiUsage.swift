import Foundation
import Darwin

/// Gemini quota from Antigravity: `agy -p "/usage" --output-format json` answers locally, with no agent turn and no token printed.
public enum GeminiUsage {
    public static func executable() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [home + "/.local/bin/agy", "/opt/homebrew/bin/agy", "/usr/local/bin/agy"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    public static func read(executableURL: URL? = nil) async throws -> SubscriptionUsage {
        try await Task.detached(priority: .utility) { try readBlocking(executableURL: executableURL) }.value
    }

    public static func readBlocking(executableURL: URL? = nil) throws -> SubscriptionUsage {
        guard let executable = executableURL ?? executable() else { throw DeckError.rpc("Installa Antigravity (agy) e accedi per vedere le quote Gemini.") }
        let process = Process(), output = Pipe()
        process.executableURL = executable; process.arguments = ["-p", "/usage", "--output-format", "json"]
        process.standardInput = FileHandle.nullDevice; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        try process.run()
        let deadline = DispatchWorkItem {
            if process.isRunning { process.terminate() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: deadline)
        defer { deadline.cancel(); if process.isRunning { process.terminate() } }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard !data.isEmpty, data.count < 2_000_000 else { throw DeckError.timeout }
        return try parse(data)
    }

    static let windowMinutes = ["weekly": 10080, "daily": 1440, "hourly": 60]

    public static func parse(_ data: Data, now: Date = Date()) throws -> SubscriptionUsage {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw DeckError.invalidResponse }
        guard (root["status"] as? String) == "SUCCESS" else { throw DeckError.rpc("Antigravity non disponibile. Accedi con agy e riprova.") }
        guard let groups = ((root["command"] as? [String: Any])?["data"] as? [String: Any])?["groups"] as? [[String: Any]] else { throw DeckError.invalidResponse }
        let dates = ISO8601DateFormatter()
        var windows: [UsageWindow] = []
        for group in groups {
            guard let name = group["name"] as? String, let buckets = group["buckets"] as? [[String: Any]] else { throw DeckError.invalidResponse }
            let label = name.hasPrefix("Gemini") ? "Modelli Gemini" : name == "Claude and GPT models" ? "Modelli Claude e GPT" : name
            for bucket in buckets {
                guard let id = bucket["id"] as? String, let remaining = bucket["remaining_fraction"] as? Double, remaining.isFinite, (0...1).contains(remaining) else { throw DeckError.invalidResponse }
                let window = bucket["window"] as? String ?? ""
                let minutes = windowMinutes[window]
                let span = minutes.map { $0 % 1440 == 0 ? "\($0 / 1440) giorni" : "\($0 / 60) ore" }
                windows.append(UsageWindow(id: id, title: span.map { "\(label) · \($0)" } ?? label, usedPercent: (1 - remaining) * 100,
                                           resetsAt: (bucket["reset_time"] as? String).flatMap { dates.date(from: $0) }, durationMinutes: minutes))
            }
        }
        return SubscriptionUsage(provider: "Google", windows: windows, updatedAt: now, source: "Antigravity · agy",
                                 message: windows.isEmpty ? "Nessuna quota restituita da Antigravity." : nil)
    }
}
