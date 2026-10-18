import AppKit
import ApplicationServices
func attr(_ e:AXUIElement,_ key:String)->CFTypeRef?{var v:CFTypeRef?;return AXUIElementCopyAttributeValue(e,key as CFString,&v) == .success ? v:nil}
func strings(_ e:AXUIElement,_ depth:Int=0)->[String]{guard depth<12 else{return []};let own=["AXTitle","AXDescription","AXValue"].compactMap{attr(e,$0) as? String};let children=attr(e,"AXChildren") as? [AXUIElement] ?? [];return own+children.flatMap{strings($0,depth+1)}}

// BEGIN FOREIGN MODALS
/// One on-screen window observed read-only (CGWindowList + AX); nothing here ever presses or dismisses.
struct ObservedWindow { let owner: String; let pid: Int32; let title: String; let frame: CGRect; let modal: Bool; let sheet: Bool }
let qaBundle = "com.voicelayer.voicebar.uie2e"
// System agents whose any on-screen window is a modal over the run (run-03: Gatekeeper's
// "downloaded from the Internet" dialog sat on screen undetected). Real bundle IDs, compared
// case-insensitively: CoreServicesUIAgent is com.apple.coreservices.uiagent, coreautha is
// com.apple.LocalAuthentication.UIAgent.
let systemModalOwners: Set<String> = ["com.apple.coreservices.uiagent", "com.apple.coreservicesuiagent",
    "com.apple.securityagent", "com.apple.usernotificationcenter", "com.apple.coreautha",
    "com.apple.localauthentication.uiagent"]
func isSystemModalOwner(_ owner: String) -> Bool { systemModalOwners.contains(owner.lowercased()) }
/// Foreign modals: any system-agent window anywhere, or another app's modal window/sheet over the
/// capture region. The QA app's own product alert is the fixture under test, never foreign.
func foreignModals(_ windows: [ObservedWindow], region: CGRect) -> [[String: Any]] {
    windows.compactMap { window in
        guard window.owner != qaBundle, !window.frame.isEmpty else { return nil }
        let source = isSystemModalOwner(window.owner) ? "system-owner"
            : !window.frame.intersects(region) ? nil : window.sheet ? "sheet" : window.modal ? "modal" : nil
        return source.map { ["owner": window.owner, "pid": Int(window.pid), "title": window.title, "source": $0] }
    }
}
/// The QA app's on-screen union, or the main display before it has any window.
func captureRegion(_ qaFrames: [CGRect], display: CGRect) -> CGRect {
    qaFrames.filter { !$0.isEmpty }.reduce(nil as CGRect?) { $0?.union($1) ?? $1 } ?? display
}
// END FOREIGN MODALS

func axFrame(_ e: AXUIElement) -> CGRect {
    var origin = CGPoint.zero, size = CGSize.zero
    if let p = attr(e, "AXPosition"), CFGetTypeID(p) == AXValueGetTypeID() { AXValueGetValue(p as! AXValue, .cgPoint, &origin) }
    if let s = attr(e, "AXSize"), CFGetTypeID(s) == AXValueGetTypeID() { AXValueGetValue(s as! AXValue, .cgSize, &size) }
    return CGRect(origin: origin, size: size)
}
func observedWindows() -> (windows: [ObservedWindow], region: CGRect) {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    func bundle(_ pid: Int32) -> String { NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "unknown" }
    func bounds(_ row: [String: Any]) -> CGRect {
        guard let dict = row[kCGWindowBounds as String] as? NSDictionary, let rect = CGRect(dictionaryRepresentation: dict) else { return .zero }
        return rect
    }
    // Fully transparent windows are not visible to the operator or the capture.
    let rows = list.filter { ($0[kCGWindowAlpha as String] as? Double ?? 1) > 0 }.map { row -> (Int32, CGRect, String) in
        ((row[kCGWindowOwnerPID as String] as? Int32) ?? 0, bounds(row), row[kCGWindowName as String] as? String ?? "")
    }
    let region = captureRegion(rows.filter { bundle($0.0) == qaBundle }.map(\.1), display: CGDisplayBounds(CGMainDisplayID()))
    var windows: [ObservedWindow] = []
    // System agents: every on-screen CG window, titled from AX where CG withholds the name.
    for (pid, frame, name) in rows where isSystemModalOwner(bundle(pid)) {
        let ax = AXUIElementCreateApplication(pid); AXUIElementSetMessagingTimeout(ax, 0.3)
        let title = name.isEmpty ? ((attr(ax, "AXWindows") as? [AXUIElement] ?? []).flatMap { strings($0) }.first { !$0.isEmpty } ?? "") : name
        windows.append(ObservedWindow(owner: bundle(pid), pid: pid, title: title, frame: frame, modal: true, sheet: false))
    }
    // Other apps: AX only for those with an on-screen window over the capture region.
    let candidates = Set(rows.filter { $0.1.intersects(region) && !isSystemModalOwner(bundle($0.0)) && bundle($0.0) != qaBundle }.map(\.0))
    for pid in candidates {
        let ax = AXUIElementCreateApplication(pid); AXUIElementSetMessagingTimeout(ax, 0.3)
        for w in attr(ax, "AXWindows") as? [AXUIElement] ?? [] {
            let title = attr(w, "AXTitle") as? String ?? ""
            if attr(w, "AXModal") as? Bool == true {
                windows.append(ObservedWindow(owner: bundle(pid), pid: pid, title: title, frame: axFrame(w), modal: true, sheet: false))
            }
            for child in attr(w, "AXChildren") as? [AXUIElement] ?? [] where attr(child, "AXRole") as? String == "AXSheet" {
                windows.append(ObservedWindow(owner: bundle(pid), pid: pid, title: title, frame: axFrame(child), modal: true, sheet: true))
            }
        }
    }
    return (windows, region)
}

let owners=Set(["com.apple.UserNotificationCenter","com.apple.SecurityAgent","com.apple.CoreServicesUIAgent","com.apple.coreservices.uiagent","com.apple.coreautha","com.apple.LocalAuthentication.UIAgent","com.voicelayer.voicebar.uie2e"])
var prompts:[[String:Any]]=[]
for app in NSWorkspace.shared.runningApplications where owners.contains(app.bundleIdentifier ?? "") {
 let ax=AXUIElementCreateApplication(app.processIdentifier)
 for w in attr(ax,"AXWindows") as? [AXUIElement] ?? [] {
  let labels=strings(w);let text=labels.joined(separator:" ").lowercased()
  if labels.contains(where:{$0=="Allow" || $0=="Don’t Allow" || $0=="Don't Allow"}) || text.contains("would like to access") || text.contains("to access your microphone") {
   prompts.append(["pid":app.processIdentifier,"owner":app.bundleIdentifier ?? "","labels":labels])
  }
 }
}
let observed = observedWindows()
let modals = foreignModals(observed.windows, region: observed.region)
let region = observed.region
print(String(decoding:try JSONSerialization.data(withJSONObject:["axTrusted":AXIsProcessTrusted(),"prompts":prompts,"modals":modals,
    "modalRegion":[region.minX, region.minY, region.width, region.height]],options:[.sortedKeys]),as:UTF8.self))
// Exit status keeps its prompt/AX meaning; the supervisor refuses on any reported modal.
exit(prompts.isEmpty && AXIsProcessTrusted() ? 0:2)
