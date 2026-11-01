import Foundation

public enum CompanionNotifications {
    /// Urgent decisions of a fresh feed that were not announced yet. A stale feed never notifies.
    public static func pending(in feed: CompanionFeed, announced: Set<String>, now: Date = Date()) -> [CompanionFeed.Decision] {
        guard !feed.isStale(now: now) else { return [] }
        return feed.decisions.filter { $0.urgent && !announced.contains($0.id) }
    }
}

/// Sample feed for demo mode and tests; the same content lives in docs/companion/fixture-feed.json.
public enum CompanionFixture {
    public static func json(generatedAt: Date = Date()) -> String {
        """
        {"schema":"companion-feed.v1","generated_at":"\(ISO8601DateFormatter().string(from: generatedAt))","producer":"fixture",
         "decisions":[
          {"id":"dec-1","title":"Ship the parser change without a migration?","project":"example-service","why_now":"The release train closes today.",
           "options":[{"label":"Ship now","consequence":"Fast, but old rows stay unconverted."},{"label":"Wait for migration","consequence":"Safe, one day later."}],
           "recommendation":"Wait for migration","links":["https://example.com/decisions/1"],"urgent":true},
          {"id":"dec-2","title":"Rename the config key?","project":"example-tool","why_now":"Two callers use the old name.",
           "options":[{"label":"Rename","consequence":"One breaking change."},{"label":"Keep","consequence":"No change, naming stays odd."}],
           "recommendation":"Keep","links":[],"urgent":false}],
         "mrs":[
          {"ref":"svc !12","url":"https://example.com/svc/-/merge_requests/12","title":"Add retry to the client","role":"author","verdict":"notyet","label":"Fix pipeline",
           "next_owner":"you","pipeline":"failed","open_threads":2,
           "drafts":[{"id":"draft-1","target_url":"https://example.com/svc/-/merge_requests/12","text":"Rebased, pipeline green now."}],
           "actions":[{"id":"mr-12-rerun","label":"Rerun pipeline","outward":false},{"id":"mr-12-post","label":"Post reply","outward":true}]},
          {"ref":"tool !7","url":"https://example.com/tool/-/merge_requests/7","title":"Tidy the CLI flags","role":"reviewer","verdict":"close","label":"Approve",
           "next_owner":"you","pipeline":"passed","open_threads":0,"drafts":[],"actions":[{"id":"mr-7-review","label":"Prepare review","outward":false}]}],
         "tickets":[
          {"identifier":"IN-1","url":"https://example.com/issue/IN-1","title":"Retry on timeout","status":"In Review",
           "finish":{"step":"Merge svc !12","owner":"you"},"linked_mrs":["svc !12"],"actions":[{"id":"ticket-IN-1-next","label":"What is next?","outward":false}]}]}
        """
    }
}
