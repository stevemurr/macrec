import Foundation
import Darwin
import MacrecCore

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
    private let recorder = AppRecorder()

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
        let apps = try await MainActor.run {
            try await recorder.listApplications()
                .map { $0.applicationName }
                .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        }

        if apps.isEmpty {
            print("No capturable applications found. You may need to grant Screen Recording permission.")
            return
        }

        apps.forEach { print($0) }
    }

    private func record(applicationNamed name: String, outputPath: String?) async throws {
        let handle = try await MainActor.run {
            try await recorder.startRecording(appNamed: name, outputPath: outputPath)
        }

        let status = RecordingStatus(appName: handle.appName, outputPath: handle.outputURL.path)
        status.start()

        do {
            status.startTimer()
            waitForStopSignal()
            try await MainActor.run {
                try await handle.stop()
            }
            status.finish()
        } catch {
            status.fail(error: error)
            throw error
        }
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

final class RecordingStatus {
    private let appName: String
    private let outputPath: String
    private var startDate: Date?
    private var timer: DispatchSourceTimer?
    private var lastLineLength = 0
    private let queue = DispatchQueue(label: "macrec.status")

    init(appName: String, outputPath: String) {
        self.appName = appName
        self.outputPath = outputPath
    }

    func start() {
        print("▶︎ Recording \(appName)")
        print("   Output: \(outputPath)")
        print("   Press Ctrl+C to stop.")
    }

    func startTimer() {
        startDate = Date()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1)
        timer.setEventHandler { [weak self] in
            self?.tick()
        }
        timer.resume()
        self.timer = timer
    }

    func finish() {
        stopTimer()
        moveToNewLine()
        print("✅ Saved \(outputPath)")
    }

    func fail(error: Error) {
        stopTimer()
        moveToNewLine()
        print("✖️ Recording failed: \(describe(error))")
    }

    private func tick() {
        guard let start = startDate else { return }
        let elapsed = Date().timeIntervalSince(start)
        let line = "⏺  \(appName) — \(format(elapsed: elapsed)) elapsed"
        let padded = line.padding(toLength: max(lastLineLength, line.count), withPad: " ", startingAt: 0)
        fputs("\r\(padded)", stdout)
        fflush(stdout)
        lastLineLength = padded.count
    }

    private func stopTimer() {
        timer?.setEventHandler {}
        timer?.cancel()
        timer = nil
    }

    private func moveToNewLine() {
        fputs("\r", stdout)
        fflush(stdout)
    }

    private func format(elapsed: TimeInterval) -> String {
        let total = Int(elapsed)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
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
