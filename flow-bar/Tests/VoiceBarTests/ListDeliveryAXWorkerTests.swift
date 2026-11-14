import XCTest
import ApplicationServices
@testable import VoiceBar
@testable import VoiceBarUI

@MainActor final class ListDeliveryAXWorkerTests: XCTestCase {
    func testCaptureAcceptsMissingSubroleAndRejectsPresentSecureSubrole() async {
        for secure in [false, true] {
            let element = AXUIElementCreateApplication(12345)
            let worker = ListDeliveryAXWorker(pid: 12345, focusReader: { element },
                subroleReader: { _ in secure ? kAXSecureTextFieldSubrole as String : nil }, valueReader: { _ in "" })
            let done = expectation(description: "capture")
            let m = ListDeliveryMachine()
            m.deliver("1. Alpha\n2. Beta", env: .init(worker: { request, _ in
                worker.request(request) { reply in
                    XCTAssertEqual(reply.same, !secure); XCTAssertEqual(reply.value, secure ? nil : "")
                    done.fulfill()
                }
            }, guardTarget: { false }, post: { _ in XCTFail(); return .failed })) { _ in }
            await fulfillment(of: [done], timeout: 1)
            m.close()
        }
    }
    func testChromiumNoFocusEnablesManualAccessibilityOnceAndRetries() async {
        let element = AXUIElementCreateApplication(12345)
        var reads = 0, enables = 0
        let worker = ListDeliveryAXWorker(pid: 12345, focusReader: { reads += 1; return reads == 1 ? nil : element },
            subroleReader: { _ in nil }, valueReader: { _ in "" }, chromium: { true },
            enableManualAccessibility: { enables += 1 })
        let done = expectation(description: "capture")
        let m = ListDeliveryMachine()
        m.deliver("1. Alpha\n2. Beta", env: .init(worker: { request, _ in
            worker.request(request) { reply in
                XCTAssertTrue(reply.same); XCTAssertEqual(reads, 2); XCTAssertEqual(enables, 1); done.fulfill()
            }
        }, guardTarget: { false }, post: { _ in XCTFail(); return .failed })) { _ in }
        await fulfillment(of: [done], timeout: 1)
        m.close()
    }
}
