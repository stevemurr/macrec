# macrec

Record the output audio of a macOS application from the command line using ScreenCaptureKit (no virtual audio devices required).

## Requirements
- macOS 13+ (14 or newer recommended for most reliable app audio capture)
- Screen Recording permission for `macrec` (you will be prompted on first run)

## Build
```bash
# From the repo root
swift build -c release
```

## Usage
```bash
# List capturable apps
swift run macrec -l

# Record an app's output to WAV (press Ctrl+C to stop)
swift run macrec -r "Apple Music" -o music.wav

# Launch the SwiftUI UI (runs as a SwiftPM executable)
swift run MacrecUI
```

Notes:
- The default output file name is derived from the app name if `-o` is omitted.
- The tool scopes capture to the primary display and excludes its own audio.
- If the app does not appear in `-l`, open it first or confirm Screen Recording permission in System Settings → Privacy & Security.
- To build a `.app` bundle, open the package in Xcode and add signing/entitlements as needed; `swift run MacrecUI` is sufficient for local use.
