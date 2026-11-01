import AppKit
import SwiftUI
@testable import VoiceBarUI
import XCTest
@MainActor final class NativeFixScopeAXTests: XCTestCase {
 func testEachStockTabExposesRadioRoleAndSelectedValue() throws {
  var selection=SettingsHistoryScope.recording
  let binding=Binding(get:{selection},set:{selection=$0})
  let host=NSHostingView(rootView:SettingsHistoryScopePicker(selection:binding))
  host.frame=CGRect(x:0,y:0,width:274,height:40)
  let window=NSWindow(contentRect:host.frame,styleMask:.borderless,backing:.buffered,defer:true);window.contentView=host
  defer{window.contentView=nil}
  host.layoutSubtreeIfNeeded();RunLoop.current.run(until:Date().addingTimeInterval(0.3));host.layoutSubtreeIfNeeded()
  func find(_ view:NSView)->NSSegmentedControl? {if let c=view as? NSSegmentedControl{return c};return view.subviews.compactMap{find($0)}.first}
  let control=try XCTUnwrap(find(host))
  func elements(_ root:Any,depth:Int=0)->[any NSAccessibilityProtocol] {
   guard depth<20,let e=root as? any NSAccessibilityProtocol else{return []}
   return [e]+(e.accessibilityChildren() ?? []).flatMap{elements($0,depth:depth+1)}
  }
  let group=try XCTUnwrap(elements(control).first{$0.accessibilityRole() == .radioGroup})
  XCTAssertEqual(group.accessibilityRole(),.radioGroup)
  let tabs=elements(group).filter{$0.accessibilityRole() == .radioButton}
  XCTAssertEqual(tabs.count,3)
  guard tabs.count==3 else{return}
  var dump:[[String:Any]]=[]
  for (i,scope) in SettingsHistoryScope.allCases.enumerated() {
   control.selectedSegment=i;control.sendAction(control.action,to:control.target)
   XCTAssertEqual(selection,scope)
   let tab=tabs[i]
   XCTAssertEqual(tab.accessibilityRole(),.radioButton,scope.title)
   let value=tab.accessibilityValue()
   XCTAssertTrue(tab.isAccessibilitySelected() || (value as? NSNumber)?.intValue == 1,"Selected radio AX state/value: \(scope.title)")
   dump.append(["tab":scope.title,"groupRole":group.accessibilityRole()?.rawValue ?? "nil",
    "role":tab.accessibilityRole()?.rawValue ?? "nil","selectedValue":String(describing:value),"label":tab.accessibilityLabel() ?? "nil"])
  }
  if let output=ProcessInfo.processInfo.environment["NATIVEFIX_OUTPUT"] {try JSONSerialization.data(withJSONObject:dump,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:output).appendingPathComponent("stock-tab-ax.json"))}
 }
}
