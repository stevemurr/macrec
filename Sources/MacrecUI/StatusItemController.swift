import SwiftUI
import AppKit

@MainActor
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let panel: NSPanel
    private let hosting: NSHostingView<MenuBarView>
    private let viewModel = RecorderViewModel()

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        panel = StatusItemController.makePanel()
        hosting = NSHostingView(
            rootView: MenuBarView(
                viewModel: viewModel,
                onClose: { [weak panel] in panel?.orderOut(nil) }
            )
        )
        super.init()

        configureStatusItem()
        configurePanel()
    }

    private func configureStatusItem() {
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: "macrec")
            button.action = #selector(togglePanel(_:))
            button.target = self
        }
    }

    private func configurePanel() {
        panel.contentView = hosting
        panel.setContentSize(NSSize(width: 340, height: 260))
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
    }

    @objc
    private func togglePanel(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if panel.isVisible {
            panel.orderOut(sender)
            return
        }

        positionPanel(relativeTo: button)
        Task { await viewModel.loadApps(forceRefresh: true) }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(sender)
    }

    private func positionPanel(relativeTo button: NSStatusBarButton) {
        guard let window = button.window else { return }
        let buttonFrameInScreen = window.convertToScreen(button.convert(button.bounds, to: nil))
        var origin = NSPoint(
            x: buttonFrameInScreen.midX - panel.frame.width / 2,
            y: buttonFrameInScreen.minY - panel.frame.height - 8
        )
        if let screenFrame = window.screen?.visibleFrame {
            origin.x = max(screenFrame.minX + 8, min(origin.x, screenFrame.maxX - panel.frame.width - 8))
        }
        panel.setFrameOrigin(origin)
    }

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 260),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovable = false
        return panel
    }
}

struct MenuBarView: View {
    @ObservedObject var viewModel: RecorderViewModel
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            header
            Divider()
            controls
            statusSection
            footer
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minWidth: 320, idealWidth: 340, maxWidth: 360)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .task {
            await viewModel.loadApps(forceRefresh: false)
            viewModel.loadRecents()
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform.circle.fill")
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text("macrec")
                    .font(.headline)
            }
            Spacer()
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Application")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Picker("", selection: $viewModel.selectedApp) {
                ForEach(viewModel.apps, id: \.self) { app in
                    Text(app).tag(app)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(minWidth: 260, maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("Application")

            Button {
                viewModel.toggleRecording()
            } label: {
                HStack {
                    Image(systemName: viewModel.isRecording ? "stop.fill" : "record.circle.fill")
                        .imageScale(.large)
                    if viewModel.isRecording {
                        Text("Stop")
                            .fontWeight(.semibold)
                        Spacer()
                        Text(viewModel.elapsed)
                            .monospacedDigit()
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Start Recording")
                            .fontWeight(.semibold)
                        Spacer()
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .keyboardShortcut(.space, modifiers: [])
            .buttonStyle(RecordingButtonStyle(isRecording: viewModel.isRecording))
            .animation(.easeInOut(duration: 0.2), value: viewModel.isRecording)
            .disabled(viewModel.selectedApp.isEmpty || viewModel.isBusy)
        }
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = viewModel.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }

            if !viewModel.recents.isEmpty {
                Divider()
                VStack(spacing: 6) {
                    ForEach(viewModel.recents.prefix(5)) { item in
                        RecentCard(
                            primary: item.appName,
                            secondary: "\(RecentCard.format(duration: item.duration)) · \(item.simpleDate)",
                            onReveal: { viewModel.reveal(url: item.url) },
                            onCopy: { viewModel.copyPath(for: item.url) }
                        )
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack { Spacer() }
    }
}

private struct RecentCard: View {
    let primary: String
    let secondary: String
    let onReveal: () -> Void
    let onCopy: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(primary)
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(secondary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button {
                onReveal()
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help("Reveal in Finder")

            Button {
                onCopy()
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy path")
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    static func format(duration: TimeInterval) -> String {
        let total = Int(duration)
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        let hours = total / 3600
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

private struct RecordingButtonStyle: ButtonStyle {
    let isRecording: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let base = isRecording ? Color(.systemRed) : Color.accentColor
        let color = isEnabled ? base : base.opacity(0.4)

        return configuration.label
            .foregroundStyle(Color.white)
            .padding(.vertical, 12)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(color.opacity(configuration.isPressed ? 0.85 : 1))
            )
            .shadow(color: .black.opacity(0.08), radius: configuration.isPressed ? 2 : 4, x: 0, y: configuration.isPressed ? 1 : 2)
            .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
    }
}
