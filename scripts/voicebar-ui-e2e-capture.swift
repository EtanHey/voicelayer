import AVFoundation
import CoreGraphics
import ScreenCaptureKit

// Standalone QA tool. The only capture source is an SCDisplay; there is no
// AVCaptureDevice lookup, device-name selector, camera input or audio output.
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    private let queue = DispatchQueue(label: "voicebar.uie2e.screen")
    private let destination: URL
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var video: AVAssetWriterInput?
    private var stopping = false
    private var failure: String?
    private var frames = 0

    init(destination: URL) { self.destination = destination }

    func start() {
        // Never request/grant permission or fall back to a camera.
        guard CGPreflightScreenCaptureAccess() else {
            stop(error: "Screen Recording permission missing; stop for human approval")
            return
        }
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
            self.queue.async {
                guard !self.stopping else { return }
                do {
                    if let error { throw error }
                    guard let display = content?.displays.first(where: { $0.displayID == CGMainDisplayID() })
                    else { throw self.error("Main display unavailable") }
                    let config = SCStreamConfiguration()
                    config.width = display.width / 2 * 2
                    config.height = display.height / 2 * 2
                    config.minimumFrameInterval = CMTime(value: 1, timescale: 15)
                    config.queueDepth = 5
                    config.pixelFormat = kCVPixelFormatType_32BGRA
                    config.showsCursor = true
                    config.capturesAudio = false
                    if #available(macOS 15.0, *) { config.captureMicrophone = false }
                    let writer = try AVAssetWriter(outputURL: self.destination, fileType: .mov)
                    writer.movieFragmentInterval = CMTime(value: 1, timescale: 1)
                    let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
                        AVVideoCodecKey: AVVideoCodecType.h264,
                        AVVideoWidthKey: config.width, AVVideoHeightKey: config.height,
                        AVVideoCompressionPropertiesKey: [AVVideoMaxKeyFrameIntervalKey: 15]])
                    video.expectsMediaDataInRealTime = true
                    guard writer.canAdd(video) else { throw self.error("Cannot add video writer") }
                    writer.add(video)
                    self.writer = writer
                    self.video = video
                    let filter = SCContentFilter(display: display, excludingWindows: [])
                    let stream = SCStream(filter: filter, configuration: config, delegate: self)
                    self.stream = stream
                    try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.queue)
                    stream.startCapture { error in
                        if let error { self.stop(error: "Screen capture failed: \(error)") }
                    }
                } catch { self.stop(error: "Screen capture setup failed: \(error)") }
            }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // Runs on queue, which also serializes writer shutdown behind pending frames.
        guard !stopping, type == .screen, CMSampleBufferIsValid(sampleBuffer),
              CMSampleBufferDataIsReady(sampleBuffer),
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: status) == .complete,
              let writer, let video else { return }
        if writer.status == .unknown {
            guard writer.startWriting() else { stop(error: "Writer start failed: \(String(describing: writer.error))"); return }
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        }
        guard video.isReadyForMoreMediaData else { return }
        guard video.append(sampleBuffer) else { stop(error: "Video append failed: \(String(describing: writer.error))"); return }
        frames += 1
        print("frame=\(frames)")
        fflush(stdout)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        stop(error: "Screen stream stopped unexpectedly: \(error)")
    }

    func stop(error: String? = nil) {
        queue.async {
            if let error { self.failure = error }
            guard !self.stopping else { return }
            self.stopping = true
            guard let stream = self.stream else { self.finish(); return }
            stream.stopCapture { error in
                self.queue.async {
                    if let error { self.failure = "Screen stop failed: \(error)" }
                    self.finish()
                }
            }
        }
    }

    private func finish() {
        guard frames > 0, let writer, writer.status == .writing, let video else {
            exitWithFailure(failure ?? "No screen frames recorded")
        }
        video.markAsFinished()
        writer.finishWriting {
            self.queue.async {
                guard writer.status == .completed, self.failure == nil else {
                    self.exitWithFailure(self.failure ?? "Movie flush failed: \(String(describing: writer.error))")
                }
                print("flushed")
                fflush(stdout)
                exit(0) // Exit only after the MOV writer confirms finalization.
            }
        }
    }

    private func error(_ message: String) -> NSError { NSError(domain: message, code: 1) }
    private func exitWithFailure(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }
}

if CommandLine.arguments == [CommandLine.arguments[0], "--version"] {
    print("VoiceBar UIE2E ScreenCaptureKit recorder v1")
    exit(0)
}
guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: voicebar-ui-e2e-capture NEW_MOV_PATH\n".utf8))
    exit(2)
}
let recorder = ScreenRecorder(destination: URL(fileURLWithPath: CommandLine.arguments[1]))
recorder.start()
DispatchQueue.global().async {
    while let line = readLine() {
        if line == "q" { recorder.stop(); return }
    }
    recorder.stop(error: "Supervisor stdin closed")
}
RunLoop.main.run()
