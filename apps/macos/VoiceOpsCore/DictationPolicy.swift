import Foundation

enum DictationASRMode: String, CaseIterable, Codable, Sendable {
    case accurate
    case fast
    case adaptive

    static let defaultsKey = "dictationASRMode"
    static let defaultValue: DictationASRMode = .accurate
}

enum DictationPostProcessMode: String, CaseIterable, Codable, Sendable {
    case translateAndPolish
    case direct
    case polishSameLanguage

    static let defaultsKey = "dictationPostProcessMode"
    static let defaultValue: DictationPostProcessMode = .translateAndPolish
}

enum DictationPostProcessAction: String, Equatable, Sendable {
    case translateAndPolish
    case direct
    case polishSameLanguage

    var requiresLLM: Bool { self != .direct }
}

struct DictationPostProcessPolicy: Sendable {
    func action(for mode: DictationPostProcessMode) -> DictationPostProcessAction {
        switch mode {
        case .translateAndPolish: return .translateAndPolish
        case .direct: return .direct
        case .polishSameLanguage: return .polishSameLanguage
        }
    }
}

enum StreamingScriptClass: String, Codable, Hashable, Sendable {
    case latin
    case cjk
    case mixed

    static func classify(_ text: String) -> StreamingScriptClass {
        var containsLatin = false
        var containsCJK = false

        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0041...0x005A, 0x0061...0x007A:
                containsLatin = true
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:
                containsCJK = true
            default:
                continue
            }
        }

        if containsLatin && containsCJK { return .mixed }
        if containsCJK { return .cjk }
        return .latin
    }
}

struct StreamingFinalResult: Equatable, Codable, Sendable {
    let sessionID: UUID
    let text: String
    let receivedFrames: Int64
    let expectedFrames: Int64
    let lastSequence: UInt64?
    let clean: Bool
    let truncated: Bool
    let reason: String?
    let stableRevisionCount: Int
    let stableDurationMs: Int
    let modelID: String?
    let modelHash: String?
    let protocolVersion: Int

    var hasCompleteFrameCount: Bool {
        receivedFrames == expectedFrames
    }
}

enum StreamingASRDecision: Equatable, Sendable {
    case useStreaming(String)
    case useFinalASR(reason: String)
}

struct StreamingASRPolicy: Sendable {
    static let requiredProtocolVersion = 1

    let approvedAdaptiveClasses: Set<StreamingScriptClass>
    let requiredStableRevisionCount: Int
    let requiredStableDurationMs: Int

    init(
        approvedAdaptiveClasses: Set<StreamingScriptClass> = [],
        requiredStableRevisionCount: Int = 2,
        requiredStableDurationMs: Int = 300
    ) {
        self.approvedAdaptiveClasses = approvedAdaptiveClasses
        self.requiredStableRevisionCount = max(1, requiredStableRevisionCount)
        self.requiredStableDurationMs = max(0, requiredStableDurationMs)
    }

    func decide(mode: DictationASRMode, result: StreamingFinalResult?) -> StreamingASRDecision {
        guard mode != .accurate else {
            return .useFinalASR(reason: "accurate_mode")
        }
        guard let result else {
            return .useFinalASR(reason: "stream_missing")
        }
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return .useFinalASR(reason: "stream_empty")
        }
        guard result.protocolVersion == Self.requiredProtocolVersion else {
            return .useFinalASR(reason: "protocol_mismatch")
        }
        guard result.clean, !result.truncated else {
            return .useFinalASR(reason: result.reason ?? "stream_not_clean")
        }
        guard result.hasCompleteFrameCount else {
            return .useFinalASR(reason: "frame_count_mismatch")
        }

        if mode == .adaptive {
            let scriptClass = StreamingScriptClass.classify(text)
            guard approvedAdaptiveClasses.contains(scriptClass) else {
                return .useFinalASR(reason: "script_class_not_approved")
            }
            guard result.stableRevisionCount >= requiredStableRevisionCount else {
                return .useFinalASR(reason: "insufficient_stable_revisions")
            }
            guard result.stableDurationMs >= requiredStableDurationMs else {
                return .useFinalASR(reason: "insufficient_stability_duration")
            }
        }

        return .useStreaming(text)
    }
}

enum DictationPreferences {
    static let streamingFinalsApprovedKey = "streamingFinalsApproved"
    static let approvedAdaptiveClassesKey = "approvedAdaptiveScriptClasses"

