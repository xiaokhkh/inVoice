import Foundation

struct FnSessionContext: Equatable, Sendable {
    let id: UUID
    let targetPID: Int32?
    let targetBundleID: String?
}

struct FnSessionStateMachine {
    enum Phase: String, Equatable, Sendable {
        case idle
        case starting
        case listening
        case processing
        case inserting
    }

    enum StopAction: Equatable, Sendable {
        case ignored
        case deferred(UUID)
        case stopListening(UUID)
    }

    private struct ActiveSession: Equatable, Sendable {
        let context: FnSessionContext
        var pendingStop = false
        var deliveryClaimed = false
    }

    private(set) var phase: Phase = .idle
    private(set) var cooldownUntil: TimeInterval = 0
    private var active: ActiveSession?
    private let cooldownDuration: TimeInterval

    init(cooldownDuration: TimeInterval = 0.2) {
        self.cooldownDuration = max(0, cooldownDuration)
    }

    var currentContext: FnSessionContext? {
        active?.context
    }

    mutating func begin(
        targetPID: Int32?,
        targetBundleID: String?,
        now: TimeInterval,
        id: UUID = UUID()
    ) -> FnSessionContext? {
        guard phase == .idle, active == nil, now >= cooldownUntil else {
            return nil
        }

        let context = FnSessionContext(
            id: id,
            targetPID: targetPID,
            targetBundleID: targetBundleID
        )
        active = ActiveSession(context: context)
        phase = .starting
        return context
    }

    mutating func requestStop() -> StopAction {
        guard var active else { return .ignored }

        switch phase {
        case .starting:
            active.pendingStop = true
            self.active = active
            return .deferred(active.context.id)
        case .listening:
            phase = .processing
            return .stopListening(active.context.id)
        case .idle, .processing, .inserting:
            return .ignored
        }
    }

    /// Moves a successfully started audio session into listening.
    /// Returns `true` when key-up happened during startup and recording must
    /// be stopped immediately.
    mutating func recordingDidStart(sessionID: UUID) -> Bool? {
        guard phase == .starting,
              let active,
              active.context.id == sessionID else {
            return nil
        }

        if active.pendingStop {
            phase = .processing
            return true
        }

        phase = .listening
        return false
    }

    /// Claims the only delivery slot for the current session.
    mutating func claimInsertion(sessionID: UUID) -> Bool {
        guard phase == .processing,
              var active,
              active.context.id == sessionID,
              !active.deliveryClaimed else {
            return false
        }

        active.deliveryClaimed = true
        self.active = active
        phase = .inserting
        return true
    }

    func isCurrent(_ sessionID: UUID, phase expectedPhase: Phase? = nil) -> Bool {
        guard active?.context.id == sessionID else { return false }
        guard let expectedPhase else { return true }
        return phase == expectedPhase
    }

    func context(for sessionID: UUID) -> FnSessionContext? {
        guard active?.context.id == sessionID else { return nil }
        return active?.context
    }

    @discardableResult
    mutating func complete(sessionID: UUID, now: TimeInterval) -> Bool {
        guard active?.context.id == sessionID else { return false }
        active = nil
        phase = .idle
        cooldownUntil = now + cooldownDuration
        return true
    }
}
