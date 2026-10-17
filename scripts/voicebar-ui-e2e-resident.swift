import AppKit
import ApplicationServices
let args=CommandLine.arguments
func fail(_ s:String)->Never {fputs(s+"\n",stderr);exit(2)}
guard (3...4).contains(args.count),let pid=Int32(args[1]) else{fail("usage: resident-control PID read|open|hide|show|close [owned-settings-window-id]")}
let mode=args[2]
guard AXIsProcessTrusted() else{fail("AX not trusted; never prompt")}
guard let resident=NSRunningApplication(processIdentifier:pid),resident.bundleURL?.path=="/Applications/VoiceBar.app" else{fail("Resident identity mismatch")}
func attr(_ e:AXUIElement,_ key:String)->CFTypeRef?{var v:CFTypeRef?;return AXUIElementCopyAttributeValue(e,key as CFString,&v) == .success ? v:nil}
func string(_ e:AXUIElement,_ key:String)->String{attr(e,key) as? String ?? ""}
func children(_ e:AXUIElement)->[AXUIElement]{attr(e,"AXChildren") as? [AXUIElement] ?? []}
func walk(_ e:AXUIElement,_ depth:Int=0)->[AXUIElement]{guard depth<16 else{return []};return [e]+children(e).flatMap{walk($0,depth+1)}}
func press(_ e:AXUIElement){let r=AXUIElementPerformAction(e,kAXPressAction as CFString);guard r == .success else{fail("AX press failed \(r.rawValue)")}}
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
if ["hide","show","close"].contains(mode) {
 guard args.count==4,let expected=Int(args[3]),settingsWindowId()==expected else{fail("Owned Settings window changed; no action permitted")}
}
if mode=="open" {
 guard settingsWindowId()==nil else{fail("Settings already open; cannot claim a user-owned window")}
 resident.activate(options:[.activateIgnoringOtherApps])
 guard let raw=attr(app,"AXMenuBar") else{fail("No menu bar")}
 let bar=raw as! AXUIElement
 guard let item=children(bar).first(where:{string($0,"AXTitle")=="VoiceBar"}) else{fail("No VoiceBar menu")}
 press(item);Thread.sleep(forTimeInterval:0.2)
 guard let settings=walk(item).first(where:{string($0,"AXTitle")=="Settings…"}) else{fail("No Settings action")}
 press(settings)
} else if mode=="hide" || mode=="show" {
 let name=mode=="hide" ? "Hide VoiceBar for 1 hour":"Show VoiceBar"
 let nodes=windows().flatMap{walk($0)}
 guard let button=nodes.first(where:{string($0,"AXRole")=="AXButton" && [string($0,"AXTitle"),string($0,"AXDescription")].contains(name)}) else{fail("Missing own visibility button: "+name)}
 press(button)
} else if mode=="close" {
 guard let settings=windows().first(where:{string($0,"AXTitle")=="VoiceBar Settings"}),let raw=attr(settings,"AXCloseButton") else{fail("No operator Settings close button")}
 press(raw as! AXUIElement)
} else if mode != "read" {fail("Unknown mode")}
Thread.sleep(forTimeInterval:0.35)
let labels=windows().flatMap{walk($0)}.map{ e in ["role":string(e,"AXRole"),"title":string(e,"AXTitle"),"description":string(e,"AXDescription"),"value":string(e,"AXValue")]}.filter{!$0.values.allSatisfy{$0.isEmpty}}
let screenWindows = cgWindows([.optionOnScreenOnly, .excludeDesktopElements]).filter {
    ((($0[kCGWindowBounds as String] as? [String: Any])?["Width"] as? NSNumber)?.doubleValue ?? 0) > 0 &&
    ((($0[kCGWindowBounds as String] as? [String: Any])?["Height"] as? NSNumber)?.doubleValue ?? 0) > 0
}.map { ["number": $0[kCGWindowNumber as String] ?? 0, "bounds": $0[kCGWindowBounds as String] ?? [:], "layer": $0[kCGWindowLayer as String] ?? NSNull()] }
let data=try JSONSerialization.data(withJSONObject:["pid":pid,"action":mode,"nodes":labels,"screenWindows":screenWindows,"settingsWindowId":settingsWindowId() as Any? ?? NSNull()],options:[.prettyPrinted,.sortedKeys]);print(String(decoding:data,as:UTF8.self))
