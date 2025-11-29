import SwiftUI
import AppKit
import MacrecCore

@main
struct MacrecUIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        statusController = StatusItemController()
    }
}

@MainActor
final class RecorderViewModel: ObservableObject {
    @Published var apps: [String] = []
    @Published var selectedApp: String = ""
    @Published var isRecording = false
    @Published var isBusy = false
    @Published var statusMessage = ""
    @Published var errorMessage: String?
    @Published var elapsed = "00:00"
    @Published var lastSaved: URL?
    @Published var recents: [RecentRecording] = []

    private let recorder = AppRecorder()
    private var handle: RecordingHandle?
    private var timer: Timer?
    private var startDate: Date?
    private let recentsStore = RecentsStore()

    func loadApps(forceRefresh: Bool) async {
        if !forceRefresh && !apps.isEmpty { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let apps = try await recorder.listApplications().map { $0.applicationName }
            self.apps = apps
            if selectedApp.isEmpty {
                selectedApp = apps.first ?? ""
            }
            statusMessage = apps.isEmpty ? "No capturable apps found." : ""
        } catch {
            errorMessage = "Unable to list apps: \(error.localizedDescription)"
        }
    }

    func toggleRecording() {
        if isRecording {
            Task { await stopRecording() }
        } else {
            Task { await startRecording() }
        }
    }

    private func startRecording() async {
        guard !selectedApp.isEmpty else {
            errorMessage = "Select an application to record."
            return
        }

        isBusy = true
        errorMessage = nil
        statusMessage = ""
        do {
            let handle = try await recorder.startRecording(appNamed: selectedApp, outputPath: nil)
            self.handle = handle
            startTimer()
            isRecording = true
            statusMessage = "Recording \(handle.appName)"
        } catch {
            errorMessage = friendly(error)
        }
        isBusy = false
    }

    private func stopRecording() async {
        isBusy = true
        defer { isBusy = false }
        do {
            let duration = startDate.map { Date().timeIntervalSince($0) } ?? 0
            if let handle {
                try await handle.stop()
            }
            stopTimer()
            if let handle {
                statusMessage = "Saved recording"
                lastSaved = handle.outputURL
                addRecent(appName: handle.appName, url: handle.outputURL, duration: duration)
                revealInFinder(url: handle.outputURL)
            }
        } catch {
            errorMessage = friendly(error)
        }
        isRecording = false
        handle = nil
    }

    private func startTimer() {
        startDate = Date()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let start = self.startDate else { return }
                let elapsed = Date().timeIntervalSince(start)
                self.elapsed = Self.format(elapsed: elapsed)
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        startDate = nil
        elapsed = "00:00"
    }

    private func addRecent(appName: String, url: URL, duration: TimeInterval) {
        let entry = RecentRecording(appName: appName, duration: duration, timestamp: Date(), url: url)
        recents = recentsStore.add(entry)
    }

    func loadRecents() {
        recents = recentsStore.load()
    }

    func revealLastSaved() {
        guard let url = lastSaved else { return }
        revealInFinder(url: url)
    }

    func reveal(url: URL) {
        revealInFinder(url: url)
    }

    func copyPath(for url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url.path, forType: .string)
    }

    private func revealInFinder(url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func friendly(_ error: Error) -> String {
        let ns = error as NSError
        return "\(ns.localizedDescription) [\(ns.domain) \(ns.code)]"
    }

    nonisolated private static func format(elapsed: TimeInterval) -> String {
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
