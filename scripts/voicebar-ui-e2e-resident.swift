import AppKit
import ApplicationServices
let args=CommandLine.arguments
func fail(_ s:String)->Never {fputs(s+"\n",stderr);exit(2)}
guard args.count==3,let pid=Int32(args[1]) else{fail("usage: resident-control PID read|open|hide|show|close")}
let mode=args[2]
guard AXIsProcessTrusted() else{fail("AX not trusted; never prompt")}
guard let resident=NSRunningApplication(processIdentifier:pid),resident.bundleURL?.path=="/Applications/VoiceBar.app" else{fail("Resident identity mismatch")}
func attr(_ e:AXUIElement,_ key:String)->CFTypeRef?{var v:CFTypeRef?;return AXUIElementCopyAttributeValue(e,key as CFString,&v) == .success ? v:nil}
func string(_ e:AXUIElement,_ key:String)->String{attr(e,key) as? String ?? ""}
func children(_ e:AXUIElement)->[AXUIElement]{attr(e,"AXChildren") as? [AXUIElement] ?? []}
func walk(_ e:AXUIElement,_ depth:Int=0)->[AXUIElement]{guard depth<16 else{return []};return [e]+children(e).flatMap{walk($0,depth+1)}}
func press(_ e:AXUIElement){let r=AXUIElementPerformAction(e,kAXPressAction as CFString);guard r == .success else{fail("AX press failed \(r.rawValue)")}}
let app=AXUIElementCreateApplication(pid)
func windows()->[AXUIElement]{attr(app,"AXWindows") as? [AXUIElement] ?? []}
if mode=="open" {
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
let screenWindows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []).filter {
    ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid &&
    ((($0[kCGWindowBounds as String] as? [String: Any])?["Width"] as? NSNumber)?.doubleValue ?? 0) > 0 &&
    ((($0[kCGWindowBounds as String] as? [String: Any])?["Height"] as? NSNumber)?.doubleValue ?? 0) > 0
}.map { ["number": $0[kCGWindowNumber as String] ?? 0, "bounds": $0[kCGWindowBounds as String] ?? [:]] }
let data=try JSONSerialization.data(withJSONObject:["pid":pid,"action":mode,"nodes":labels,"screenWindows":screenWindows],options:[.prettyPrinted,.sortedKeys]);print(String(decoding:data,as:UTF8.self))
