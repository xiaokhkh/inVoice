import XCTest
@testable import VoiceOpsCore

final class ProductExperienceTests: XCTestCase {
    func testSensitiveClipboardTypesAreNeverCaptured() {
        for type in ClipboardCapturePolicy.sensitiveTypes {
            XCTAssertFalse(ClipboardCapturePolicy.shouldCapture(types: ["public.utf8-plain-text", type], enabled: true))
        }
        XCTAssertTrue(ClipboardCapturePolicy.shouldCapture(types: ["public.utf8-plain-text"], enabled: true))
        XCTAssertFalse(ClipboardCapturePolicy.shouldCapture(types: ["public.png"], enabled: false))
    }

    func testResponseTimeExcludesSpeakingAndFailures() {
        let metrics = [metric(stop: 12_000, end: 14_000), metric(stop: 1_000, end: 2_000),
                       metric(stop: 1_000, end: 20_000, outcome: "final_asr_failed")]
        let summary = SessionSummary(metrics: metrics)
        XCTAssertEqual(summary.completedCount, 2)
        XCTAssertEqual(summary.medianResponseMs, 1_500)
        XCTAssertEqual(summary.latestResponseMs, 1_000)
    }

    func testAbsentOrInvalidTimingsDoNotBecomeZeroLatency() {
        var missing = metric(stop: 1_000, end: 2_000)
        missing.stopAtMs = nil
        let summary = SessionSummary(metrics: [missing, metric(stop: 3_000, end: 2_000)])
        XCTAssertEqual(summary.completedCount, 2)
        XCTAssertNil(summary.medianResponseMs)
        XCTAssertNil(SessionSummary().latestResponseMs)
    }

    func testHealthRequiresIdentityVersionAndReadyState() throws {
        for json in [
            #"{"status":"ok","service":"another-app","protocol_version":1}"#,
            #"{"status":"loading","service":"voiceops-asr-mlx","protocol_version":1}"#,
            #"{"status":"ok","service":"voiceops-asr-mlx","protocol_version":2}"#,
        ] {
            let health = try JSONDecoder().decode(LocalServiceHealth.self, from: Data(json.utf8))
            XCTAssertFalse(health.isReady(expectedService: "voiceops-asr-mlx"))
        }
        let health = try JSONDecoder().decode(LocalServiceHealth.self, from: Data(
            #"{"status":"ok","service":"voiceops-asr-mlx","protocol_version":1}"#.utf8))
        XCTAssertTrue(health.isReady(expectedService: "voiceops-asr-mlx"))
    }

    func testExplicitOutputPreferenceSurvivesDefault() {
        let name = "ProductExperienceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(DictationPreferences.postProcessMode(userDefaults: defaults), .translateAndPolish)
        defaults.set("direct", forKey: DictationPostProcessMode.defaultsKey)
        XCTAssertEqual(DictationPreferences.postProcessMode(userDefaults: defaults), .direct)
    }

    private func metric(stop: Int, end: Int, outcome: String = "delivered") -> SessionMetricV1 {
        var metric = SessionMetricV1(sessionID: UUID(), asrMode: .accurate, postProcessMode: .direct, outcome: outcome)
        metric.stopAtMs = stop
        metric.endToEndMs = end
        return metric
    }
}
