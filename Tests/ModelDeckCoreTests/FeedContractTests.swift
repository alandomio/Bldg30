import Foundation
import Testing
@testable import ModelDeckCore

/// Feed contract (test A), app side: the app decodes every sample feed the producer tests validate against the schema
/// (wire/fixtures/feeds, see wire/tests/test_feed_contract.py), and rejects the invalid samples the schema rejects.
struct FeedContractTests {
    static let feeds = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("wire/fixtures/feeds")

    static func samples(in folder: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.hasSuffix(".feed.json") }.sorted().map { folder.appendingPathComponent($0) }
    }

    @Test func everySampleFeedDecodes() throws {
        let files = Self.samples(in: Self.feeds)
        #expect(files.count >= 2, "sample feeds missing in \(Self.feeds.path)")
        for file in files {
            do { _ = try CompanionFeed.decode(try Data(contentsOf: file)) }
            catch { Issue.record("\(file.lastPathComponent) does not decode: \(error)") }
        }
    }

    @Test func producerOutputWithUnknownPipelineAndThreadsDecodes() throws {
        let feed = try CompanionFeed.decode(try Data(contentsOf: Self.feeds.appendingPathComponent("producer.feed.json")))
        let mr = try #require(feed.mrs.first { $0.ref == "pi !1" })
        #expect(mr.pipeline == nil)
        #expect(mr.openThreads == nil)
        #expect(feed.decisions.first?.options.map(\.label) == ["Approve now", "Wait for the test"])
    }

    @Test func invalidSampleFeedsAreRejected() {
        let files = Self.samples(in: Self.feeds.appendingPathComponent("invalid"))
        #expect(files.count >= 2)
        for file in files {
            #expect(throws: (any Error).self, "\(file.lastPathComponent) must be rejected") { try CompanionFeed.decode(try Data(contentsOf: file)) }
        }
    }

    /// A row the schema rejects (unknown verdict or role) is skipped with a note; the rest of the feed stays usable.
    @Test func invalidRowsAreSkippedAndTheRestIsKept() throws {
        let files = Self.samples(in: Self.feeds.appendingPathComponent("invalid-rows"))
        #expect(files.count >= 2)
        for file in files {
            let feed = try CompanionFeed.decode(try Data(contentsOf: file))
            let skipped = feed.skipped.filter { $0.hasPrefix("mrs[") }
            #expect(skipped.count == 1, "\(file.lastPathComponent): the bad row must be reported")
            #expect(feed.mrs.count == 1, "\(file.lastPathComponent): only the valid MR row stays")
            #expect(feed.decisions.count == 1 && feed.tickets.count == 1)
        }
    }
}
