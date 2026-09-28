import Foundation

public struct DictationReceipt: Codable, Equatable {
    public let audioDurationMilliseconds: Int
    public let processingDurationMilliseconds: Int

    public var audioDuration: TimeInterval {
        TimeInterval(audioDurationMilliseconds) / 1000
    }

    public var processingDuration: TimeInterval {
        TimeInterval(processingDurationMilliseconds) / 1000
    }

    public init?(audioDurationMilliseconds: Int, processingDurationMilliseconds: Int) {
        guard audioDurationMilliseconds > 0,
              processingDurationMilliseconds > 0
        else { return nil }
        self.audioDurationMilliseconds = audioDurationMilliseconds
        self.processingDurationMilliseconds = processingDurationMilliseconds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let audio = try container.decode(Int.self, forKey: .audioDurationMilliseconds)
        let processing = try container.decode(Int.self, forKey: .processingDurationMilliseconds)
        guard let receipt = DictationReceipt(
            audioDurationMilliseconds: audio,
            processingDurationMilliseconds: processing
        ) else {
            throw DecodingError.dataCorruptedError(
                forKey: .audioDurationMilliseconds,
                in: container,
                debugDescription: "Dictation receipt durations must be positive"
            )
        }
        self = receipt
    }

    static func parse(_ value: Any?) -> DictationReceipt? {
        guard let fields = value as? [String: Any],
              let audioMilliseconds = positiveMilliseconds(fields["audio_duration_ms"]),
              let processingMilliseconds = positiveMilliseconds(fields["processing_duration_ms"])
        else { return nil }

        return DictationReceipt(
            audioDurationMilliseconds: audioMilliseconds,
            processingDurationMilliseconds: processingMilliseconds
        )
    }

    private static func positiveMilliseconds(_ value: Any?) -> Int? {
        guard !(value is Bool), let number = value as? NSNumber else { return nil }
        let milliseconds = number.doubleValue
        guard milliseconds.isFinite,
              milliseconds > 0,
              let rounded = Int(exactly: milliseconds.rounded())
        else { return nil }
        return rounded > 0 ? rounded : nil
    }
}
