import XCTest
@testable import VoiceOpsCore

final class FnSessionStateMachineTests: XCTestCase {
    func testReleaseDuringStartingStopsImmediatelyAfterAudioStarts() {
        var machine = FnSessionStateMachine(cooldownDuration: 0.2)
        let id = UUID()
        let session = machine.begin(
            targetPID: 42,
            targetBundleID: "test.target",
            now: 10,
            id: id
        )

        XCTAssertEqual(session?.id, id)
        XCTAssertEqual(machine.phase, .starting)
        XCTAssertEqual(machine.requestStop(), .deferred(id))
        XCTAssertEqual(machine.recordingDidStart(sessionID: id), true)
        XCTAssertEqual(machine.phase, .processing)
    }

    func testOneSessionCanClaimInsertionOnlyOnce() {
        var machine = FnSessionStateMachine(cooldownDuration: 0)
        let id = UUID()
        XCTAssertNotNil(machine.begin(targetPID: 1, targetBundleID: nil, now: 0, id: id))
        XCTAssertEqual(machine.recordingDidStart(sessionID: id), false)
        XCTAssertEqual(machine.requestStop(), .stopListening(id))

        XCTAssertTrue(machine.claimInsertion(sessionID: id))
        XCTAssertFalse(machine.claimInsertion(sessionID: id))
        XCTAssertEqual(machine.phase, .inserting)
    }

    func testStaleSessionCannotMutateCurrentSession() {
        var machine = FnSessionStateMachine(cooldownDuration: 0)
        let currentID = UUID()
        let staleID = UUID()
        XCTAssertNotNil(machine.begin(targetPID: 1, targetBundleID: nil, now: 0, id: currentID))

        XCTAssertNil(machine.recordingDidStart(sessionID: staleID))
        XCTAssertFalse(machine.claimInsertion(sessionID: staleID))
        XCTAssertFalse(machine.complete(sessionID: staleID, now: 1))
        XCTAssertTrue(machine.isCurrent(currentID, phase: .starting))
    }

    func testDuplicateBeginAndProcessingStopAreIgnored() {
        var machine = FnSessionStateMachine(cooldownDuration: 0)
        let id = UUID()
        XCTAssertNotNil(machine.begin(targetPID: 1, targetBundleID: nil, now: 0, id: id))
        XCTAssertNil(machine.begin(targetPID: 2, targetBundleID: nil, now: 0, id: UUID()))
        XCTAssertEqual(machine.recordingDidStart(sessionID: id), false)
        XCTAssertEqual(machine.requestStop(), .stopListening(id))
        XCTAssertEqual(machine.requestStop(), .ignored)
    }

    func testCooldownRejectsImmediateRetrigger() {
        var machine = FnSessionStateMachine(cooldownDuration: 0.2)
        let id = UUID()
        XCTAssertNotNil(machine.begin(targetPID: 1, targetBundleID: nil, now: 1, id: id))
        XCTAssertTrue(machine.complete(sessionID: id, now: 2))
        XCTAssertNil(machine.begin(targetPID: 1, targetBundleID: nil, now: 2.1))
        XCTAssertNotNil(machine.begin(targetPID: 1, targetBundleID: nil, now: 2.2))
    }
}
