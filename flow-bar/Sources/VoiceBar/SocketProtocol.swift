import CoreFoundation
import Foundation
import VoiceBarUI

enum SocketPlaybackAmplitudeParser {
    static func parse(event: [String: Any]) -> PlaybackAmplitudeEnvelope? {
        guard event["type"] as? String == "state",
              event["state"] as? String == "speaking",
              let payload = event["playback_amplitude"] as? [String: Any],
              let sourceValue = payload["source"] as? String,
              let source = PlaybackAmplitudeSource(rawValue: sourceValue),
              let interval = integer(payload["sample_interval_ms"]),
              interval > 0,
              let rawSamples = payload["samples"] as? [Any],
              rawSamples.count <= PlaybackAmplitudeEnvelope.maximumSampleCount
        else { return nil }

        let samples = rawSamples.compactMap(number)
        guard samples.count == rawSamples.count else { return nil }
        switch source {
        case .decodedRMS:
            guard !samples.isEmpty else { return nil }
        case .unavailable:
            guard samples.isEmpty else { return nil }
        }

        return PlaybackAmplitudeEnvelope(
            source: source,
            sampleIntervalMilliseconds: interval,
            samples: samples
        )
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let value, !isBoolean(value) else { return nil }
        if let integer = value as? Int { return integer }
        guard let number = value as? NSNumber else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double.rounded() == double else { return nil }
        return Int(exactly: double)
    }

    private static func number(_ value: Any) -> Double? {
        guard !isBoolean(value) else { return nil }
        let parsed: Double? = if let double = value as? Double {
            double
        } else if let integer = value as? Int {
            Double(integer)
        } else if let number = value as? NSNumber {
            number.doubleValue
        } else {
            nil
        }
        guard let parsed, parsed.isFinite else { return nil }
        return parsed
    }

    private static func isBoolean(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return value is Bool }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }
}

struct SetRecordingHoldCommand: Equatable {
    static let commandName = "set_recording_hold"

    let engaged: Bool
    let id: String?

    init(engaged: Bool, id: String? = nil) {
        self.engaged = engaged
        self.id = id
    }

    init?(payload: [String: Any]) {
        guard payload["cmd"] as? String == Self.commandName,
              let engagedNumber = payload["engaged"] as? NSNumber,
              CFGetTypeID(engagedNumber) == CFBooleanGetTypeID()
        else {
            return nil
        }
        engaged = engagedNumber.boolValue
        id = payload["id"] as? String
    }

    var payload: [String: Any] {
        var result: [String: Any] = [
            "cmd": Self.commandName,
            "engaged": engaged,
        ]
        if let id {
            result["id"] = id
        }
        return result
    }
}

enum SocketControlCommand: String, Equatable {
    case startRecording = "start-recording"
    case stopRecording = "stop-recording"
    case toggle
    case cancel
    case replay

    init?(event: [String: Any]) {
        guard event["type"] as? String == "control",
              let command = event["command"] as? String
        else {
            return nil
        }
        self.init(rawValue: command)
    }
}

enum VoiceBarLocalControlCommand: String, Equatable {
    case startRecording = "start-recording"
    case stopRecording = "stop-recording"
    case toggle
    case pasteLastTranscript = "paste-last-transcript"

    init?(payload: [String: Any]) {
        guard let type = payload["type"] as? String,
              type == "control",
              let rawCommand = payload["command"] as? String,
              let command = Self(rawValue: rawCommand)
        else {
            return nil
        }

        self = command
    }
}
