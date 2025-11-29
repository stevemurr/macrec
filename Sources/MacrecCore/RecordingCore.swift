import Foundation
import AVFoundation
import CoreMedia
@preconcurrency import ScreenCaptureKit

public struct RecordingHandle {
    public let appName: String
    public let outputURL: URL
    private let stream: SCStream
    private let writer: AudioFileWriter

    init(appName: String, outputURL: URL, stream: SCStream, writer: AudioFileWriter) {
        self.appName = appName
        self.outputURL = outputURL
        self.stream = stream
        self.writer = writer
    }

    @MainActor
    public func stop() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            stream.stopCapture { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
        writer.finish()
    }
}

@MainActor
public final class AppRecorder {
    public init() {}

    public func listApplications() async throws -> [SCRunningApplication] {
        let content = try await SCShareableContent.current
        return content.applications.sorted { $0.applicationName.localizedCaseInsensitiveCompare($1.applicationName) == .orderedAscending }
    }

    public func startRecording(appNamed name: String, outputPath: String?) async throws -> RecordingHandle {
        let content = try await SCShareableContent.current

        guard let targetApp = matchApplication(name, in: content.applications) else {
            throw RecordingError.notFound("Could not find an application named '\(name)'. Use -l to list capturable apps.")
        }

        guard let display = content.displays.first else {
            throw RecordingError.notFound("No displays found to anchor capture.")
        }

        let outputURL = resolvedOutputURL(outputPath, fallbackName: targetApp.applicationName)
        let writer = try AudioFileWriter(outputURL: outputURL)

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        config.excludesCurrentProcessAudio = true
        config.queueDepth = 4

        let filter: SCContentFilter
        if #available(macOS 15.2, *) {
            filter = SCContentFilter(display: display, including: [targetApp], exceptingWindows: [])
        } else if let window = content.windows.first(where: { $0.owningApplication?.processID == targetApp.processID }) {
            filter = SCContentFilter(desktopIndependentWindow: window)
        } else {
            filter = SCContentFilter(display: display, excludingWindows: [])
        }

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try addOutput(writer, to: stream, queue: writer.queue)

        try await startStream(stream)

        return RecordingHandle(appName: targetApp.applicationName, outputURL: outputURL, stream: stream, writer: writer)
    }

    private func addOutput(_ output: SCStreamOutput, to stream: SCStream, queue: DispatchQueue) throws {
        try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: queue)
    }

    private func startStream(_ stream: SCStream) async throws {
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            stream.startCapture { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }
}

public enum RecordingError: LocalizedError {
    case notFound(String)

    public var errorDescription: String? {
        switch self {
        case let .notFound(message):
            return message
        }
    }
}

// MARK: - Helpers

private func matchApplication(_ name: String, in applications: [SCRunningApplication]) -> SCRunningApplication? {
    let lower = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !lower.isEmpty else { return nil }

    if let exact = applications.first(where: { $0.applicationName.lowercased() == lower }) {
        return exact
    }
    return applications.first(where: { $0.applicationName.lowercased().contains(lower) })
}

private func resolvedOutputURL(_ path: String?, fallbackName: String) -> URL {
    let filename = path ?? defaultOutputName(for: fallbackName)
    let url = URL(fileURLWithPath: filename)
    let resolved: URL
    if url.path.hasPrefix("/") {
        resolved = url
    } else {
        resolved = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(filename)
    }
    return uniqueURL(startingAt: resolved)
}

private func defaultOutputName(for appName: String) -> String {
    let sanitized = sanitizedAppName(appName)
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd_HHmmss"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    let timestamp = formatter.string(from: Date())
    return "\(sanitized.isEmpty ? "output" : sanitized)_\(timestamp).wav"
}

private func uniqueURL(startingAt url: URL) -> URL {
    guard FileManager.default.fileExists(atPath: url.path) else { return url }
    let base = url.deletingPathExtension()
    let ext = url.pathExtension
    var attempt = 1
    while attempt < 10_000 {
        let candidateName = base.lastPathComponent + "-\(attempt)"
        let candidate = base.deletingLastPathComponent()
            .appendingPathComponent(candidateName)
            .appendingPathExtension(ext)
        if !FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        attempt += 1
    }
    return url
}

private func sanitizedAppName(_ name: String) -> String {
    name
        .components(separatedBy: CharacterSet.alphanumerics.inverted)
        .filter { !$0.isEmpty }
        .joined(separator: "_")
}

// MARK: - Audio writer

final class AudioFileWriter: NSObject, SCStreamOutput {
    let queue = DispatchQueue(label: "macrec.audio.writer")
    private let outputURL: URL
    private var audioFile: AVAudioFile?
    private var format: AVAudioFormat?
    private var encounteredError = false

    init(outputURL: URL) throws {
        self.outputURL = outputURL
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .audio else { return }
        guard CMSampleBufferDataIsReady(sampleBuffer), !encounteredError else { return }

        do {
            try write(sampleBuffer: sampleBuffer)
        } catch {
            encounteredError = true
            fputs("Audio write error: \(error.localizedDescription)\n", stderr)
        }
    }

    func finish() {
        audioFile = nil
    }

    private func write(sampleBuffer: CMSampleBuffer) throws {
        if format == nil {
            try prepareFormat(for: sampleBuffer)
        }
        guard let format else { return }

        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else {
            throw NSError(domain: "macrec", code: -2, userInfo: [NSLocalizedDescriptionKey: "Unable to allocate PCM buffer"])
        }

        buffer.frameLength = buffer.frameCapacity
        let copyStatus = CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frameCount), into: buffer.mutableAudioBufferList)
        guard copyStatus == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(copyStatus), userInfo: [NSLocalizedDescriptionKey: "PCM copy failed (\(copyStatus))"])
        }

        guard let audioFile else {
            throw NSError(domain: "macrec", code: -3, userInfo: [NSLocalizedDescriptionKey: "Audio file not initialized"])
        }
        try audioFile.write(from: buffer)
    }

    private func prepareFormat(for sampleBuffer: CMSampleBuffer) throws {
        guard let formatDescription = sampleBuffer.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            throw NSError(domain: "macrec", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unable to read audio format description"])
        }

        guard let audioFormat = AVAudioFormat(streamDescription: asbd) else {
            throw NSError(domain: "macrec", code: -4, userInfo: [NSLocalizedDescriptionKey: "Unsupported audio format"])
        }

        var settings = audioFormat.settings
        settings[AVLinearPCMIsNonInterleaved] = false

        self.format = audioFormat
        self.audioFile = try AVAudioFile(forWriting: outputURL, settings: settings)
    }
}