    static func asrMode(userDefaults: UserDefaults = .standard) -> DictationASRMode {
        guard userDefaults.bool(forKey: streamingFinalsApprovedKey),
              let raw = userDefaults.string(forKey: DictationASRMode.defaultsKey),
              let mode = DictationASRMode(rawValue: raw) else {
            return .accurate
        }
        return mode
    }

    static func postProcessMode(
        userDefaults: UserDefaults = .standard
    ) -> DictationPostProcessMode {
        guard let raw = userDefaults.string(forKey: DictationPostProcessMode.defaultsKey),
              let mode = DictationPostProcessMode(rawValue: raw) else {
            return .defaultValue
        }
        return mode
    }

    static func approvedAdaptiveClasses(
        userDefaults: UserDefaults = .standard
    ) -> Set<StreamingScriptClass> {
        let rawValues = userDefaults.stringArray(forKey: approvedAdaptiveClassesKey) ?? []
        return Set(rawValues.compactMap(StreamingScriptClass.init(rawValue:)))
    }
}

enum StreamingWireCodec {
    static func makeAudioFrame(sequence: UInt64, pcmFloat32LE: Data) -> Data {
        var littleEndianSequence = sequence.littleEndian
        var frame = Data(bytes: &littleEndianSequence, count: MemoryLayout<UInt64>.size)
        frame.append(pcmFloat32LE)
        return frame
    }

    static func sequence(fromAudioFrame frame: Data) -> UInt64? {
        guard frame.count >= MemoryLayout<UInt64>.size else { return nil }
        return frame.prefix(MemoryLayout<UInt64>.size).withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return nil }
            return UInt64(littleEndian: baseAddress.loadUnaligned(as: UInt64.self))
        }
    }
}

struct StreamingAudioChunk: Equatable, Sendable {
    let sequence: UInt64
    let data: Data
    let frames: Int64
}

enum StreamingQueueEnqueueResult: Equatable, Sendable {
    case enqueued
    case overflow
    case invalidPCM
}

struct BoundedStreamingAudioQueue: Sendable {
    let capacity: Int
    private(set) var nextSequence: UInt64 = 0
    private var chunks: [StreamingAudioChunk] = []
    private var head = 0

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    var count: Int { max(0, chunks.count - head) }

    mutating func enqueue(_ pcmFloat32LE: Data) -> StreamingQueueEnqueueResult {
        guard !pcmFloat32LE.isEmpty, pcmFloat32LE.count.isMultiple(of: MemoryLayout<Float>.size) else {
            return .invalidPCM
        }
        guard count < capacity else { return .overflow }
        chunks.append(
            StreamingAudioChunk(
                sequence: nextSequence,
                data: pcmFloat32LE,
                frames: Int64(pcmFloat32LE.count / MemoryLayout<Float>.size)
            )
        )
        nextSequence &+= 1
        return .enqueued
    }

    mutating func popFirst() -> StreamingAudioChunk? {
        guard head < chunks.count else { return nil }
        let chunk = chunks[head]
        head += 1
        if head >= 64, head * 2 >= chunks.count {
            chunks.removeFirst(head)
            head = 0
        }
        return chunk
    }

    mutating func removeAll() {
        chunks.removeAll(keepingCapacity: false)
        head = 0
    }
}

struct Float32PCMChunker: Sendable {
    let targetFrames: Int
    private var accumulated = Data()

    init(targetFrames: Int) {
        self.targetFrames = max(1, targetFrames)
    }

    mutating func append(_ pcmFloat32LE: Data) -> [Data]? {
        guard pcmFloat32LE.count.isMultiple(of: MemoryLayout<Float>.size) else { return nil }
        accumulated.append(pcmFloat32LE)
        let targetBytes = targetFrames * MemoryLayout<Float>.size
        var chunks: [Data] = []
        while accumulated.count >= targetBytes {
            chunks.append(Data(accumulated.prefix(targetBytes)))
            accumulated.removeSubrange(0..<targetBytes)
        }
        return chunks
    }

    mutating func finishTail() -> Data? {
        guard !accumulated.isEmpty else { return nil }
        let tail = accumulated
        accumulated.removeAll(keepingCapacity: false)
        return tail
    }

    mutating func reset() {
        accumulated.removeAll(keepingCapacity: false)
    }
}
