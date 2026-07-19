import AppKit
import ApplicationServices
import Foundation
import VoiceBarUI

struct CommandModeSelectionSnapshot: Equatable {
    var value: String
    var selectedRange: NSRange
}

enum AXWriteDisposition: Equatable {
    case failed
    case appliedVerified
    case appliedUnverified
}

enum AXInsertionStrategy: Equatable {
    case valueRewrite
    case selectedTextStreaming(maxChunkUTF16Length: Int, interChunkDelay: TimeInterval)
}

enum AXSelectedTextStreamingDisposition: Equatable {
    case failedBeforeWrite
    case partiallyApplied(writtenChunkCount: Int, totalChunkCount: Int)
    case applied(writtenChunkCount: Int)

    var suppressesWholeTranscriptFallback: Bool {
        self != .failedBeforeWrite
    }
}

final class CommandModeAXHelper {
    private static let atomicValueRewriteBundleIdentifiers = Set([
        "com.cmuxterm.app",
    ])
    private static let selectedTextStreamingChunkMaxUTF16Length = 240
    private static let selectedTextStreamingInterChunkDelay: TimeInterval = 0.012
    private static let valueRewriteMaxTextUTF16Length = 2048
    private static let valueRewriteMaxFocusedValueUTF16Length = 32768
    private static let selectedTextStreamingQueue = DispatchQueue(
        label: "com.voicelayer.voicebar.ax-selected-text-streaming"
    )

    private let readSelection: () -> CommandModeSelectionSnapshot?
    private let writeValue: (String) -> Bool
    private let readBackValue: () -> String?
    private let writePasteboard: (String) -> Void
    private let postPasteShortcut: () -> Bool

    init(
        readSelection: @escaping () -> CommandModeSelectionSnapshot? = CommandModeAXHelper.readFocusedSelectionSnapshot,
        writeValue: @escaping (String) -> Bool = CommandModeAXHelper.writeFocusedValue,
        readBackValue: @escaping () -> String? = CommandModeAXHelper.readFocusedValue,
        writePasteboard: @escaping (String) -> Void = CommandModeAXHelper.writeStringToPasteboard,
        postPasteShortcut: @escaping () -> Bool = CommandModeAXHelper.postPasteShortcutLive
    ) {
        self.readSelection = readSelection
        self.writeValue = writeValue
        self.readBackValue = readBackValue
        self.writePasteboard = writePasteboard
        self.postPasteShortcut = postPasteShortcut
    }

    func applyReplacement(_ replacement: String) -> CommandModeApplyResult {
        guard let snapshot = readSelection() else {
            writePasteboard(replacement)
            return postPasteShortcut()
                ? .clipboardFallback("Pasted fallback")
                : .failed("No writable selection")
        }

        guard let swiftRange = Range(snapshot.selectedRange, in: snapshot.value) else {
            writePasteboard(replacement)
            return postPasteShortcut()
                ? .clipboardFallback("Pasted fallback")
                : .failed("Invalid selection range")
        }

        let updatedValue = snapshot.value.replacingCharacters(in: swiftRange, with: replacement)
        let disposition = Self.assessAXWrite(
            expectedValue: updatedValue,
            didWrite: writeValue(updatedValue),
            readBackValue: readBackValue()
        )
        guard disposition != .failed else {
            writePasteboard(replacement)
            return postPasteShortcut()
                ? .clipboardFallback("Pasted fallback")
                : .failed("AX write failed")
        }
        return .axVerified("Applied to selection")
    }

    static func captureFocusedInsertionHandler() -> AsyncDictationInsertionHandler? {
        guard AXIsProcessTrusted(), let element = focusedElement() else { return nil }
        return { text, completion in
            insertText(text, into: element) {
                DispatchQueue.main.async(execute: completion)
            }
        }
    }

