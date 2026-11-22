import AppKit
import SwiftUI
import Vision
import ModelDeckCore

/// `--ui-selftest --feed F --inbox I` (see scripts/ui-selftest.sh): hosts the Bridge offscreen and clicks its buttons with real mouse events.
/// The feed must be fresh: a stale feed disables the buttons on purpose.
@MainActor enum UISelfTest {
    static func run() -> Int32 {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        _ = application.accessibilitySetOverrideValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        _ = application.accessibilitySetOverrideValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXManualAccessibility"))
        let store = DeckStore()
        guard let feed = try? CompanionFeed.read(path: CompanionSettings.feedPath) else { print("cannot read feed"); return 2 }
        store.companionFeed = feed
        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 1100, height: 1500), styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: CompanionView().environmentObject(store).frame(width: 1100).background(DeckTheme.background))
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        spin(1.5)
        var failures: [String] = []
        func check(_ ok: Bool, _ text: String) { print((ok ? "PASS " : "FAIL ") + text); if !ok { failures.append(text) } }
        func clicks() -> [[String: String]] {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: CompanionSettings.inboxPath))?.filter { $0.hasSuffix(".json") }.sorted() ?? []
            return names.compactMap { try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CompanionSettings.inboxPath).appendingPathComponent($0))) as? [String: String] }
        }
        func click(at point: NSPoint) {
            let base = host.convert(point, to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(with: type, location: base, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { window.sendEvent(event) }
            }
            spin(0.6)
        }
        func press(_ label: String, nth: Int = 0) -> Bool {
            for _ in 0..<3 {
                if let point = locate(label, nth: nth, in: host) { click(at: point); return true }
                spin(0.5)
            }
            return false
        }
        func detailsOpen() -> Bool { allText(in: host).contains { $0.contains("No dossier") || $0.contains("Dossier") } }
        func pressBack() -> Bool {
            guard let point = locate("<", nth: 0, in: host, prefix: true) else { return false }
            click(at: point); return true
        }
        func waitForClick(_ matches: @escaping ([String: String]) -> Bool) -> Bool {
            for _ in 0..<6 { if clicks().contains(where: matches) { return true }; spin(0.5) }
            return false
        }
        func has(_ label: String) -> Bool { locate(label, nth: 0, in: host) != nil }
        /// Puts text into the editor nearest to a point, as typing would (the offscreen window is never key).
        func typeText(_ text: String, near point: NSPoint) {
            func editors(_ view: NSView) -> [NSTextView] { (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(editors) }
            let all = editors(host)
            guard let target = all.min(by: { distance($0, point) < distance($1, point) }) else { print("no text view"); return }
            window.makeFirstResponder(target)
            target.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
            spin(0.5)
        }
        func distance(_ view: NSTextView, _ point: NSPoint) -> CGFloat {
            let center = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: host)
            return hypot(center.x - point.x, center.y - point.y)
        }
        // Decisions tab: an option button sends its feed id and leaves the list in place.
        check(press("Ship now"), "found option button")
        check(waitForClick { $0["action_id"] == "dec-1.opt-1" && $0["target"] == "dec-1" }, "option click wrote dec-1.opt-1")
        check(!detailsOpen(), "detail pane stayed closed after the option click")
        _ = press("Defer one week") // disabled while the option is in flight: must not write
        check(clicks().filter { $0["action_id"] == "dec-1.opt-defer" }.isEmpty, "a second action on a busy card wrote nothing")
        // Free answer: with an option sent on the card, Send is disabled and writes nothing.
        if let label = locate("Something different, or add context", nth: 0, in: host) {
            let spot = NSPoint(x: label.x + 120, y: label.y + (host.isFlipped ? 50 : -50)); click(at: spot); typeText("free answer", near: spot)
            check(press("Send", nth: 0), "pressed Send on the free answer")
            check(!clicks().contains { $0["action_id"] == "dec-1.answer" }, "free answer waits while the option click is in flight")
            check(!detailsOpen(), "detail pane stayed closed after the free answer")
        } else { check(false, "found the free answer field") }
        // Add context stays possible while another action is in flight; the option click comes last.
        // Add context on the decision card opens an editor; typing and Send writes <ref>.add-context.
        check(press("Add context"), "pressed Add context on the decision card")
        if let cancel = locate("Cancel", nth: 0, in: host) {
            let spot = NSPoint(x: cancel.x + 60, y: cancel.y + (host.isFlipped ? -50 : 50)); click(at: spot); typeText("more context", near: spot)
            check(press("Send", nth: 1), "pressed Send in the Add context editor")
            check(waitForClick { $0["action_id"] == "dec-1.add-context" && $0["draft_text"] == "more context" }, "Add context wrote dec-1.add-context with the typed text")
        } else { check(false, "Add context opened its editor with Cancel") }
        check(!detailsOpen(), "detail pane stayed closed after Add context")
        // MR tab: action buttons run; the card itself does not open the detail pane.
        check(press("MRs and reviews (1)"), "opened the MR tab")
        check(press("Fix the threads"), "found the MR action button")
        check(waitForClick { $0["action_id"] == "row-mr-svc-12.fix-the-threads" && $0["target"] == "svc !12" }, "MR action wrote its feed id with the MR ref as target")
        check(!detailsOpen(), "detail pane stayed closed after the MR action click")
        // Tapping an empty part of the card does nothing; the title opens the details.
        if let title = locate("Add retry", nth: 0, in: host) {
            click(at: NSPoint(x: title.x + 400, y: title.y + (host.isFlipped ? 120 : -120)))
            check(!detailsOpen(), "a tap on the card body does not open the detail pane")
            click(at: title)
            if CommandLine.arguments.contains("--dump") { print("OCR:", allText(in: host)) }
            check(detailsOpen(), "the title opens the details")
            check(pressBack(), "back to the list")
        } else { check(false, "found the MR title") }
        // The outward post action only asks for confirmation; it never fires on its own.
        check(press("Post drafted reply"), "found the post action")
        check(clicks().filter { $0["action_id"] == "row-mr-svc-12.post-drafted-reply" }.isEmpty, "outward post action waits for confirmation instead of firing")
        print(failures.isEmpty ? "ALL PASS" : "FAILURES \(failures.count)")
        return failures.isEmpty ? 0 : 1
    }

    /// Finds visible text with Vision and returns its center in the view's coordinates; the app has no accessibility tree offscreen.
    static func locate(_ label: String, nth: Int, in view: NSView, prefix: Bool = false) -> NSPoint? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let image = rep.cgImage else { return nil }
        let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate; request.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: image).perform([request])
        let hits = (request.results ?? []).compactMap { observation -> (String, CGRect)? in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            return (text, observation.boundingBox)
        }.filter { prefix ? $0.0.hasPrefix(label) : $0.0.trimmingCharacters(in: .whitespaces).lowercased() == label.lowercased() || ($0.0.count < label.count + 4 && $0.0.lowercased().hasSuffix(label.lowercased())) }.sorted { $0.1.midY > $1.1.midY }
        guard hits.indices.contains(nth) else { return nil }
        let box = hits[nth].1, size = view.bounds.size
        let y = view.isFlipped ? (1 - box.midY) * size.height : box.midY * size.height
        return NSPoint(x: box.midX * size.width, y: y)
    }

    static func allText(in view: NSView) -> [String] {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return [] }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let image = rep.cgImage else { return [] }
        let request = VNRecognizeTextRequest(); request.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    }

    static func spin(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
}
