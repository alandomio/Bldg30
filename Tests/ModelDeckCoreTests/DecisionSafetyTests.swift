import Foundation
import Testing
@testable import ModelDeckCore

struct DecisionSafetyTests {
    func option(_ label: String) -> CompanionFeed.Option {
        .init(label: label, consequence: "Effect", actionId: "choice.opt-1", outward: false, standard: nil)
    }

    @Test func clickBindsChoiceSeparatelyFromContext() throws {
        let choice = option("Discard the copy")
        for text in ["", "After review."] {
            let click = try #require(CompanionAnswer.click(decisionID: "choice", option: choice, optionIndex: 0, text: text))
            let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(click)) as? [String: Any])
            let selected = try #require(json["selected_option"] as? [String: Any])
            #expect(selected["label"] as? String == "Discard the copy")
            #expect(selected["consequence"] as? String == "Effect")
            #expect(selected["index"] as? Int == 0)
            #expect(click.draftText == (text.isEmpty ? nil : text))
        }
    }

    @Test func invalidOrNegatedRecommendationsHaveNoMatch() {
        for text in ["Do not merge; ask the owner for a new plan.", "Option 7; keep a backup while asking the owner.",
                     "Ask the owner.", "Merge or wait.", "Option 7; merge after review.", "Do not choose option 1.", "Option 1 or option 2.", "Option 1 or 2.", "Option -1; merge later.", "Don’t merge."] {
            let options = text.contains("backup") ? [option("Keep it"), option("Discard the copy")] : [option("Merge"), option("Wait")]
            #expect(CompanionRecommendation.optionIndex(recommendation: text, options: options) == nil, "\(text)")
            let recommended = CompanionRecommendation.optionIndex(recommendation: text, options: options)
            #expect(DecisionKeys.confirmed(selected: nil, recommended: recommended, count: options.count) == nil)
        }
        #expect(CompanionRecommendation.optionIndex(recommendation: "Merge", options: [option("Merge"), option("Merge")]) == nil)
    }

    @Test func enterRequiresAManualSelectionOrAnUnambiguousRecommendation() {
        #expect(DecisionKeys.confirmed(selected: nil, recommended: nil, count: 2) == nil)
        #expect(DecisionKeys.confirmed(selected: nil, recommended: 1, count: 2) == 1)
        #expect(DecisionKeys.confirmed(selected: 0, recommended: nil, count: 2) == 0)
        #expect(DecisionKeys.confirmed(selected: 0, recommended: 1, count: 2) == 0)
        #expect(DecisionKeys.confirmed(selected: 7, recommended: 1, count: 2) == nil)
        #expect(DecisionKeys.confirmed(selected: nil, recommended: 7, count: 2) == nil)
    }

    @Test func recommendationBlockIsInTheCardModelEvenWithoutAMatchingOption() throws {
        let json = #"{"id":"d","title":"T","project":"p","why_now":"Context","recommendation":"Ask the owner.","options":[{"label":"Merge","consequence":"Effect"}],"links":[],"urgent":false,"summary":[{"heading":"Status","text":"Waiting"}]}"#
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let decision = try decoder.decode(CompanionFeed.Decision.self, from: Data(json.utf8))
        #expect(decision.displayParts.map(\.heading) == ["Status", "Recommendation"])
        #expect(decision.displayParts.last?.text == "Ask the owner.")
        #expect(CompanionRecommendation.optionIndex(recommendation: decision.recommendation, options: decision.options) == nil)
    }
}
