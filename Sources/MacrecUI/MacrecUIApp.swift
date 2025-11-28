import SwiftUI
import AppKit
import MacrecCore

@main
struct MacrecUIApp: App {
    init() {
        // Ensure the app is a regular app (shows in Dock and Cmd+Tab).
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: RecorderViewModel())
                .frame(minWidth: 340, minHeight: 200)
                .onAppear {
                    // Ensure the app becomes active so text inputs receive focus when launched from CLI.
                    NSApp.activate(ignoringOtherApps: true)
                }
        }
    }
}

struct ContentView: View {
    @StateObject var viewModel: RecorderViewModel
    @FocusState private var focusedField: FocusField?

    private enum FocusField: Hashable {
        case output
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("MacrecUI")
                .font(.headline)
                .bold()

            Text("App")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Picker("", selection: $viewModel.selectedApp) {
                ForEach(viewModel.apps, id: \.self) { app in
                    Text(app).tag(app)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .accessibilityLabel("App")
            .frame(maxWidth: .infinity, alignment: .leading)

            Text("Output")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextField("filename.wav", text: $viewModel.outputName)
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: .output)

            HStack {
                Spacer()
                Button(viewModel.isRecording ? "Stop" : "Record") {
                    viewModel.toggleRecording()
                }
                .keyboardShortcut(.space, modifiers: [])
                .buttonStyle(.borderedProminent)
                .tint(viewModel.isRecording ? .red : .accentColor)
                .disabled(viewModel.selectedApp.isEmpty || viewModel.isBusy)
            }

            if viewModel.isRecording {
                Label(viewModel.elapsed, systemImage: "record.circle")
                    .foregroundStyle(.secondary)
            } else if !viewModel.statusMessage.isEmpty {
                Text(viewModel.statusMessage)
                    .foregroundStyle(.secondary)
            }

            if let error = viewModel.errorMessage {
                Text(error)
                    .foregroundStyle(Color.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(minWidth: 320, idealWidth: 340, maxWidth: 440, minHeight: 120, idealHeight: 140)
        .padding(12)
        .task {
            await viewModel.loadApps()
        }
        .onAppear {
            // Bring the app to the front and focus the output field when the window opens.
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first?.makeKeyAndOrderFront(nil)
                focusedField = .output
            }
        }
    }
}

@MainActor
final class RecorderViewModel: ObservableObject {
    @Published var apps: [String] = []
    @Published var selectedApp: String = ""
    @Published var outputName: String = ""
    @Published var isRecording = false
    @Published var isBusy = false
    @Published var statusMessage = ""
    @Published var errorMessage: String?
    @Published var elapsed = "00:00"

    private let recorder = AppRecorder()
    private var handle: RecordingHandle?
    private var timer: Timer?
    private var startDate: Date?

    func loadApps() async {
        isBusy = true
        defer { isBusy = false }
        do {
            let apps = try await recorder.listApplications().map { $0.applicationName }
            self.apps = apps
            if selectedApp.isEmpty {
                selectedApp = apps.first ?? ""
            }
            if outputName.isEmpty, let first = selectedApp.split(separator: ".").first {
                outputName = "\(first).wav"
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
            let handle = try await recorder.startRecording(appNamed: selectedApp, outputPath: outputName.isEmpty ? nil : outputName)
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
            if let handle {
                try await handle.stop()
            }
            stopTimer()
            if let handle {
                statusMessage = "Saved to \(handle.outputURL.path)"
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
