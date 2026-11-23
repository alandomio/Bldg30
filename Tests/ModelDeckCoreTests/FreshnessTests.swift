import Foundation
import Testing
@testable import ModelDeckCore

/// Freshness (test D), app side: a feed older than 30 minutes is outdated, which the panel shows as a red badge and the
/// menu bar as a "Feed fermo" reading. The producer side is wire/tests/test_freshness.py.
struct FreshnessTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func outdatedStartsAfterThirtyMinutesAndStaleAfterFifteen() throws {
        let feed = try CompanionFeed.decode(Data(CompanionFixture.json(generatedAt: now).utf8))
        #expect(!feed.isStale(now: now.addingTimeInterval(15 * 60)))
        #expect(feed.isStale(now: now.addingTimeInterval(16 * 60)))
        #expect(!feed.isOutdated(now: now.addingTimeInterval(16 * 60)))
        #expect(!feed.isOutdated(now: now.addingTimeInterval(30 * 60)))
        #expect(feed.isOutdated(now: now.addingTimeInterval(30 * 60 + 1)))
    }

    @Test func menuBarShowsTheOutdatedFeedOnlyWhenOutdated() {
        var options = MenuBarOptions(); options.metrics = [.cpu]; options.layout = .detailed
        func render(_ outdated: Bool) -> MenuBarSummary {
            MenuBarSummary.render(options: options, snapshot: .init(), claude: .init(provider: "Claude", source: "x"), openAI: .init(provider: "OpenAI", source: "x"),
                                  feedOutdated: outdated, now: now)
        }
        #expect(!render(false).title.contains("Feed"))
        let outdated = render(true)
        #expect(outdated.title.contains("Feed fermo"))
        #expect(outdated.tooltip.contains("Feed fermo da oltre 30 min"))
    }
}
