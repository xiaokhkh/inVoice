import Foundation

/// Exercises the shipping clients against the installed local services.
/// Input is a synthetic speech fixture; no microphone or user clipboard is read.
@main
struct LocalProductSmoke {
    @MainActor
    static func main() async throws {
        guard CommandLine.arguments.count == 2,
              let token = UserDefaults(suiteName: "com.voiceops.VoiceOps")?
                .string(forKey: "voiceops.sidecar.localToken") else {
            throw failure("Expected a synthetic WAV path and an installed inVoice token")
        }
        let asr = ASRClient(localToken: token)
        let result = try await asr.transcribeDetailed(wavURL: URL(fileURLWithPath: CommandLine.arguments[1]))
        guard result.text.contains("周五") else { throw failure("ASR lost the synthetic fixture's Friday deadline") }
        print("ASR passed; server time: \(result.totalMs ?? -1) ms")

        let client = OfflineLLMClient(model: OfflineLLMClient.defaultModel)
        _ = await client.warmUp()
        let translation = try await client.translateDetailed(text: result.text, profile: .voice)
        guard translation.text.range(of: "Friday", options: .caseInsensitive) != nil else {
            throw failure("English output did not preserve the deadline")
        }
        print("English dictation passed; request: \(translation.requestMs) ms; output: \(translation.text)")

        var streamed = ""
        let answer = try await client.chatStream(
            messages: [.init(role: "user", content: "Reply with exactly READY", applyTemplate: false)],
            profile: .assistant
        ) { streamed += $0 }
        guard answer.contains("READY"), !streamed.isEmpty else { throw failure("Assistant stream failed") }
        print("Assistant streaming passed")

        let missingModelRouter = LLMRouter(offlineClient: OfflineLLMClient(model: "invoice-missing-model-qa"))
        let original = "Keep this text when the model is unavailable."
        let fallback = await missingModelRouter.route(text: original, mode: .translateAndPolish)
        guard fallback.text == original, !fallback.offlineUsed else { throw failure("Offline fallback lost text") }
        let direct = await missingModelRouter.route(text: original, mode: .direct)
        guard direct.text == original, direct.offlineLatencyMs == 0 else { throw failure("Direct mode called the model") }
        print("Unavailable-model fallback and direct mode passed")
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "LocalProductSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
