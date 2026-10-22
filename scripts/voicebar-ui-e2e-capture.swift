import AVFoundation
import CoreGraphics
import ScreenCaptureKit

// Standalone QA tool. The only capture source is the windows of this run's proven QA process
// (bundle AND exact executable path) on the main SCDisplay: everything else (desktop, other apps,
// system dialogs, a stale QA app from another run) is never composited. No full-display mode.
// There is no AVCaptureDevice lookup, device-name selector, camera input or audio output.
// BEGIN QA EXECUTABLE PATH
// BEGIN CANONICAL PATH
/// The one path form compared on both sides of every QA executable check: realpath(3), which keeps
/// /private (Foundation's resolvingSymlinksInPath strips it). An unresolvable path stays exact.
func canonicalPath(_ path: String) -> String {
    guard let resolved = realpath(path, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
}
// END CANONICAL PATH
func qaExecutablePath(_ pid: pid_t) -> String? {
    var buffer = [CChar](repeating: 0, count: 4096)
    guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
    return canonicalPath(String(cString: buffer))
}
// END QA EXECUTABLE PATH
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    private let queue = DispatchQueue(label: "voicebar.uie2e.screen")
    private let destination: URL
    private let bundle: String
    private let executable: String
    private var display: SCDisplay?
    private var includedPids: [pid_t] = []
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var video: AVAssetWriterInput?
    private var stopping = false
    private var failure: String?
    private var frames = 0

    init(destination: URL, bundle: String, executable: String) {
        self.destination = destination; self.bundle = bundle; self.executable = canonicalPath(executable)
    }

    // BEGIN QA-ONLY FILTER
    /// The run's proven QA process: bundle AND exact executable path (as proc_pidpath reports it).
    static func provenApplications(_ applications: [SCRunningApplication], bundle: String, executable: String,
                                   path: (pid_t) -> String?) -> [SCRunningApplication] {
        applications.filter { $0.bundleIdentifier == bundle && path($0.processID) == executable }
    }
    /// Only those applications' windows; an empty list renders black frames, never the desktop.
    static func qaFilter(display: SCDisplay, applications: [SCRunningApplication]) -> SCContentFilter {
        SCContentFilter(display: display, including: applications, exceptingWindows: [])
    }
    // END QA-ONLY FILTER

    static func executablePath(_ pid: pid_t) -> String? { qaExecutablePath(pid) }
    func proven(_ applications: [SCRunningApplication]) -> [SCRunningApplication] {
        Self.provenApplications(applications, bundle: bundle, executable: executable, path: Self.executablePath)
    }

    /// The QA app launches after recording starts: follow its process set as it appears.
    private func followApplication() {
        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: false) { content, _ in
            self.queue.async {
                guard !self.stopping, let display = self.display, let stream = self.stream, let content else { return }
                let apps = self.proven(content.applications)
                let pids = apps.map(\.processID).sorted()
                if pids != self.includedPids {
                    self.includedPids = pids
                    stream.updateContentFilter(Self.qaFilter(display: display, applications: apps)) { error in
                        if let error { self.stop(error: "Capture filter update failed: \(error)") }
                    }
                    print("source=application bundle=\(self.bundle) executable=\(self.executable) pids=\(pids.map(String.init).joined(separator: ","))")
                    fflush(stdout)
                }
            }
        }
        queue.asyncAfter(deadline: .now() + 0.5) { if !self.stopping { self.followApplication() } }
    }

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
                    let filter = Self.qaFilter(display: display, applications: self.proven(content?.applications ?? []))
                    self.display = display
                    let stream = SCStream(filter: filter, configuration: config, delegate: self)
                    self.stream = stream
                    try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.queue)
                    print("source=application bundle=\(self.bundle) executable=\(self.executable) pids=")
                    fflush(stdout)
                    stream.startCapture { error in
                        if let error { self.stop(error: "Screen capture failed: \(error)") } else { self.followApplication() }
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
    print("VoiceBar UIE2E ScreenCaptureKit recorder v3 (proven QA process windows only)")
    exit(0)
}
// There is deliberately no full-display mode: the QA bundle is mandatory.
let args = CommandLine.arguments
guard args.count == 6, args[1] == "--include-bundle", !args[2].isEmpty, args[3] == "--include-executable",
      args[4].hasPrefix("/") else {
    FileHandle.standardError.write(Data("usage: voicebar-ui-e2e-capture --include-bundle BUNDLE_ID --include-executable PATH NEW_MOV_PATH\n".utf8))
    exit(2)
}
let recorder = ScreenRecorder(destination: URL(fileURLWithPath: args[5]), bundle: args[2], executable: args[4])
recorder.start()
DispatchQueue.global().async {
    while let line = readLine() {
        if line == "q" { recorder.stop(); return }
    }
    recorder.stop(error: "Supervisor stdin closed")
}
RunLoop.main.run()
