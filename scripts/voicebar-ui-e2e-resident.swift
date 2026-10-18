import AppKit
import ApplicationServices
let args=CommandLine.arguments
func fail(_ s:String)->Never {fputs(s+"\n",stderr);exit(2)}
guard (3...4).contains(args.count),let pid=Int32(args[1]) else{fail("usage: resident-control PID read (mutations refused)")}
let mode=args[2]
// The installed resident exposes no causal/generation-bound Settings ownership.
// Reject before activation, menu/AX presses, permission checks or window inspection.
guard mode=="read" else{fail("Settings causal/lifecycle ownership NOT_PROVEN; mutation refused before dispatch")}
guard AXIsProcessTrusted() else{fail("AX not trusted; never prompt")}
guard let resident=NSRunningApplication(processIdentifier:pid),resident.bundleURL?.path=="/Applications/VoiceBar.app" else{fail("Resident identity mismatch")}
func attr(_ e:AXUIElement,_ key:String)->CFTypeRef?{var v:CFTypeRef?;return AXUIElementCopyAttributeValue(e,key as CFString,&v) == .success ? v:nil}
func string(_ e:AXUIElement,_ key:String)->String{attr(e,key) as? String ?? ""}
func children(_ e:AXUIElement)->[AXUIElement]{attr(e,"AXChildren") as? [AXUIElement] ?? []}
func walk(_ e:AXUIElement,_ depth:Int=0)->[AXUIElement]{guard depth<16 else{return []};return [e]+children(e).flatMap{walk($0,depth+1)}}
let app=AXUIElementCreateApplication(pid)
func windows()->[AXUIElement]{guard let result=attr(app,"AXWindows") as? [AXUIElement] else{fail("AX window evidence unreadable")};return result}
func cgWindows(_ options:CGWindowListOption)->[[String:Any]] {
 guard let rows=CGWindowListCopyWindowInfo(options,kCGNullWindowID) as? [[String:Any]] else{fail("CG window evidence unreadable")}
 return rows.filter{($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid}
}
func settingsWindowId()->Int? {
 let settings=windows().filter{string($0,"AXTitle")=="VoiceBar Settings"}
 guard !settings.isEmpty else{return nil}
 let rows=cgWindows(.optionAll).filter{($0[kCGWindowName as String] as? String)=="VoiceBar Settings"}
 guard settings.count==1,rows.count==1,let number=rows[0][kCGWindowNumber as String] as? Int else{fail("Settings window identity unreadable")}
 return number
}
Thread.sleep(forTimeInterval:0.35)
let labels=windows().flatMap{walk($0)}.map{ e in ["role":string(e,"AXRole"),"title":string(e,"AXTitle"),"description":string(e,"AXDescription"),"value":string(e,"AXValue")]}.filter{!$0.values.allSatisfy{$0.isEmpty}}
let screenWindows = cgWindows([.optionOnScreenOnly, .excludeDesktopElements]).filter {
    ((($0[kCGWindowBounds as String] as? [String: Any])?["Width"] as? NSNumber)?.doubleValue ?? 0) > 0 &&
    ((($0[kCGWindowBounds as String] as? [String: Any])?["Height"] as? NSNumber)?.doubleValue ?? 0) > 0
}.map { ["number": $0[kCGWindowNumber as String] ?? 0, "bounds": $0[kCGWindowBounds as String] ?? [:], "layer": $0[kCGWindowLayer as String] ?? NSNull()] }
let windowId=settingsWindowId()
let data=try JSONSerialization.data(withJSONObject:["pid":pid,"action":mode,"nodes":labels,"screenWindows":screenWindows,"settingsWindowId":windowId as Any? ?? NSNull()],options:[.prettyPrinted,.sortedKeys]);print(String(decoding:data,as:UTF8.self))
