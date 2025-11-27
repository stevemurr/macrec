import Foundation
import AVFoundation
import CoreMedia
import Darwin
import ScreenCaptureKit

@main
struct Macrec {
    static func main() async {
        do {
            try await CLI().run()
        } catch {
            fputs("Error: \(describe(error))\n", stderr)
            exit(EXIT_FAILURE)
        }
    }
}

struct CLI {
    func run() async throws {
        switch Arguments.parse(from: Array(CommandLine.arguments.dropFirst())) {
        case .list:
            try await listApplications()
        case let .record(appName, outputPath):
            try await record(applicationNamed: appName, outputPath: outputPath)
        case .usage:
            printUsage()
        }
    }

    private func listApplications() async throws {
        let content = try await SCShareableContent.current
        let apps = content.applications
            .map { $0.applicationName }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

        if apps.isEmpty {
            print("No capturable applications found. You may need to grant Screen Recording permission.")
            return
        }

        apps.forEach { print($0) }
    }

    private func record(applicationNamed name: String, outputPath: String?) async throws {
        let content = try await SCShareableContent.current

        guard let targetApp = matchApplication(name, in: content.applications) else {
            throw CLIError.notFound("Could not find an application named '\(name)'. Use -l to list capturable apps.")
        }

        guard let display = content.displays.first else {
            throw CLIError.notFound("No displays found to anchor capture.")
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
            // Fallback: capture the whole display if app-specific capture is not available on this macOS
            filter = SCContentFilter(display: display, excludingWindows: [])
            fputs("Warning: capturing full display audio because no windows for '\(targetApp.applicationName)' were found.\n", stderr)
        }
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try await addOutput(writer, to: stream, queue: writer.queue)

        print("Recording '\(targetApp.applicationName)' → \(outputURL.path)")
        print("Press Ctrl+C to stop. If prompted, allow Screen Recording access.")

        try await stream.startCapture()
        waitForStopSignal()
        try await stream.stopCapture()

        writer.finish()
        print("Recording stopped. Saved to \(outputURL.path)")
    }

    private func addOutput(_ output: SCStreamOutput, to stream: SCStream, queue: DispatchQueue) async throws {
        try await stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: queue)
    }

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
        if url.path.hasPrefix("/") {
            return url
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(filename)
    }

    private func defaultOutputName(for appName: String) -> String {
        let sanitized = appName
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "_")
        return "\(sanitized.isEmpty ? "output" : sanitized).wav"
    }

    private func printUsage() {
        let usage = """
        macrec - CLI audio recorder for macOS apps (ScreenCaptureKit)

        Usage:
          macrec -l
              List capturable applications.

          macrec -r "App Name" [-o output.wav]
              Record the specified application's output to a WAV file. Default output uses the app name.

        Notes:
          - First run will prompt for Screen Recording permission; approve to allow capture.
          - Uses the primary display to scope capture and excludes this process's audio.
        """
        print(usage)
    }
}

private func describe(_ error: Error) -> String {
    let ns = error as NSError
    return "\(ns.localizedDescription) [\(ns.domain) \(ns.code)]"
}

enum CLIError: LocalizedError {
    case notFound(String)

    var errorDescription: String? {
        switch self {
        case let .notFound(message):
            return message
        }
    }
}

enum Arguments {
    case list
    case record(appName: String, output: String?)
    case usage

    static func parse(from raw: [String]) -> Arguments {
        var args = raw
        var output: String?
        var target: String?
        var wantsList = false

        while let next = args.first {
            args.removeFirst()
            switch next {
            case "-l", "--list":
                wantsList = true
            case "-r", "--record":
                guard let name = args.first else { return .usage }
                target = name
                args.removeFirst()
            case "-o", "--output":
                guard let path = args.first else { return .usage }
                output = path
                args.removeFirst()
            case "-h", "--help":
                return .usage
            default:
                return .usage
            }
        }

        if wantsList { return .list }
        if let target { return .record(appName: target, output: output) }
        return .usage
    }
}

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

        self.format = audioFormat
        self.audioFile = try AVAudioFile(forWriting: outputURL, settings: audioFormat.settings)
    }
}

private func waitForStopSignal() {
    let semaphore = DispatchSemaphore(value: 0)
    let queue = DispatchQueue(label: "macrec.signal")
    var sources: [DispatchSourceSignal] = []

    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)

    for sig in [SIGINT, SIGTERM] {
        let source = DispatchSource.makeSignalSource(signal: sig, queue: queue)
        source.setEventHandler {
            semaphore.signal()
        }
        source.resume()
        sources.append(source)
    }

    semaphore.wait()
    sources.forEach { $0.cancel() }
}
