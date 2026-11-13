import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest

@MainActor
final class SettingsHistoryDestinationTests: XCTestCase {
    private final class Pages: @unchecked Sendable {
        private let lock = NSLock()
        private var revision = 0
        func advance() { lock.withLock { revision += 1 } }
        func asks() -> SettingsAskHistoryPage {
            let count = lock.withLock { revision + 2 }
            return .init(groups: [.init(dayKey: "2026-11-11", date: Date(timeIntervalSince1970: 0), entries:
                (0..<count).map { index in .init(id: "ask-\(index)", dayKey: "2026-11-11", askID: "ask-\(index)",
                    createdAt: Date(timeIntervalSince1970: Double(index)), questionText: "Synthetic question?",
                    questionAudioPath: nil, responseTranscript: "Synthetic answer.", responseAudioPath: nil) })], hasMore: false)
        }
    }
    private var windows: [NSWindow] = []
    private var root: URL!
    private var restoreAX: (() -> Void)?
    override func setUp() {
        super.setUp()
        MainActor.assumeIsolated {
            root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("h2-settings-\(UUID().uuidString)")
            try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let app = NSApplication.shared, selector = NSSelectorFromString("setAccessibilityEnhancedUserInterface:")
            if app.responds(to: selector) {
                let before = app.value(forKey: "accessibilityEnhancedUserInterface") as? Bool ?? false
                typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
                let setter = unsafeBitCast(app.method(for: selector), to: Setter.self)
                setter(app, selector, true); restoreAX = { setter(app, selector, before) }
            }
        }
    }
    override func tearDown() {
        MainActor.assumeIsolated {
            for window in windows { window.orderOut(nil); window.contentView = nil; window.close() }
            windows=[]; restoreAX?()
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: root.path+".speech-history-v1"))
        }
        super.tearDown()
    }
    private func speechID(_ index: Int) -> String { "2026-11-11T12-00-00-000Z-" + String(format: "%08d", index) }
    private func speech(_ index: Int) throws {
        let id = speechID(index)
        let directory=root.appendingPathComponent("2026-11-11/\(id)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let metadata: [String: Any] = ["schema_version":1,"source":"speak","id":id,
            "created_at":"2026-11-11T12:00:00Z","status":"completed",
            "speech":["state":"completed","generated":[["index":0,"text":"Synthetic speech."]]]]
        try JSONSerialization.data(withJSONObject: metadata).write(to: directory.appendingPathComponent("metadata.json"))
    }
    private func make(_ pages: Pages, request: SettingsTabRequest, search: String = "",
                      observe: @escaping (SettingsHistoryScope,String)->Void) -> AnyView {
        AnyView(SettingsView(hotkeyEnabled: true, missingPermissions: [], availableDevices:{[]}, selectedDeviceID:{nil},
            modelsStatus:{.loading}, onRefreshModelsStatus:{}, vocabularyRevision:{0},
            historyPage:{ _ in .init(groups:[],hasMore:false) }, askHistoryPage:{ _ in pages.asks() },
            historySearchPage:{ _,_ in .init(groups:[],hasMore:false) },
            askHistorySearchPage:{ _,_ in .init(groups:[],hasMore:false) }, searchPrewarm:{},
            initialTab:.history, tabRequest:request, speechHistoryRoot:root, initialAskHistorySearch:search)
            .environment(\.settingsHistoryDestinationObserver,observe))
    }
    private func host(_ view: AnyView) -> NSHostingView<AnyView> {
        let host=NSHostingView(rootView:view)
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:820,height:700),styleMask:[.titled],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false; window.contentView=host
        window.setFrameOrigin(NSPoint(x:-20000,y:-20000)); window.orderBack(nil); windows.append(window)
        return host
    }
    private func pause(_ duration: Double = 0.1) { RunLoop.main.run(until:Date().addingTimeInterval(duration)) }
    private func wait(_ condition:()->Bool) { let end=Date().addingTimeInterval(4); while !condition(),Date()<end { pause(0.02) } }
    private func elements(_ root: Any, depth: Int=0) -> [NSObject] {
        guard depth<40,let object=root as? NSObject,object.responds(to:NSSelectorFromString("accessibilityRole")) else {return []}
        var found=[object]
        if object.responds(to:NSSelectorFromString("accessibilityChildren")) {
            for child in object.value(forKey:"accessibilityChildren") as? [Any] ?? [] { found += elements(child,depth:depth+1) }
        }
        return found
    }
    private func selected(_ id: String, in host: NSView) -> Bool {
        guard let row=elements(host).first(where:{ $0.responds(to:NSSelectorFromString("accessibilityIdentifier")) && $0.value(forKey:"accessibilityIdentifier") as? String == id }) else {return false}
        if row.responds(to:NSSelectorFromString("isAccessibilitySelected")) { return row.value(forKey:"accessibilitySelected") as? Bool ?? false }
        return row.responds(to:NSSelectorFromString("accessibilityValue")) && (row.value(forKey:"accessibilityValue") as? NSNumber)?.boolValue == true
    }
    func testOpenRequestsSelectAndScrollOnceDespiteLaterListChanges() throws {
        for scope in [SettingsHistoryScope.ask,.speech] {
            let pages=Pages(); try speech(0)
            var scrolls:[String]=[]
            let id=scope == .ask ? "ask-1" : speechID(0)
            let request=SettingsTabRequest(tab:.history,historyDestination:.init(scope:scope,entryID:id),id:1)
            let host=host(make(pages,request:request){ scope,id in scrolls.append("\(scope.rawValue):\(id)") })
            wait { !scrolls.isEmpty }; pause(0.3)
            XCTAssertTrue(selected("history-\(scope.rawValue)-\(id)",in:host),"Settings selects the requested row")
            XCTAssertEqual(scrolls,["\(scope.rawValue):\(id)"],"one open request scrolls exactly once")
            pages.advance(); try speech(scope == .ask ? 1 : 2)
            NotificationCenter.default.post(name:.voiceBarHistoryArchiveDidChange,object:nil)
            pause(0.7)
            let freshID = scope == .ask ? "history-ask-ask-2" : "history-speech-" + speechID(2)
            XCTAssertNoThrow(try row(freshID, in: host), "the later archive page actually arrived")
            XCTAssertEqual(scrolls,["\(scope.rawValue):\(id)"],"archive reload or Load older must not snap to the old selection")
        }
    }
    private func press(_ element: NSObject) throws {
        let selector = NSSelectorFromString("accessibilityPerformPress")
        XCTAssertTrue(element.responds(to: selector))
        guard element.responds(to: selector) else { return }
        typealias Action = @convention(c) (AnyObject, Selector) -> Bool
        let action = unsafeBitCast(element.method(for: selector), to: Action.self)
        XCTAssertTrue(action(element, selector))
        pause(0.1)
    }
    private func row(_ id: String, in host: NSView) throws -> NSObject {
        try XCTUnwrap(elements(host).first { $0.responds(to: NSSelectorFromString("accessibilityIdentifier")) && $0.value(forKey: "accessibilityIdentifier") as? String == id })
    }
    func testDetailsClicksNeverCreateScrollRequests() throws {
        let pages=Pages(); try speech(0); var scrolls:[String]=[]
        let request=SettingsTabRequest(tab:.history,historyDestination:.init(scope:.speech,entryID:speechID(0)),id:1)
        let host=host(make(pages,request:request){ _,id in scrolls.append(id) })
        wait { !scrolls.isEmpty }; pause(0.2)
        let original=scrolls.count
        for label in ["Hide details","Details"] {
            let button=try XCTUnwrap(elements(host).first { $0.responds(to:NSSelectorFromString("accessibilityLabel")) && $0.value(forKey:"accessibilityLabel") as? String == label })
            try press(button)
        }
        XCTAssertEqual(scrolls.count,original,"ordinary Speech Details toggles never scroll the list")
    }
    func testInitialAskDestinationClearsSearchAndLaterSelectionClearsHighlight() throws {
        let pages=Pages(); var scrolls:[String]=[]
        let request=SettingsTabRequest(tab:.history,historyDestination:.init(scope:.ask,entryID:"ask-1"),id:1)
        let host=host(make(pages,request:request,search:"hidden"){ _,id in scrolls.append(id) })
        wait { selected("history-ask-ask-1",in:host) }
        XCTAssertTrue(selected("history-ask-ask-1",in:host),"an initial destination clears a query hiding the target")
        // A separate unfiltered host also proves the next row selection releases the destination highlight.
        let plain=self.host(make(pages,request:request){ _,_ in })
        wait { selected("history-ask-ask-1",in:plain) }
        try press(row("history-ask-ask-0",in:plain))
        XCTAssertFalse(selected("history-ask-ask-1",in:plain))
    }
    func testPendingTargetWaitsForItsPageAndIsConsumedOnce() throws {
        let pages=Pages(); var scrolls:[String]=[]
        let request=SettingsTabRequest(tab:.history,historyDestination:.init(scope:.ask,entryID:"ask-2"),id:1)
        let host=host(make(pages,request:request){ _,id in scrolls.append(id) })
        pause(0.3)
        XCTAssertTrue(scrolls.isEmpty,"do not scroll before the target is in a loaded page")
        pages.advance()
        NotificationCenter.default.post(name:.voiceBarHistoryArchiveDidChange,object:nil)
        wait { scrolls.contains("ask-2") }
        XCTAssertTrue(selected("history-ask-ask-2",in:host))
        XCTAssertEqual(scrolls,["ask-2"])
        pages.advance()
        NotificationCenter.default.post(name:.voiceBarHistoryArchiveDidChange,object:nil)
        pause(0.5)
        XCTAssertEqual(scrolls,["ask-2"],"a consumed pending request stays consumed")
    }

    func testRepeatedAskRequestClearsAnActiveSearchAndSelectsItsTarget() throws {
        let pages=Pages(); var scrolls:[String]=[]
        let first=SettingsTabRequest(tab:.history,id:1)
        let host=host(make(pages,request:first,search:"hidden"){ _,id in scrolls.append(id) })
        pause(0.5)
        let second=SettingsTabRequest(tab:.history,historyDestination:.init(scope:.ask,entryID:"ask-1"),id:2)
        host.rootView=make(pages,request:second,search:"hidden"){ _,id in scrolls.append(id) }
        wait { scrolls.contains("ask-1") }; pause(0.2)
        XCTAssertTrue(selected("history-ask-ask-1",in:host))
        XCTAssertEqual(scrolls,["ask-1"],"the onChange request also scrolls once")
    }
}
