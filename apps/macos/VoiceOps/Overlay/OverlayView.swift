import AppKit
import SwiftUI

struct OverlayView: View {
    @EnvironmentObject private var pipeline: PipelineController
    let onOpenSettings: () -> Void
    @AppStorage(ActivationKeyPreference.keyCodeDefaultsKey) private var activationKeyCode = Int(ActivationKeyPreference.defaultValue.keyCode)
    @AppStorage(ActivationKeyPreference.modifiersDefaultsKey) private var activationModifiers = Int(ActivationKeyPreference.defaultValue.modifiers)
    @AppStorage(HotKeyPreference.keyCodeDefaultsKey) private var clipboardKeyCode = Int(HotKeyPreference.defaultValue.keyCode)
    @AppStorage(HotKeyPreference.modifiersDefaultsKey) private var clipboardModifiers = Int(HotKeyPreference.defaultValue.modifiers)
    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: statusIcon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(statusColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusTitle)
                        .font(.headline)
                    Text(statusHint)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            Picker("Mode", selection: $pipeline.mode) {
                ForEach(Mode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if !pipeline.transcript.isEmpty || !pipeline.output.isEmpty || isError {
                VStack(alignment: .leading, spacing: 8) {
                    if !pipeline.transcript.isEmpty {
                        Text("Transcript")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(pipeline.transcript)
                            .font(.body)
                            .lineLimit(3)
                    }

                    if case .error(let message) = pipeline.state {
                        Text(message)
                            .font(.caption)
                            .foregroundColor(.red)
                            .lineLimit(3)
                    } else if !pipeline.output.isEmpty {
                        Text("Output")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(pipeline.output)
                            .font(.body)
                            .lineLimit(3)
                    }
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor).opacity(0.65))
                )
            }

            HStack(spacing: 8) {
                Button(primaryButtonTitle) {
                    pipeline.toggleRecord()
                }
                .buttonStyle(.borderedProminent)

                if case .ready = pipeline.state {
                    Button("Insert") {
                        pipeline.insertToFocusedApp()
                    }
                    .buttonStyle(.bordered)

                    Button(didCopy ? "Copied" : "Copy") {
                        copyResult()
                    }
                    .buttonStyle(.bordered)
                }

                if case .error = pipeline.state {
                    Button("Open Settings") {
                        onOpenSettings()
                    }
                    .buttonStyle(.bordered)
                }

                if pipeline.state != .idle {
                    Button("Cancel") {
                        pipeline.cancel()
                    }
                    .buttonStyle(.bordered)
                }
            }

            Text(shortcutHint)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(16)
        .frame(width: 380)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var statusTitle: String {
        switch pipeline.state {
        case .idle:
            return "Idle"
        case .recording:
            return "Recording"
        case .transcribing:
            return "Transcribing"
        case .generating:
            return "Generating"
        case .ready:
            return "Ready"
        case .error:
            return "Error"
        }
    }

    private var statusHint: String {
        switch pipeline.state {
        case .idle:
            return "Hold \(activationDisplay) to speak"
        case .recording:
            return "Release \(activationDisplay) to stop"
        case .transcribing, .generating:
            return "Working..."
        case .ready:
            return "Enter to insert"
        case .error:
            return "Review setup or try again"
        }
    }

    private var primaryButtonTitle: String {
        switch pipeline.state {
        case .recording:
            return "Stop"
        case .error:
            return "Try Again"
        default:
            return "Record"
        }
    }

    private var isError: Bool {
        if case .error = pipeline.state {
            return true
        }
        return false
    }

    private var statusIcon: String {
        switch pipeline.state {
        case .recording:
            return "waveform"
        case .transcribing, .generating:
            return "sparkles"
        case .ready:
            return "checkmark.circle"
        case .error:
            return "exclamationmark.triangle"
        default:
            return "mic.circle"
        }
    }

    private var statusColor: Color {
        switch pipeline.state {
        case .recording:
            return .green
        case .transcribing, .generating:
            return .orange
        case .ready:
            return .blue
        case .error:
            return .red
        default:
            return .secondary
        }
    }

    private var shortcutHint: String {
        "Clipboard: \(clipboardDisplay) | Translate: \(translateDisplay)"
    }

    private var activationDisplay: String {
        ActivationKeyPreference(
            keyCode: UInt32(activationKeyCode),
            modifiers: UInt32(activationModifiers)
        ).displayString
    }

    private var clipboardDisplay: String {
        let clipboardPreference = HotKeyPreference(
            keyCode: UInt32(clipboardKeyCode),
            modifiers: UInt32(clipboardModifiers)
        )
        return (clipboardPreference.isValid ? clipboardPreference : HotKeyPreference.defaultValue).displayString
    }

    private var translateDisplay: String {
        TranslateHotKeyPreference.load().displayString
    }

    private func copyResult() {
        let text = pipeline.output.isEmpty ? pipeline.transcript : pipeline.output
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        didCopy = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            didCopy = false
        }
    }
}
