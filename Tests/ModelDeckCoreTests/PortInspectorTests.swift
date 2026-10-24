import XCTest
@testable import ModelDeckCore

final class PortInspectorTests: XCTestCase {
    func testPortsPreserveIPv6FamiliesOwnershipAndBoundUDP() {
        let result = PortInspector.parsePorts("p123\ncServer Name\nu501\nf1\ntIPv4\nPTCP\nn127.0.0.1:8000\nf2\ntIPv6\nPTCP\nn[::1]:8000\nf3\ntIPv6\nPTCP\nn[::1]:8000\np124\ncDiscovery\nu0\nf1\ntIPv4\nPUDP\nn*:5353\nf2\ntIPv4\nPUDP\nn*:*\nf3\ntIPv4\nPUDP\nn127.0.0.1:40000->127.0.0.1:53\n")
        XCTAssertEqual(result.count, 4)
        XCTAssertEqual(result.map(\.port), [8000, 8000, 5353, 40000])
        XCTAssertEqual(result[1].address, "[::1]:8000")
        XCTAssertEqual(result[0].process, "Server Name")
        XCTAssertEqual(result[2].userID, 0)
        XCTAssertEqual(result[2].transport, "UDP")
        XCTAssertEqual(result[3].address, "127.0.0.1:40000")
    }
    func testLoadedIdleDisabledAndUnloadedServicesAreDistinct() throws {
        let text = "gui/501 = {\nservices = {\n42 - app.running\n0 0 app.idle\n0 (pe) app.disabled\n}\ndisabled services = {\n\"app.disabled\" => disabled\n\"app.notloaded\" => enabled\n\"app.running\" => false\n\"app.old\" => true\n}\n}"
        let result = PortInspector.parseServices(text, domain: "gui/501")
        XCTAssertEqual(result.count, 5)
        let idle = try XCTUnwrap(result.first { $0.label == "app.idle" })
        XCTAssertTrue(idle.loaded); XCTAssertFalse(idle.running); XCTAssertNil(idle.disabled)
        XCTAssertEqual(idle.status, "In attesa")
        XCTAssertEqual(result.first { $0.label == "app.running" }?.pid, 42)
        XCTAssertEqual(result.first { $0.label == "app.disabled" }?.disabled, true)
        XCTAssertEqual(result.first { $0.label == "app.old" }?.disabled, true)
        XCTAssertEqual(result.first { $0.label == "app.notloaded" }?.loaded, false)
        XCTAssertTrue(PortInspector.parseServices("unrecognized output", domain: "system").isEmpty)
    }
}
