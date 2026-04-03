// AudioCapture.swift — AVAudioEngine mic capture for VoiceBar.
//
// Records from the default input device at 16kHz 16-bit mono PCM.
// Streams chunks to the daemon via the socket server.
// This runs inside VoiceBar.app — TCC mic permission is valid because
// VoiceBar is the responsible process (no orphan chain breakage).
//
// AIDEV-NOTE: This replaces sox (rec) for mic capture when VoiceBar is
// connected. Sox remains as fallback for MCP-only mode without VoiceBar.

import AVFoundation
import Foundation

final class AudioCapture {
    private let engine = AVAudioEngine()
    private var isCapturing = false

    /// Target format: 16kHz 16-bit mono PCM (what VAD and whisper expect)
    private let targetSampleRate: Double = 16000
    private let targetChannels: UInt32 = 1

    /// Callback receives 16kHz 16-bit mono PCM chunks (Uint8-compatible bytes)
    var onAudioChunk: ((Data) -> Void)?

    /// Request mic permission (shows system prompt on first call)
    static func requestPermission(completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                completion(granted)
            }
        }
    }

    /// Start capturing from the default input device.
    func start() throws {
        guard !isCapturing else { return }

        let inputNode = engine.inputNode
        let hwFormat = inputNode.outputFormat(forBus: 0)

        NSLog("[AudioCapture] Device format: %.0fHz, %d channels",
              hwFormat.sampleRate, hwFormat.channelCount)

        // Install tap — AVAudioEngine handles resampling from device rate to our format
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: targetSampleRate,
            channels: targetChannels,
            interleaved: true
        )!

        // Use a converter to resample from hardware format to 16kHz 16-bit mono
        guard let converter = AVAudioConverter(from: hwFormat, to: targetFormat) else {
            throw AudioCaptureError.converterCreationFailed
        }

        // Tap at hardware format, convert in the callback
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buffer, _ in
            guard let self, isCapturing else { return }
            processBuffer(buffer, converter: converter, targetFormat: targetFormat)
        }

        engine.prepare()
        try engine.start()
        isCapturing = true
        NSLog("[AudioCapture] Started — capturing at %.0fHz, converting to %.0fHz",
              hwFormat.sampleRate, targetSampleRate)
    }

    /// Stop capturing.
    func stop() {
        guard isCapturing else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isCapturing = false
        NSLog("[AudioCapture] Stopped")
    }

    /// Convert hardware-format buffer to 16kHz 16-bit mono and emit via callback.
    private func processBuffer(
        _ buffer: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        targetFormat: AVAudioFormat
    ) {
        // Calculate output frame count based on sample rate ratio
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let outputFrameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio)

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outputFrameCount
        ) else { return }

        var error: NSError?
        var allConsumed = false
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if allConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            allConsumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        if let error {
            NSLog("[AudioCapture] Conversion error: %@", error.localizedDescription)
            return
        }

        guard outputBuffer.frameLength > 0 else { return }

        // Extract raw bytes from the int16 buffer
        let byteCount = Int(outputBuffer.frameLength) * Int(targetFormat.streamDescription.pointee.mBytesPerFrame)
        guard let int16Data = outputBuffer.int16ChannelData else { return }

        let data = Data(bytes: int16Data[0], count: byteCount)
        onAudioChunk?(data)
    }
}

enum AudioCaptureError: Error {
    case converterCreationFailed
}
