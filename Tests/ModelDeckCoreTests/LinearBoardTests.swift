import XCTest
@testable import ModelDeckCore

final class LinearBoardTests: XCTestCase {
    func node(_ identifier: String, type: String = "started") -> String {
        #"{"id":"id-\#(identifier)","identifier":"\#(identifier)","title":"Ticket \#(identifier)","url":"https://linear.app/x/issue/\#(identifier)","updatedAt":"2026-10-30T12:00:00.000Z","state":{"name":"In Review","type":"\#(type)"}}"#
    }
    func response(_ nodes: [String]) -> Data {
        Data(#"{"data":{"viewer":{"assignedIssues":{"nodes":[\#(nodes.joined(separator: ","))]}}}}"#.utf8)
    }
    func testParsesOpenTicketsAndDropsClosedOnes() throws {
        let tickets = try LinearBoard.parse(response([node("IN-1"), node("IN-2", type: "completed"), node("IN-3", type: "canceled"), node("IN-4", type: "unstarted")]))
        XCTAssertEqual(tickets.map(\.identifier), ["IN-1", "IN-4"])
        XCTAssertEqual(tickets[0].state, "In Review")
        XCTAssertEqual(tickets[0].url.absoluteString, "https://linear.app/x/issue/IN-1")
        XCTAssertEqual(tickets[0].updatedAt, ISO8601DateFormatter().date(from: "2026-10-30T12:00:00Z"))
    }
    func testEmptyListIsZeroTickets() throws {
        XCTAssertEqual(try LinearBoard.parse(response([])), [])
    }
    func testMissingFieldIsAnErrorNotZeroTickets() {
        XCTAssertThrowsError(try LinearBoard.parse(response([#"{"id":"a","identifier":"IN-9","title":"t"}"#])))
        XCTAssertThrowsError(try LinearBoard.parse(Data(#"{"data":{"viewer":null}}"#.utf8)))
        XCTAssertThrowsError(try LinearBoard.parse(Data("not json".utf8)))
    }
    func testGraphQLErrorIsSurfaced() {
        XCTAssertThrowsError(try LinearBoard.parse(Data(#"{"errors":[{"message":"Authentication required"}]}"#.utf8))) { error in
            XCTAssertEqual(error.localizedDescription, "Authentication required")
        }
    }
    func testNonHTTPSURLIsRejected() {
        let bad = #"{"id":"a","identifier":"IN-9","title":"t","url":"javascript:alert(1)","updatedAt":"2026-10-30T12:00:00.000Z","state":{"name":"Todo","type":"unstarted"}}"#
        XCTAssertThrowsError(try LinearBoard.parse(response([bad])))
    }
}
