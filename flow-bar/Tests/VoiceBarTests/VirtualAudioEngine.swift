import Foundation
@testable import VoiceBar

final class VirtualAudioEngine: AudioStreamable {
    private let mockFile: String
    private let chunkFrameCount: Int

    init(mockFile: String, chunkFrameCount: Int = 1024) {
        precondition(chunkFrameCount > 0, "chunkFrameCount must be greater than 0")
        self.mockFile = mockFile
        self.chunkFrameCount = chunkFrameCount
    }

    func audioStream() -> AsyncThrowingStream<AudioStreamBuffer, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let fixtureURL = try Self.fixtureURL(named: mockFile)
                    let wav = try PCM16WAV(url: fixtureURL)
                    let sampleRate = Double(wav.sampleRate)

                    for start in stride(from: 0, to: wav.samples.count, by: chunkFrameCount) {
                        try Task.checkCancellation()
                        let end = min(start + chunkFrameCount, wav.samples.count)
                        let chunk = Array(wav.samples[start ..< end])
                        continuation.yield(AudioStreamBuffer(samples: chunk, sampleRate: sampleRate))

                        let chunkDuration = Double(chunk.count) / sampleRate
                        try await Task.sleep(for: .seconds(chunkDuration))
                    }

                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private static func fixtureURL(named fileName: String) throws -> URL {
        let bundleURL = Bundle.module.url(forResource: fileName, withExtension: nil)
        if let bundleURL {
            return bundleURL
        }

        let localURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: localURL.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return localURL
    }
}

private struct PCM16WAV {
    let sampleRate: UInt32
    let samples: [Float]

    init(url: URL) throws {
        let data = try Data(contentsOf: url)
        guard data.count >= 44 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        guard String(decoding: data[0 ..< 4], as: UTF8.self) == "RIFF",
              String(decoding: data[8 ..< 12], as: UTF8.self) == "WAVE"
        else {
            throw CocoaError(.fileReadCorruptFile)
        }

        var offset = 12
        var parsedSampleRate: UInt32?
        var bitsPerSample: UInt16?
        var audioFormat: UInt16?
        var channelCount: UInt16?
        var pcmData: Data?

        while offset + 8 <= data.count {
            let chunkID = String(decoding: data[offset ..< offset + 4], as: UTF8.self)
            let chunkSize = Int(data.uint32LE(at: offset + 4))
            let payloadStart = offset + 8
            let payloadEnd = payloadStart + chunkSize
            guard payloadEnd <= data.count else {
                throw CocoaError(.fileReadCorruptFile)
            }

            switch chunkID {
            case "fmt ":
                guard chunkSize >= 16 else { throw CocoaError(.fileReadCorruptFile) }
                audioFormat = data.uint16LE(at: payloadStart)
                channelCount = data.uint16LE(at: payloadStart + 2)
                parsedSampleRate = data.uint32LE(at: payloadStart + 4)
                bitsPerSample = data.uint16LE(at: payloadStart + 14)
            case "data":
                pcmData = Data(data[payloadStart ..< payloadEnd])
            default:
                break
            }

            offset = payloadEnd + (chunkSize % 2)
        }

        guard audioFormat == 1,
              channelCount == 1,
              bitsPerSample == 16,
              let parsedSampleRate,
              let pcmData
        else {
            throw CocoaError(.fileReadCorruptFile)
        }

        sampleRate = parsedSampleRate
        samples = stride(from: 0, to: pcmData.count - 1, by: 2).map { byteOffset in
            Float(pcmData.int16LE(at: byteOffset)) / 32768.0
        }
    }
}

private extension Data {
    func uint16LE(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func uint32LE(at offset: Int) -> UInt32 {
        UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
    }

    func int16LE(at offset: Int) -> Int16 {
        Int16(bitPattern: uint16LE(at: offset))
    }
}
