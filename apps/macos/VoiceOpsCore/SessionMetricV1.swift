import Foundation

struct SessionMetricV1: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    var schemaVersion = Self.schemaVersion
    var timestamp: Date
    var sessionID: UUID
    var asrMode: DictationASRMode
    var postProcessMode: DictationPostProcessMode
    var audioFrames: Int64 = 0
    var audioDurationMs: Int = 0
    var stopAtMs: Int?
    var audioDrainMs: Int?
    var firstPartialMs: Int?
    var partialCount: Int = 0
    var maxQueueDepth: Int = 0
    var droppedChunks: Int = 0
    var stopToStreamFinalMs: Int?
    var streamClean: Bool?
    var streamProtocolVersion: Int?
    var streamModelID: String?
    var streamModelHash: String?
    var fallbackReason: String?
    var finalASRQueueMs: Int?
    var finalASRInferMs: Int?
    var finalASRTotalMs: Int?
    var finalASRSource: String?
    var finalASRModelID: String?
    var finalASRModelHash: String?
    var llmWarmupMs: Int?
    var llmMs: Int?
    var llmLoadMs: Int?
    var llmPromptEvalMs: Int?
    var llmGenerateMs: Int?
    var llmFailureReason: String?
    var injectMs: Int?
    var endToEndMs: Int?
    var deliveryStatus: String?
    var outcome: String

    init(
        timestamp: Date = Date(),
        sessionID: UUID,
        asrMode: DictationASRMode,
        postProcessMode: DictationPostProcessMode,
        outcome: String = "started"
    ) {
        self.timestamp = timestamp
        self.sessionID = sessionID
        self.asrMode = asrMode
        self.postProcessMode = postProcessMode
        self.outcome = outcome
    }
}
