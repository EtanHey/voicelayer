import AppKit
import ApplicationServices
func attr(_ e:AXUIElement,_ key:String)->CFTypeRef?{var v:CFTypeRef?;return AXUIElementCopyAttributeValue(e,key as CFString,&v) == .success ? v:nil}
func strings(_ e:AXUIElement,_ depth:Int=0)->[String]{guard depth<12 else{return []};let own=["AXTitle","AXDescription","AXValue"].compactMap{attr(e,$0) as? String};let children=attr(e,"AXChildren") as? [AXUIElement] ?? [];return own+children.flatMap{strings($0,depth+1)}}
let owners=Set(["com.apple.UserNotificationCenter","com.apple.SecurityAgent","com.apple.CoreServicesUIAgent","com.apple.coreautha","com.voicelayer.voicebar.uie2e"])
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
print(String(decoding:try JSONSerialization.data(withJSONObject:["axTrusted":AXIsProcessTrusted(),"prompts":prompts],options:[.sortedKeys]),as:UTF8.self))
exit(prompts.isEmpty && AXIsProcessTrusted() ? 0:2)
