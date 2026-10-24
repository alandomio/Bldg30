import Foundation
import Darwin

public struct ListeningPort: Identifiable, Sendable {
    public var id: String { "\(pid):\(transport):\(family):\(address)" }
    public let pid: Int32
    public let process: String
    public let userID: UInt32?
    public let transport: String
    public let family: String
    public let address: String
    public let port: UInt16
}

public struct LaunchService: Identifiable, Sendable {
    public var id: String { domain + "/" + label }
    public let domain: String
    public let label: String
    public let pid: Int32?
    public let loaded: Bool
    public let disabled: Bool?
    public var running: Bool { pid != nil }
    public var status: String {
        if disabled == true { return running ? "In esecuzione · disabilitato" : "Disabilitato" }
        return running ? "In esecuzione" : loaded ? "In attesa" : "Non caricato"
    }
}

public struct PortInspectorSnapshot: Sendable {
    public let ports: [ListeningPort]
    public let services: [LaunchService]
    public let errors: [String]
    public init(ports: [ListeningPort], services: [LaunchService], errors: [String] = []) { self.ports = ports; self.services = services; self.errors = errors }
}

public enum PortInspector {
    private struct Output: Sendable { let text: String; let status: Int32; let limited: Bool }
    private static func capture(_ executable: String, _ arguments: [String]) async -> Output {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardOutput = pipe; process.standardError = pipe; process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return Output(text: "", status: -1, limited: false) }
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + 5)
        timer.setEventHandler { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        timer.resume()
        defer { timer.cancel() }
        var data = Data(), limited = false
        while let chunk = try? pipe.fileHandleForReading.read(upToCount: 32_768), !chunk.isEmpty {
            if Task.isCancelled || data.count + chunk.count > 1_000_000 {
                limited = true; if process.isRunning { process.terminate() }; break
            }
            data.append(chunk)
        }
        process.waitUntilExit()
        return Output(text: String(decoding: data, as: UTF8.self), status: process.terminationStatus, limited: limited)
    }
    public static func read() async -> PortInspectorSnapshot {
        async let tcp = capture("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-FpcuPtn"])
        async let udp = capture("/usr/sbin/lsof", ["-nP", "-iUDP", "-FpcuPtn"])
        async let user = capture("/bin/launchctl", ["print", "gui/\(geteuid())"])
        async let system = capture("/bin/launchctl", ["print", "system"])
        let output = await (tcp, udp, user, system)
        var errors: [String] = []
        if output.0.limited || output.1.limited || output.0.status < 0 || output.1.status < 0 || output.0.status > 1 || output.1.status > 1 { errors.append("Lettura delle porte incompleta o non disponibile.") }
        if output.2.status != 0 || output.2.limited { errors.append("Servizi utente: lettura incompleta o non disponibile.") }
        if output.3.status != 0 || output.3.limited { errors.append("Servizi di sistema: lettura incompleta o non disponibile.") }
        let ports = parsePorts(output.0.text) + parsePorts(output.1.text)
        let services = parseServices(output.2.text, domain: "gui/\(geteuid())") + parseServices(output.3.text, domain: "system")
        return PortInspectorSnapshot(ports: ports.sorted { $0.port == $1.port ? $0.id < $1.id : $0.port < $1.port }, services: services.sorted { $0.id < $1.id }, errors: errors)
    }
    public static func parsePorts(_ text: String) -> [ListeningPort] {
        var pid: Int32?, name = "", uid: UInt32?, transport = "", family = ""
        var seen = Set<String>(), ports: [ListeningPort] = []
        for line in text.split(separator: "\n") {
            guard let field = line.first else { continue }; let value = String(line.dropFirst())
            switch field {
            case "p": pid = Int32(value); name = ""; uid = nil; transport = ""; family = ""
            case "c": name = value
            case "u": uid = UInt32(value)
            case "f": transport = ""; family = ""
            case "P": transport = value
            case "t": family = value
            case "n":
                let local = value.components(separatedBy: "->")[0]
                guard let pid, ["TCP", "UDP"].contains(transport), let colon = local.lastIndex(of: ":"), let port = UInt16(local[local.index(after: colon)...]), port > 0 else { continue }
                let item = ListeningPort(pid: pid, process: name, userID: uid, transport: transport, family: family, address: local, port: port)
                if seen.insert(item.id).inserted { ports.append(item) }
            default: continue
            }
        }
        return ports
    }
    public static func parseServices(_ text: String, domain: String) -> [LaunchService] {
        var section = "", loaded: [String: Int32?] = [:], overrides: [String: Bool] = [:]
        for line in text.split(separator: "\n") {
            let value = line.trimmingCharacters(in: .whitespaces)
            if value == "services = {" { section = "loaded"; continue }
            if value == "disabled services = {" { section = "overrides"; continue }
            if value == "}" { section = ""; continue }
            if section == "loaded" {
                let parts = value.split(whereSeparator: \.isWhitespace)
                guard parts.count >= 3, let number = Int32(parts[0]) else { continue }
                let label = parts.dropFirst(2).joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                loaded[label] = .some(number > 0 ? number : nil)
            } else if section == "overrides", value.hasPrefix("\""), let end = value.dropFirst().firstIndex(of: "\"") {
                let label = String(value[value.index(after: value.startIndex)..<end])
                let state = value[value.index(after: end)...].replacingOccurrences(of: "=>", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                if ["true", "disabled"].contains(state) { overrides[label] = true }
                else if ["false", "enabled"].contains(state) { overrides[label] = false }
            }
        }
        return Set(loaded.keys).union(overrides.keys).sorted().map { label in
            LaunchService(domain: domain, label: label, pid: loaded[label] ?? nil, loaded: loaded.keys.contains(label), disabled: overrides[label])
        }
    }
}
