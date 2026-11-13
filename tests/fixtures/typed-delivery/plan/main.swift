// Prints SynthesizedTyping's keystroke plan for stdin as JSON lines, compiled together with the
// production flow-bar/Sources/VoiceBarUI/SynthesizedTyping.swift (lane T7 fixture driver input).
import Foundation

let input = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
var out: [[String: String]] = []
for keystroke in SynthesizedTyping.keystrokes(for: input) {
    switch keystroke {
    case let .text(s): out.append(["t": "text", "s": s])
    case .newline: out.append(["t": "newline"])
    }
}
let data = try JSONSerialization.data(withJSONObject: out)
print(String(decoding: data, as: UTF8.self))
