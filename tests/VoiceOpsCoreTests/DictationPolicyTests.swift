import XCTest
@testable import VoiceOpsCore

final class DictationPolicyTests: XCTestCase {
    func testAccurateModeAlwaysUsesFinalASR() {
        let decision = StreamingASRPolicy().decide(mode: .accurate, result: cleanResult())
        XCTAssertEqual(decision, .useFinalASR(reason: "accurate_mode"))
    }

    func testFastModeAcceptsOnlyCompleteCleanResult() {
        XCTAssertEqual(
            StreamingASRPolicy().decide(mode: .fast, result: cleanResult(text: "hello")),
            .useStreaming("hello")
        )

        let incomplete = result(clean: true, receivedFrames: 1_599, expectedFrames: 1_600)
        XCTAssertEqual(
            StreamingASRPolicy().decide(mode: .fast, result: incomplete),
            .useFinalASR(reason: "frame_count_mismatch")
        )
    }

    func testAdaptiveModeRequiresApprovalAndStability() {
        let result = cleanResult(text: "测试 build")
        let unapproved = StreamingASRPolicy().decide(mode: .adaptive, result: result)
        XCTAssertEqual(unapproved, .useFinalASR(reason: "script_class_not_approved"))

        let policy = StreamingASRPolicy(approvedAdaptiveClasses: [.mixed])
        XCTAssertEqual(policy.decide(mode: .adaptive, result: result), .useStreaming("测试 build"))
    }

    func testTruncatedResultAlwaysFallsBack() {
        let truncated = result(clean: false, truncated: true, reason: "sequence_gap")
        XCTAssertEqual(
            StreamingASRPolicy().decide(mode: .fast, result: truncated),
            .useFinalASR(reason: "sequence_gap")
        )
    }

    func testScriptClassification() {
        XCTAssertEqual(StreamingScriptClass.classify("hello"), .latin)
        XCTAssertEqual(StreamingScriptClass.classify("你好"), .cjk)
        XCTAssertEqual(StreamingScriptClass.classify("你好 Swift"), .mixed)
    }

    func testBinaryAudioFrameUsesLittleEndianSequenceHeader() {
        let pcm = Data([1, 2, 3, 4])
        let frame = StreamingWireCodec.makeAudioFrame(sequence: 42, pcmFloat32LE: pcm)
        XCTAssertEqual(frame.count, 12)
        XCTAssertEqual(StreamingWireCodec.sequence(fromAudioFrame: frame), 42)
        XCTAssertEqual(frame.suffix(4), pcm)
    }

    func testAllPostProcessModesHaveExplicitRoutes() {
        let policy = DictationPostProcessPolicy()
        XCTAssertEqual(policy.action(for: .translateAndPolish), .translateAndPolish)
        XCTAssertTrue(policy.action(for: .translateAndPolish).requiresLLM)
        XCTAssertEqual(policy.action(for: .direct), .direct)
        XCTAssertFalse(policy.action(for: .direct).requiresLLM)
        XCTAssertEqual(policy.action(for: .polishSameLanguage), .polishSameLanguage)
        XCTAssertTrue(policy.action(for: .polishSameLanguage).requiresLLM)
    }

    func testBoundedQueueReportsOverflowAndKeepsSequenceOrder() {
        var queue = BoundedStreamingAudioQueue(capacity: 2)
        XCTAssertEqual(queue.enqueue(Data(repeating: 0, count: 16)), .enqueued)
        XCTAssertEqual(queue.enqueue(Data(repeating: 1, count: 8)), .enqueued)
        XCTAssertEqual(queue.enqueue(Data(repeating: 2, count: 4)), .overflow)
        XCTAssertEqual(queue.popFirst()?.sequence, 0)
        XCTAssertEqual(queue.popFirst()?.sequence, 1)
        XCTAssertNil(queue.popFirst())
    }

    func testPCMChunkerPreservesSub100msTail() {
        var chunker = Float32PCMChunker(targetFrames: 1_600)
        let input = Data(repeating: 0, count: (3_200 + 137) * MemoryLayout<Float>.size)
        let chunks = chunker.append(input)
        XCTAssertEqual(chunks?.map(\.count), [6_400, 6_400])
        XCTAssertEqual(chunker.finishTail()?.count, 137 * MemoryLayout<Float>.size)
        XCTAssertNil(chunker.finishTail())
    }

    func testPreferencesFailClosedUntilStreamingFinalsAreApproved() {
        let suiteName = "DictationPolicyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(DictationASRMode.fast.rawValue, forKey: DictationASRMode.defaultsKey)
        XCTAssertEqual(DictationPreferences.asrMode(userDefaults: defaults), .accurate)
        defaults.set(true, forKey: DictationPreferences.streamingFinalsApprovedKey)
        XCTAssertEqual(DictationPreferences.asrMode(userDefaults: defaults), .fast)
    }

    private func cleanResult(text: String = "hello") -> StreamingFinalResult {
        result(text: text, clean: true)
    }

    private func result(
        text: String = "hello",
        clean: Bool,
        truncated: Bool = false,
        reason: String? = nil,
        receivedFrames: Int64 = 1_600,
        expectedFrames: Int64 = 1_600
    ) -> StreamingFinalResult {
        StreamingFinalResult(
            sessionID: UUID(),
            text: text,
            receivedFrames: receivedFrames,
            expectedFrames: expectedFrames,
            lastSequence: 0,
            clean: clean,
            truncated: truncated,
            reason: reason,
            stableRevisionCount: 2,
            stableDurationMs: 300,
            modelID: "test",
            modelHash: "test-hash",
            protocolVersion: 1
        )
    }
}