    private static func focusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focused
        )
        guard status == .success, let focused else { return nil }
        return (focused as! AXUIElement)
    }

    private static func readFocusedSelectionSnapshot() -> CommandModeSelectionSnapshot? {
        guard let element = focusedElement(),
              let value = readAttributeString(element, attribute: kAXValueAttribute as CFString),
              let selectedRange = readSelectedRange(element)
        else {
            return nil
        }
        return CommandModeSelectionSnapshot(value: value, selectedRange: selectedRange)
    }

    private static func readFocusedValue() -> String? {
        guard let element = focusedElement() else { return nil }
        return readAttributeString(element, attribute: kAXValueAttribute as CFString)
    }

    private static func writeFocusedValue(_ value: String) -> Bool {
        guard let element = focusedElement() else { return false }
        return AXUIElementSetAttributeValue(
            element,
            kAXValueAttribute as CFString,
            value as CFTypeRef
        ) == .success
    }

    private static func insertText(
        _ text: String,
        into element: AXUIElement,
        completion: @escaping () -> Void
    ) -> Bool {
        let targetBundleIdentifier = targetBundleIdentifier(for: element)
        let earlyStrategy = insertionStrategy(
            text: text,
            focusedValueLength: 0,
            targetBundleIdentifier: targetBundleIdentifier
        )
        if case let .selectedTextStreaming(maxChunkUTF16Length, interChunkDelay) = earlyStrategy {
            return streamSelectedText(
                text,
                into: element,
                maxChunkUTF16Length: maxChunkUTF16Length,
                interChunkDelay: interChunkDelay,
                completion: completion
            )
        }

        guard let value = readAttributeString(element, attribute: kAXValueAttribute as CFString),
              let selectedRange = readSelectedRange(element),
              let swiftRange = Range(selectedRange, in: value)
        else {
            return false
        }

        let strategy = insertionStrategy(
            text: text,
            focusedValueLength: (value as NSString).length,
            targetBundleIdentifier: targetBundleIdentifier
        )
        if case let .selectedTextStreaming(maxChunkUTF16Length, interChunkDelay) = strategy {
            return streamSelectedText(
                text,
                into: element,
                maxChunkUTF16Length: maxChunkUTF16Length,
                interChunkDelay: interChunkDelay,
                completion: completion
            )
        }

        let updatedValue = value.replacingCharacters(in: swiftRange, with: text)
        let disposition = assessAXWrite(
            expectedValue: updatedValue,
            didWrite: AXUIElementSetAttributeValue(
                element,
                kAXValueAttribute as CFString,
                updatedValue as CFTypeRef
            ) == .success,
            readBackValue: readAttributeString(element, attribute: kAXValueAttribute as CFString)
        )
        guard disposition != .failed else {
            return false
        }

        let insertionLocation = selectedRange.location + (text as NSString).length
        _ = writeSelectedRange(NSRange(location: insertionLocation, length: 0), to: element)
        completion()
        return true
    }

    static func insertionStrategy(
        text: String,
        focusedValueLength: Int,
        targetBundleIdentifier: String?
    ) -> AXInsertionStrategy {
        if let targetBundleIdentifier,
           atomicValueRewriteBundleIdentifiers.contains(targetBundleIdentifier) {
            return .valueRewrite
        }
        let textLength = (text as NSString).length
        if textLength > valueRewriteMaxTextUTF16Length ||
            focusedValueLength > valueRewriteMaxFocusedValueUTF16Length {
            return .selectedTextStreaming(
                maxChunkUTF16Length: selectedTextStreamingChunkMaxUTF16Length,
                interChunkDelay: selectedTextStreamingInterChunkDelay
            )
        }
        return .valueRewrite
    }

    static func selectedTextChunks(
        for text: String,
        maxUTF16Length: Int
    ) -> [String] {
        guard !text.isEmpty else { return [] }
        let maxLength = max(1, maxUTF16Length)
        var chunks: [String] = []
        var current = ""
        var currentLength = 0

        for scalar in text.unicodeScalars {
            let scalarString = String(scalar)
            let scalarLength = (scalarString as NSString).length
            if currentLength + scalarLength > maxLength, !current.isEmpty {
                chunks.append(current)
                current = ""
                currentLength = 0
            }
            current.append(scalarString)
            currentLength += scalarLength
        }

        if !current.isEmpty {
            chunks.append(current)
        }
        return chunks
    }

    private static func streamSelectedText(
        _ text: String,
        into element: AXUIElement,
        maxChunkUTF16Length: Int,
        interChunkDelay: TimeInterval,
        completion: @escaping () -> Void
    ) -> Bool {
        beginSelectedTextStreaming(
            for: text,
            maxUTF16Length: maxChunkUTF16Length,
            interChunkDelay: interChunkDelay,
            writeChunk: { chunk in
                AXUIElementSetAttributeValue(
                    element,
                    kAXSelectedTextAttribute as CFString,
                    chunk as CFTypeRef
                ) == .success
            },
            enqueueRemainder: { work in
                selectedTextStreamingQueue.async {
                    work()
                }
            },
            sleep: Thread.sleep(forTimeInterval:),
            onCompletion: { disposition in
                if case let .partiallyApplied(writtenChunkCount, totalChunkCount) = disposition {
                    NSLog(
                        "[VoiceBar] AX selected-text streaming stopped after %d/%d chunks; suppressing whole-transcript fallback",
                        writtenChunkCount,
                        totalChunkCount
                    )
                }
                if disposition.suppressesWholeTranscriptFallback {
                    completion()
                }
            }
        )
    }

    static func beginSelectedTextStreaming(
        for text: String,
        maxUTF16Length: Int,
        interChunkDelay: TimeInterval,
        writeChunk: @escaping (String) -> Bool,
        enqueueRemainder: (@escaping () -> Void) -> Void,
        sleep: @escaping (TimeInterval) -> Void,
        onCompletion: @escaping (AXSelectedTextStreamingDisposition) -> Void
    ) -> Bool {
        let chunks = selectedTextChunks(for: text, maxUTF16Length: maxUTF16Length)
        guard let firstChunk = chunks.first else {
            onCompletion(.applied(writtenChunkCount: 0))
            return true
        }
        guard writeChunk(firstChunk) else {
            onCompletion(.failedBeforeWrite)
            return false
        }
        guard chunks.count > 1 else {
            onCompletion(.applied(writtenChunkCount: 1))
            return true
        }

        enqueueRemainder {
            var writtenChunkCount = 1
            for chunk in chunks.dropFirst() {
                if interChunkDelay > 0 {
                    sleep(interChunkDelay)
                }
                guard writeChunk(chunk) else {
                    onCompletion(
                        .partiallyApplied(
                            writtenChunkCount: writtenChunkCount,
                            totalChunkCount: chunks.count
                        )
                    )
                    return
                }
                writtenChunkCount += 1
            }
            onCompletion(.applied(writtenChunkCount: writtenChunkCount))
        }
        return true
    }

    static func selectedTextStreamingDisposition(
        for text: String,
        maxUTF16Length: Int,
        interChunkDelay: TimeInterval,
        writeChunk: (String) -> Bool,
        sleep: (TimeInterval) -> Void
    ) -> AXSelectedTextStreamingDisposition {
        let chunks = selectedTextChunks(for: text, maxUTF16Length: maxUTF16Length)
        guard !chunks.isEmpty else { return .applied(writtenChunkCount: 0) }

        var writtenChunkCount = 0
        for (index, chunk) in chunks.enumerated() {
            guard writeChunk(chunk) else {
                return writtenChunkCount == 0
                    ? .failedBeforeWrite
                    : .partiallyApplied(
                        writtenChunkCount: writtenChunkCount,
                        totalChunkCount: chunks.count
                    )
            }
            writtenChunkCount += 1
            if index < chunks.count - 1, interChunkDelay > 0 {
                sleep(interChunkDelay)
            }
        }
        return .applied(writtenChunkCount: writtenChunkCount)
    }

    static func assessAXWrite(
        expectedValue: String,
        didWrite: Bool,
        readBackValue: String?
    ) -> AXWriteDisposition {
        guard didWrite else { return .failed }
        guard let readBackValue else { return .appliedUnverified }
        return readBackValue == expectedValue ? .appliedVerified : .appliedUnverified
    }

    private static func readAttributeString(_ element: AXUIElement, attribute: CFString) -> String? {
        var raw: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute, &raw)
        guard status == .success else { return nil }
        return raw as? String
    }

    private static func targetBundleIdentifier(for element: AXUIElement) -> String? {
        var pid = pid_t()
        guard AXUIElementGetPid(element, &pid) == .success else { return nil }
        return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }

    private static func readSelectedRange(_ element: AXUIElement) -> NSRange? {
        var raw: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &raw
        )
        guard status == .success, let axValue = raw else { return nil }
        let value = axValue as! AXValue
        var range = CFRange()
        guard AXValueGetType(value) == .cfRange,
              AXValueGetValue(value, .cfRange, &range)
        else {
            return nil
        }
        return NSRange(location: range.location, length: range.length)
    }

    private static func writeSelectedRange(_ range: NSRange, to element: AXUIElement) -> Bool {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let value = AXValueCreate(.cfRange, &cfRange) else { return false }
        return AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            value
        ) == .success
    }

    private static func writeStringToPasteboard(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    private static func postPasteShortcutLive() -> Bool {
        guard AXIsProcessTrusted() else { return false }
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        else {
            return false
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}
