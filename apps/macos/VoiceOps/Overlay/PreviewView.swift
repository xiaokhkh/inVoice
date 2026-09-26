import SwiftUI

struct PreviewView: View {
    @ObservedObject var model: PreviewModel
    let onDismiss: () -> Void
    let onCopy: (String) -> Void
    let onOpenSettings: () -> Void
    @State private var didCopy = false

    private let codexBlack = Color(white: 0.15)
    private let microphoneGray = Color(white: 0.27)
    private let borderGray = Color(white: 0.38)

    var body: some View {
        Group {
            switch model.state {
            case .recording:
                recordingContent
            case .processing:
                processingContent
            case .result:
                resultContent
            case .failure:
                failureContent
            case .idle:
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(codexBlack, in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(borderGray.opacity(0.9), lineWidth: 0.8)
        }
        .padding(PreviewLayout.renderingInset)
        .environment(\.colorScheme, .dark)
        .animation(.easeOut(duration: 0.16), value: model.state)
        .onChange(of: model.text) { _ in didCopy = false }
    }

    private var recordingContent: some View {
        HStack(spacing: 7) {
            Image(systemName: "mic.fill")
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(.white)
                .frame(width: 30, height: 30)
                .background(microphoneGray, in: Circle())

            if hasText {
                previewText
                    .transition(.opacity.combined(with: .move(edge: .leading)))
            }
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var processingContent: some View {
        HStack(spacing: 7) {
            ProgressView()
                .controlSize(.small)
                .tint(Color.white.opacity(0.72))
                .frame(width: 30, height: 30)

            if hasText {
                previewText
            }
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .transition(.opacity)
    }

    private var resultContent: some View {
        HStack(spacing: 8) {
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundColor(.white)
                    .frame(width: 30, height: 30)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("关闭")

            previewText
                .frame(maxWidth: .infinity, alignment: .center)

            Button {
                onCopy(displayText)
                didCopy = true
            } label: {
                Image(systemName: didCopy ? "checkmark" : "square.on.square")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundColor(.white)
                    .frame(width: 30, height: 30)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("文字已保留在剪贴板；点击再次复制")
        }
        .padding(.horizontal, 4)
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }

    private var failureContent: some View {
        HStack(spacing: 8) {
            Button(action: onDismiss) {
                Image(systemName: "xmark").frame(width: 24, height: 30)
            }.buttonStyle(.plain).foregroundColor(.white.opacity(0.7)).help("关闭")
            Image(systemName: "exclamationmark.circle.fill").foregroundColor(.orange)
            Text(displayText).font(.system(size: 12)).foregroundColor(.white).lineLimit(1)
            Spacer(minLength: 0)
            Button(action: onOpenSettings) {
                Image(systemName: "gearshape").frame(width: 28, height: 30)
            }.buttonStyle(.plain).foregroundColor(.white).help("打开权限与诊断")
        }.padding(.horizontal, 5)
    }

    private var previewText: some View {
        Text(displayText)
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(Color.white.opacity(0.96))
            .lineLimit(1)
            .truncationMode(.head)
            .animation(.easeOut(duration: 0.12), value: displayText)
    }

    private var hasText: Bool {
        !displayText.isEmpty
    }

    private var displayText: String {
        model.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
