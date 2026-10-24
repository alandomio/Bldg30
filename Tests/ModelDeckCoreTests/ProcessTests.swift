import XCTest
import Darwin
@testable import ModelDeckCore

final class ProcessTests: XCTestCase {
    func testCPUUsesNanosecondDeltasAndAllowsMultipleCores() {
        XCTAssertEqual(ProcessMonitor.percent(current: 5_000_000_000, previous: 1_000_000_000, elapsed: 2), 200)
        XCTAssertNil(ProcessMonitor.percent(current: 1, previous: nil, elapsed: 2))
        XCTAssertNil(ProcessMonitor.percent(current: 1, previous: 2, elapsed: 2))
        XCTAssertNil(ProcessMonitor.percent(current: 1, previous: 0, elapsed: 0))
    }
    func testResourceSortingSupportsBothDirectionsAndKeepsUnavailableValuesLast() {
        let processes = [
            process(pid: 1),
            process(pid: 2, cpu: 0, memory: 0, gpu: 0),
            process(pid: 3, cpu: 40, memory: 2_000_000_000, gpu: 70),
            process(pid: 4, cpu: 200, memory: 1_000_000_000, gpu: 20),
            process(pid: 5, cpu: 40, memory: 3_000_000_000, gpuClient: true)
        ]
        XCTAssertEqual(ProcessSort.cpu.sorted(processes).map(\.pid), [4, 3, 5, 2, 1])
        XCTAssertEqual(ProcessSort.cpu.sorted(processes, descending: false).map(\.pid), [2, 3, 5, 4, 1])
        XCTAssertEqual(ProcessSort.memory.sorted(processes).map(\.pid), [5, 3, 4, 2, 1])
        XCTAssertEqual(ProcessSort.memory.sorted(processes, descending: false).map(\.pid), [2, 4, 3, 5, 1])
        XCTAssertEqual(ProcessSort.gpu.sorted(processes).map(\.pid), [3, 4, 2, 1, 5])
        XCTAssertEqual(ProcessSort.gpu.sorted(processes, descending: false).map(\.pid), [2, 4, 3, 1, 5])
    }
    func testInvalidResourceCountersAreUnavailableRatherThanLargestOrSmallest() {
        let processes = [process(pid: 1, cpu: .nan, gpu: -.infinity), process(pid: 2, cpu: .infinity, gpu: -1), process(pid: 3, cpu: -1, gpu: .nan), process(pid: 4, cpu: 0, gpu: 0)]
        for sort in [ProcessSort.cpu, .gpu] {
            XCTAssertEqual(sort.sorted(processes).map(\.pid), [4, 1, 2, 3])
            XCTAssertEqual(sort.sorted(processes, descending: false).map(\.pid), [4, 1, 2, 3])
        }
    }
    func testHighUsageUsesOneCPUCoreAndPhysicalMemoryAndRequiresMeasuredGPU() throws {
        let total: UInt64 = 16_000_000_000
        let boundary = process(pid: 1, cpu: 80, memory: 1_600_000_000, gpu: 50)
        XCTAssertEqual(boundary.highUsageResources(totalMemory: total), [.cpu, .memory, .gpu])
        XCTAssertEqual(try XCTUnwrap(boundary.memoryPercent(totalMemory: total)), 10, accuracy: 0.001)
        let below = process(pid: 2, cpu: 79.9, memory: 1_599_000_000, gpu: 49.9)
        XCTAssertTrue(below.highUsageResources(totalMemory: total).isEmpty)
        XCTAssertEqual(process(pid: 3, cpu: 240).highUsageResources(totalMemory: total), [.cpu])
        XCTAssertTrue(process(pid: 4, gpuClient: true).highUsageResources(totalMemory: total).isEmpty)
        XCTAssertTrue(process(pid: 5, cpu: .infinity, gpu: .nan).highUsageResources(totalMemory: total).isEmpty)
        XCTAssertNil(boundary.memoryPercent(totalMemory: 0))
        XCTAssertEqual(boundary.highUsageResources(totalMemory: 0), [.cpu, .gpu])
        XCTAssertNil(process(pid: 6).memoryPercent(totalMemory: total))
    }
    func testMemoryBreakdownPartitionsTheSystemSampleWithoutSummingProcessMemory() throws {
        let memory = try XCTUnwrap(MemoryBreakdown(total: 48_000_000_000, used: 36_800_000_000, wired: 5_200_000_000, compressed: 4_800_000_000))
        XCTAssertEqual(memory.appAndServices, 26_800_000_000)
        XCTAssertEqual(memory.reusable, 11_200_000_000)
        XCTAssertEqual(memory.appAndServices + memory.wired + memory.compressed, memory.used)
        XCTAssertEqual(memory.used + memory.reusable, memory.total)
        XCTAssertEqual(memory.percent(memory.used), 76.6666667, accuracy: 0.001)
        var snapshot = SystemSnapshot()
        XCTAssertNil(snapshot.memoryBreakdown)
        snapshot.memorySampleAvailable = true
        XCTAssertNotNil(snapshot.memoryBreakdown)
    }
    func testMemoryBreakdownHandlesZeroCapacityAndInconsistentCounters() throws {
        XCTAssertNil(MemoryBreakdown(total: 0, used: 1, wired: 1, compressed: 1))
        let memory = try XCTUnwrap(MemoryBreakdown(total: 16, used: 20, wired: 18, compressed: 5))
        XCTAssertEqual(memory.used, 16)
        XCTAssertEqual(memory.wired, 16)
        XCTAssertEqual(memory.compressed, 0)
        XCTAssertEqual(memory.appAndServices, 0)
        XCTAssertEqual(memory.reusable, 0)
        let compressed = try XCTUnwrap(MemoryBreakdown(total: 16, used: 12, wired: 5, compressed: 10))
        XCTAssertEqual(compressed.compressed, 7)
    }
    func testMemoryGroupsCombineNestedAppHelpersAndKeepUnrelatedProcessesSeparate() throws {
        let processes = [
            process(pid: 1, memory: 100, path: "/Applications/Browser.app/Contents/MacOS/Browser"),
            process(pid: 2, memory: 250, path: "/Applications/Browser.app/Contents/Frameworks/Browser Helper.app/Contents/MacOS/Helper"),
            process(pid: 3, memory: 400, path: "/Users/test/Applications/Browser.app/Contents/MacOS/Browser"),
            process(pid: 4, memory: 50, path: "/usr/bin/helper", name: "Helper"),
            process(pid: 5, memory: 70, path: "/usr/bin/helper", name: "Helper")
        ]
        let groups = ProcessResourceGroup.groups(processes)
        XCTAssertEqual(groups.count, 4)
        XCTAssertEqual(groups.first?.memory, 400)
        let browser = try XCTUnwrap(groups.first { $0.bundlePath == "/Applications/Browser.app" })
        XCTAssertEqual(browser.name, "Browser")
        XCTAssertEqual(browser.memory, 350)
        XCTAssertEqual(browser.processes.map(\.pid), [1, 2])
        XCTAssertEqual(processes.filter { $0.resourceGroupID == browser.id }.map(\.pid), [1, 2])
        XCTAssertEqual(groups.filter { $0.bundlePath == nil }.count, 2)
        XCTAssertNil(process(pid: 6, path: "/tmp/example.appcache/helper").appBundlePath)
        XCTAssertNil(process(pid: 7, path: "relative.app/helper").appBundlePath)
    }
    func testMemoryGroupsKeepUnknownCountersUnknownAndMarkPartialTotals() throws {
        let appPath = "/Applications/Editor.app/Contents/MacOS/Editor"
        let groups = ProcessResourceGroup.groups([process(pid: 1, path: appPath), process(pid: 2, memory: 0, path: appPath), process(pid: 3)])
        let editor = try XCTUnwrap(groups.first)
        XCTAssertEqual(editor.name, "Editor")
        XCTAssertEqual(editor.memory, 0)
        XCTAssertEqual(editor.unavailableCount(for: .memory), 1)
        XCTAssertNil(groups.last?.memory)
        XCTAssertEqual(ProcessResourceGroup.groups([]).count, 0)
    }
    func testAppCPURankingCombinesHelpersAndNormalizesByAllCores() throws {
        let app = "/Applications/Inference.app/Contents/MacOS/Inference"
        let processes = [
            process(pid: 1, cpu: 160, memory: 400, path: app),
            process(pid: 2, cpu: 80, memory: 200, path: app),
            process(pid: 3, path: app),
            process(pid: 4, cpu: 250, memory: 100),
            process(pid: 5, cpu: .nan)
        ]
        let cpuGroups = ProcessResourceGroup.groups(processes, sortedBy: .cpu).filter { $0.isRelevant(for: .cpu) }
        XCTAssertEqual(cpuGroups.count, 2)
        XCTAssertEqual(cpuGroups.first?.value(for: .cpu), 250)
        let inference = try XCTUnwrap(cpuGroups.first { $0.bundlePath != nil })
        XCTAssertEqual(inference.value(for: .cpu), 240)
        XCTAssertEqual(inference.capacityPercent(for: .cpu, totalMemory: 0, cores: 12), 20)
        XCTAssertNil(inference.capacityPercent(for: .cpu, totalMemory: 0, cores: 0))
        XCTAssertEqual(inference.unavailableCount(for: .cpu), 1)
        XCTAssertEqual(ProcessResourceGroup.groups(processes, sortedBy: .memory).first?.id, inference.id)
        XCTAssertEqual(inference.capacityPercent(for: .memory, totalMemory: 1_000, cores: 12), 60)
        XCTAssertNil(inference.capacityPercent(for: .memory, totalMemory: 0, cores: 12))
    }
    func testGPURankingKeepsMeasuredZeroAndUnknownClientsDistinct() throws {
        let app = "/Applications/Renderer.app/Contents/MacOS/Renderer"
        let processes = [
            process(pid: 1, gpu: 20, gpuClient: true, path: app),
            process(pid: 2, gpu: 30, gpuClient: true, path: app),
            process(pid: 3, gpuClient: true, path: app),
            process(pid: 4, path: app),
            process(pid: 5, gpu: 65, gpuClient: true),
            process(pid: 6, gpu: 0, gpuClient: true),
            process(pid: 7, gpuClient: true),
            process(pid: 8),
            process(pid: 9, gpu: .infinity, gpuClient: true)
        ]
        let groups = ProcessResourceGroup.groups(processes, sortedBy: .gpu).filter { $0.isRelevant(for: .gpu) }
        XCTAssertEqual(groups.count, 5)
        XCTAssertEqual(groups.prefix(3).map { $0.value(for: .gpu) }, [65, 50, 0])
        let renderer = try XCTUnwrap(groups.first { $0.bundlePath != nil })
        XCTAssertEqual(renderer.unavailableCount(for: .gpu), 1)
        XCTAssertEqual(renderer.capacityPercent(for: .gpu, totalMemory: 0, cores: 0), 50)
        XCTAssertTrue(groups.suffix(2).allSatisfy { $0.value(for: .gpu) == nil })
        XCTAssertFalse(groups.contains { $0.processes.contains { $0.pid == 8 } })
        let noAttribution = ProcessResourceGroup.groups([process(pid: 10, gpuClient: true)], sortedBy: .gpu)
        XCTAssertTrue(try XCTUnwrap(noAttribution.first).isRelevant(for: .gpu))
        XCTAssertNil(noAttribution.first?.value(for: .gpu))
    }
    private func process(pid: Int32, cpu: Double? = nil, memory: UInt64? = nil, gpu: Double? = nil, gpuClient: Bool = false, path: String? = nil, name: String? = nil) -> RunningProcess {
        RunningProcess(id: .init(pid: pid, startedSeconds: 1, startedMicroseconds: 0), name: name ?? "Process \(pid)", path: path, userID: geteuid(), cpu: cpu, memory: memory, gpu: gpu, gpuClient: gpuClient, threads: nil)
    }
    func testTerminationRejectsChangedIdentityAndStopsOnlyOwnedTestChild() async throws {
        let child = Process(); child.executableURL = URL(fileURLWithPath: "/bin/sleep"); child.arguments = ["30"]
        try child.run()
        defer { if child.isRunning { child.terminate() } }
        let monitor = ProcessMonitor()
        let processes = await monitor.sample()
        let actual = try XCTUnwrap(processes.first { $0.pid == child.processIdentifier })
        let wrong = RunningProcess(id: .init(pid: actual.pid, startedSeconds: 0, startedMicroseconds: 0), name: actual.name, path: actual.path, userID: actual.userID, cpu: nil, memory: nil, gpu: nil, gpuClient: false, threads: nil)
        XCTAssertThrowsError(try ProcessMonitor.terminate(wrong, force: true))
        XCTAssertTrue(child.isRunning)
        try ProcessMonitor.terminate(actual, force: false)
        child.waitUntilExit()
        XCTAssertEqual(child.terminationReason, .uncaughtSignal)
        XCTAssertEqual(child.terminationStatus, SIGTERM)
    }
    func testSelfAndOtherUsersAreProtected() {
        let own = RunningProcess(id: .init(pid: getpid(), startedSeconds: 0, startedMicroseconds: 0), name: "ModelDeck", path: nil, userID: geteuid(), cpu: nil, memory: nil, gpu: nil, gpuClient: false, threads: nil)
        XCTAssertFalse(own.canTerminate)
        XCTAssertThrowsError(try ProcessMonitor.terminate(own, force: true))
        let other = RunningProcess(id: .init(pid: 100, startedSeconds: 0, startedMicroseconds: 0), name: "other", path: nil, userID: geteuid() &+ 1, cpu: nil, memory: nil, gpu: nil, gpuClient: false, threads: nil)
        XCTAssertFalse(other.canTerminate)
    }
}
