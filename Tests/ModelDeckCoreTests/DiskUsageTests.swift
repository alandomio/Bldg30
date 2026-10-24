import XCTest
import Darwin
@testable import ModelDeckCore

final class DiskUsageTests: XCTestCase {
    func testScanRanksAllocatedSizesDeduplicatesHardLinksAndDoesNotFollowSymlinks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let external = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: external) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("models"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let weight = root.appendingPathComponent("models/weights.bin")
        try Data(repeating: 42, count: 128_000).write(to: weight)
        try Data(repeating: 7, count: 8_000).write(to: root.appendingPathComponent("small.bin"))
        try Data(repeating: 1, count: 300_000).write(to: external.appendingPathComponent("outside.bin"))
        try FileManager.default.linkItem(at: weight, to: root.appendingPathComponent("models/weights-link.bin"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("external"), withDestinationURL: external)
        let result = try await DiskUsageScanner.scan(root)
        XCTAssertEqual(result.entries.first?.url.lastPathComponent, "models")
        XCTAssertEqual(result.excludedCount, 1)
        XCTAssertFalse(result.largestFiles.contains { $0.url.lastPathComponent == "outside.bin" })
        XCTAssertEqual(result.largestFiles.count, 2)
        XCTAssertEqual(result.largestFiles.first?.bytes, allocated(weight))
        XCTAssertFalse(result.limited)
        XCTAssertEqual(result.inaccessibleCount, 0)
    }
    func testScanLimitsAndCancellationAreExplicit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data([1]).write(to: root.appendingPathComponent("one"))
        let limited = try await DiskUsageScanner.scan(root, maximumEntries: 0)
        XCTAssertTrue(limited.limited)
        XCTAssertEqual(limited.visitedCount, 0)
        XCTAssertTrue(limited.entries.first?.partial == true)
        let timed = try await DiskUsageScanner.scan(root, maximumSeconds: 0)
        XCTAssertTrue(timed.limited)
        let task = Task { () throws -> DiskUsageResult in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await DiskUsageScanner.scan(root)
        }
        do { _ = try await task.value; XCTFail("Cancelled scan completed") }
        catch is CancellationError { }
    }
    func testEmptyAndInvalidRootsAreDistinct() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let empty = try await DiskUsageScanner.scan(root)
        XCTAssertTrue(empty.entries.isEmpty)
        XCTAssertEqual(empty.bytes, 0)
        do { _ = try await DiskUsageScanner.scan(root.appendingPathComponent("missing")); XCTFail("Missing root accepted") }
        catch { XCTAssertFalse(error is CancellationError) }
    }
    private func allocated(_ url: URL) -> UInt64 {
        var info = stat(); XCTAssertEqual(lstat(url.path, &info), 0)
        return UInt64(info.st_blocks) * 512
    }
}
