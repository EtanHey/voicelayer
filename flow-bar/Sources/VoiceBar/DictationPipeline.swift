import Foundation

enum DictationError: Error, Equatable {
    case silenceTimeout
}

struct SileroVAD {
    let threshold: Float
    let minSpeechDuration: TimeInterval

    func isSpeech(_ buffer: AudioStreamBuffer) -> Bool {
        buffer.rms >= threshold
    }
}

final class DictationPipeline {
    private let audioSource: AudioStreamable
    private let vad: SileroVAD

    init(audioSource: AudioStreamable, vad: SileroVAD) {
        self.audioSource = audioSource
        self.vad = vad
    }

    func startListening(timeout: TimeInterval) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { [audioSource, vad] in
                var speechDuration: TimeInterval = 0
                for try await buffer in audioSource.audioStream() {
                    try Task.checkCancellation()
                    speechDuration = vad.isSpeech(buffer)
                        ? speechDuration + buffer.duration
                        : 0

                    if speechDuration >= vad.minSpeechDuration {
                        return
                    }
                }
                throw DictationError.silenceTimeout
            }

            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw DictationError.silenceTimeout
            }

            do {
                try await group.next()
                group.cancelAll()
            } catch {
                group.cancelAll()
                while await group.nextResult() != nil {}
                throw error
            }
            while await group.nextResult() != nil {}
        }
    }
}
