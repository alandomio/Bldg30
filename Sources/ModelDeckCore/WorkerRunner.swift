import Foundation

public struct ExecResult: Equatable, Sendable {
    public let status: Int32, output: String, error: String, timedOut: Bool
    public var ok: Bool { status == 0 && !timedOut }
}

/// Runs one program with a hard time limit. Output is drained while it runs so a chatty verb cannot fill the pipe and hang.
public enum Shell {
    public static func run(_ path: String, _ args: [String], env: [String: String] = [:], timeout: TimeInterval = 30, cwd: String? = nil) async -> ExecResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = args
                var merged = ProcessInfo.processInfo.environment
                for (key, value) in env { merged[key] = value }
                // The app is started from Finder with a short PATH: firstmate's scripts need the usual tool dirs.
                merged["PATH"] = (["/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.npm-global/bin", NSHomeDirectory() + "/.local/bin"] + [(merged["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")]).joined(separator: ":")
                process.environment = merged
                if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
                let out = Pipe(), err = Pipe(), lock = NSLock()
                var outData = Data(), errData = Data(), timedOut = false
                out.fileHandleForReading.readabilityHandler = { handle in let d = handle.availableData; lock.lock(); outData.append(d); lock.unlock() }
                err.fileHandleForReading.readabilityHandler = { handle in let d = handle.availableData; lock.lock(); errData.append(d); lock.unlock() }
                process.standardOutput = out; process.standardError = err; process.standardInput = FileHandle.nullDevice
                do { try process.run() } catch {
                    continuation.resume(returning: ExecResult(status: 127, output: "", error: error.localizedDescription, timedOut: false)); return
                }
                let killer = DispatchWorkItem { lock.lock(); timedOut = true; lock.unlock(); process.terminate() }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                process.waitUntilExit()
                killer.cancel()
                out.fileHandleForReading.readabilityHandler = nil; err.fileHandleForReading.readabilityHandler = nil
                lock.lock()
                outData.append(out.fileHandleForReading.readDataToEndOfFile()); errData.append(err.fileHandleForReading.readDataToEndOfFile())
                let result = ExecResult(status: process.terminationStatus, output: String(decoding: outData, as: UTF8.self), error: String(decoding: errData, as: UTF8.self), timedOut: timedOut)
                lock.unlock()
                continuation.resume(returning: result)
            }
        }
    }
}

/// The safe control verbs the app calls itself (the executor split): refresh, peek, interrupt, exit, relaunch, and
/// prompt/answer when this home's `fm-control.sh` has them. Everything else is a click for firstmate.
public struct WorkerRunner: Sendable {
    public let home: String
    public init(home: String = WorkerRunner.defaultHome) { self.home = (home as NSString).expandingTildeInPath }
    public static var defaultHome: String {
        CommandArguments.value(after: "--fm-home") ?? UserDefaults.standard.string(forKey: "firstmateHome").flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory() + "/firstmate"
    }
    var env: [String: String] { ["FM_HOME": home] }
    func script(_ name: String) -> String { home + "/bin/" + name }
    public var available: Bool { FileManager.default.isExecutableFile(atPath: script("fm-crew-state.sh")) }

    /// `fm-crew-state.sh <task>`: the current state. The forge fallback is skipped so one row stays a few seconds.
    public func crewState(_ task: String, timeout: TimeInterval = 40) async -> CrewState? {
        let result = await Shell.run(script("fm-crew-state.sh"), [task], env: env.merging(["FM_CREW_STATE_NO_FORGE": "1"]) { $1 }, timeout: timeout)
        return CrewState.parse(result.output)
    }
    /// Crew state for many tasks, a few at a time. Each result is delivered as it arrives.
    public func refresh(_ tasks: [String], concurrency: Int = 6, each: @escaping @Sendable (String, CrewState?) async -> Void) async {
        var iterator = tasks.makeIterator()
        await withTaskGroup(of: Void.self) { group in
            func next() { if let task = iterator.next() { group.addTask { await each(task, await self.crewState(task)) } } }
            for _ in 0..<max(1, concurrency) { next() }
            while await group.next() != nil { next() }
        }
    }
    public func peek(_ task: String, lines: Int = 40) async -> String {
        let result = await Shell.run(script("fm-peek.sh"), [task, String(lines)], env: env, timeout: 20)
        return result.ok ? result.output : (result.error.isEmpty ? "No pane output." : result.error)
    }
    public enum Verb: String, Sendable { case interrupt, exit }
    public func control(_ task: String, _ verb: Verb) async -> ExecResult {
        await Shell.run(script("fm-control.sh"), [task, verb.rawValue], env: env, timeout: 90)
    }
    /// Relaunch needs a note: the replacement agent inherits the worktree but none of the conversation.
    public func relaunch(_ task: String, note: String) async -> ExecResult {
        await Shell.run(script("fm-control.sh"), [task, "relaunch", "--note", note], env: env, timeout: 300)
    }
    public var controlText: String { (try? String(contentsOfFile: script("fm-control.sh"), encoding: .utf8)) ?? "" }
    public var supportsPrompt: Bool { WorkerVerbs.supports("prompt", controlScript: controlText) }
    public var supportsAnswer: Bool { WorkerVerbs.supports("answer", controlScript: controlText) }
    public func prompt(_ task: String) async -> WorkerPrompt? {
        guard supportsPrompt else { return nil }
        let result = await Shell.run(script("fm-control.sh"), [task, "prompt"], env: env, timeout: 30)
        return result.ok ? WorkerPrompt.parse(result.output) : nil
    }
    /// `answer <option> --expect-prompt-sha <sha>`: the verb refuses when the prompt on screen is no longer the one the captain read.
    public func answer(_ task: String, option: String, sha: String) async -> ExecResult {
        await Shell.run(script("fm-control.sh"), [task, "answer", option, "--expect-prompt-sha", sha], env: env, timeout: 60)
    }

    /// Open the worker's terminal pane (herdr workspace and tab focus) or its local copy in the editor.
    public func openTerminal(_ meta: WorkerMeta) async -> ExecResult {
        guard meta.backend == "herdr", let workspace = meta.herdrWorkspace, let tab = meta.herdrTab else { return ExecResult(status: 1, output: "", error: "No terminal pane is recorded for this worker.", timedOut: false) }
        let session = meta.herdrSession.map { ["--session", $0] } ?? []
        _ = await Shell.run("/opt/homebrew/bin/herdr", session + ["workspace", "focus", workspace], timeout: 15)
        return await Shell.run("/opt/homebrew/bin/herdr", session + ["tab", "focus", tab], timeout: 15)
    }
    public func openEditor(_ worktree: String) async -> ExecResult {
        for editor in ["/opt/homebrew/bin/code", "/usr/local/bin/code", "/usr/local/bin/cursor"] where FileManager.default.isExecutableFile(atPath: editor) {
            return await Shell.run(editor, [worktree], timeout: 15)
        }
        return await Shell.run("/usr/bin/open", [worktree], timeout: 15)
    }
}
