import Foundation

typealias StreamingPartialHandler = @Sendable (
    _ text: String,
    _ latencyMs: Int?,
    _ receivedFrames: Int64
) -> Void

protocol StreamingASRServing {
    func start(sessionID: UUID, onPartial: @escaping StreamingPartialHandler) async throws
    func send(sessionID: UUID, samples: Data, sequence: UInt64) async throws
    func finish(
        sessionID: UUID,
        lastSequence: UInt64?,
        totalFrames: Int64,
        timeoutMs: Int
    ) async -> StreamingFinalResult
    func abort() async
}

actor StreamingASRClient: StreamingASRServing {
    enum ClientError: Error {
        case invalidHealth
        case startTimeout
        case notStarted
        case sessionMismatch
        case alreadyFinishing
        case cancelled
    }

    private struct Health: Decodable {
        let service: String
        let protocol_version: Int
        let model_id: String
        let model_sha256: String
    }

    private struct ServerEvent: Decodable {
        let type: String
        let session_id: String?
        let text: String?
        let revision: Int?
        let received_frames: Int64?
        let expected_frames: Int64?
        let last_sequence: UInt64?
        let clean: Bool?
        let truncated: Bool?
        let reason: String?
        let stable_revision_count: Int?
        let stable_duration_ms: Int?
        let model_id: String?
        let model_sha256: String?
        let protocol_version: Int?
        let latency_ms: Int?
    }

    private let httpURL = URL(string: "http://127.0.0.1:8790")!
    private let webSocketURL = URL(string: "ws://127.0.0.1:8790/v1/fast_asr/ws")!
    private let session: URLSession
    private let localToken: String

    private var webSocket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var sessionID: UUID?
    private var modelID: String?
    private var modelHash: String?
    private var started = false
    private var finishRequested = false
    private var completedResult: StreamingFinalResult?
    private var failureReason: String?
    private var partialHandler: StreamingPartialHandler?
    private var operationID: UUID?

    init(
        session: URLSession = StreamingASRClient.makeSession(),
        localToken: String = SidecarLauncher.shared.localToken
    ) {
        self.session = session
        self.localToken = localToken
    }

    func start(sessionID: UUID, onPartial: @escaping StreamingPartialHandler) async throws {
        await abort()
        let operationID = UUID()
        self.operationID = operationID
        let health = try await validateHealth()
        guard self.operationID == operationID, !Task.isCancelled else {
            throw ClientError.cancelled
        }
        guard health.service == "voiceops-fast-asr",
              health.protocol_version == StreamingASRPolicy.requiredProtocolVersion else {
            throw ClientError.invalidHealth
        }

        var request = URLRequest(url: webSocketURL)
        authorize(&request)
        let socket = session.webSocketTask(with: request)
        self.webSocket = socket
        self.sessionID = sessionID
        self.modelID = health.model_id
        self.modelHash = health.model_sha256
        self.partialHandler = onPartial
        self.started = false
        self.finishRequested = false
        self.completedResult = nil
        self.failureReason = nil
        socket.resume()
        receiveTask = Task { [weak self] in
            await self?.receiveLoop(socket: socket)
        }

        let payload: [String: Any] = [
            "type": "start",
            "protocol_version": StreamingASRPolicy.requiredProtocolVersion,
            "session_id": sessionID.uuidString,
            "sample_rate": 16_000,
            "channels": 1,
            "format": "f32le",
        ]
        try await sendJSON(payload, on: socket)
        guard self.operationID == operationID, !Task.isCancelled else {
            socket.cancel(with: .goingAway, reason: nil)
            throw ClientError.cancelled
        }

        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while self.operationID == operationID,
              !Task.isCancelled,
              !started,
              failureReason == nil,
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard self.operationID == operationID, !Task.isCancelled else {
            throw ClientError.cancelled
        }
        guard started else {
            failureReason = failureReason ?? "start_timeout"
            throw ClientError.startTimeout
        }
    }

    func send(
        sessionID: UUID,
        samples: Data,
        sequence: UInt64
    ) async throws {
        guard self.sessionID == sessionID else { throw ClientError.sessionMismatch }
        guard started, let webSocket else { throw ClientError.notStarted }
        guard !finishRequested else {
            failureReason = failureReason ?? "audio_after_finish"
            throw ClientError.alreadyFinishing
        }
        let frame = StreamingWireCodec.makeAudioFrame(
            sequence: sequence,
            pcmFloat32LE: samples
        )
        do {
            try await webSocket.send(.data(frame))
        } catch {
            failureReason = failureReason ?? "send_failed"
            throw error
        }
    }

    func finish(
        sessionID: UUID,
        lastSequence: UInt64?,
        totalFrames: Int64,
        timeoutMs: Int = 800
    ) async -> StreamingFinalResult {
        if let completedResult { return completedResult }
        guard self.sessionID == sessionID, let webSocket, let operationID else {
            return failedResult(
                sessionID: sessionID,
                totalFrames: totalFrames,
                lastSequence: lastSequence,
                reason: "stream_not_started"
            )
        }

        if !finishRequested {
            finishRequested = true
            var payload: [String: Any] = [
                "type": "finish",
                "total_frames": totalFrames,
            ]
            if let lastSequence {
                payload["last_sequence"] = lastSequence
            } else {
                payload["last_sequence"] = NSNull()
            }
            do {
                try await sendJSON(payload, on: webSocket)
            } catch {
                failureReason = failureReason ?? "finish_send_failed"
            }
        }

        let deadline = ContinuousClock.now.advanced(by: .milliseconds(max(1, timeoutMs)))
        while self.operationID == operationID,
              !Task.isCancelled,
              completedResult == nil,
              failureReason == nil,
              ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        guard self.operationID == operationID, !Task.isCancelled else {
            return failedResult(
                sessionID: sessionID,
                totalFrames: totalFrames,
                lastSequence: lastSequence,
                reason: "stale_session"
            )
        }
        if let completedResult {
            return completedResult
        }

        let reason = failureReason ?? "finish_timeout"
        failureReason = reason
        webSocket.cancel(with: .goingAway, reason: nil)
        return failedResult(
            sessionID: sessionID,
            totalFrames: totalFrames,
            lastSequence: lastSequence,
            reason: reason
        )
    }

    func abort() async {
        if let webSocket, started, !finishRequested {
            try? await sendJSON(["type": "abort"], on: webSocket)
        }
        webSocket?.cancel(with: .goingAway, reason: nil)
        receiveTask?.cancel()
        webSocket = nil
        receiveTask = nil
        sessionID = nil
        modelID = nil
        modelHash = nil
        started = false
        finishRequested = false
        completedResult = nil
        failureReason = nil
        partialHandler = nil
        operationID = nil
    }

    private func receiveLoop(socket: URLSessionWebSocketTask) async {
        do {
            while !Task.isCancelled {
                let message = try await socket.receive()
                switch message {
                case .string(let value):
                    await consume(text: value, socket: socket)
                case .data(let data):
                    guard let value = String(data: data, encoding: .utf8) else { continue }
                    await consume(text: value, socket: socket)
                @unknown default:
                    continue
                }
            }
        } catch {
            if completedResult == nil, !Task.isCancelled {
                failureReason = failureReason ?? "connection_closed"
            }
        }
    }

    private func consume(text: String, socket: URLSessionWebSocketTask) async {
        guard webSocket === socket else { return }
        guard let data = text.data(using: .utf8),
              let event = try? JSONDecoder().decode(ServerEvent.self, from: data) else {
            failureReason = failureReason ?? "invalid_server_message"
            return
        }
        if let eventSessionID = event.session_id,
           let sessionID,
           eventSessionID.lowercased() != sessionID.uuidString.lowercased() {
            return
        }
        switch event.type {
        case "started":
            started = true
            modelID = event.model_id ?? modelID
            modelHash = event.model_sha256 ?? modelHash
        case "partial":
            partialHandler?(
                event.text ?? "",
                event.latency_ms,
                event.received_frames ?? 0
            )
        case "warning", "error":
            failureReason = failureReason ?? event.reason ?? "server_error"
        case "done":
            guard let sessionID else { return }
            completedResult = StreamingFinalResult(
                sessionID: sessionID,
                text: event.text ?? "",
                receivedFrames: event.received_frames ?? 0,
                expectedFrames: event.expected_frames ?? 0,
                lastSequence: event.last_sequence,
                clean: event.clean ?? false,
                truncated: event.truncated ?? true,
                reason: event.reason,
                stableRevisionCount: event.stable_revision_count ?? 0,
                stableDurationMs: event.stable_duration_ms ?? 0,
                modelID: event.model_id ?? modelID,
                modelHash: event.model_sha256 ?? modelHash,
                protocolVersion: event.protocol_version ?? 0
            )
        default:
            break
        }
    }

    private func validateHealth() async throws -> Health {
        var request = URLRequest(url: httpURL.appendingPathComponent("/health"))
        authorize(&request)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ClientError.invalidHealth
        }
        return try JSONDecoder().decode(Health.self, from: data)
    }

    private func sendJSON(_ payload: [String: Any], on socket: URLSessionWebSocketTask) async throws {
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let text = String(data: data, encoding: .utf8) else {
            throw ClientError.notStarted
        }
        try await socket.send(.string(text))
    }

    private func failedResult(
        sessionID: UUID,
        totalFrames: Int64,
        lastSequence: UInt64?,
        reason: String
    ) -> StreamingFinalResult {
        StreamingFinalResult(
            sessionID: sessionID,
            text: "",
            receivedFrames: 0,
            expectedFrames: totalFrames,
            lastSequence: lastSequence,
            clean: false,
            truncated: true,
            reason: reason,
            stableRevisionCount: 0,
            stableDurationMs: 0,
            modelID: modelID,
            modelHash: modelHash,
            protocolVersion: StreamingASRPolicy.requiredProtocolVersion
        )
    }

    private func authorize(_ request: inout URLRequest) {
        guard !localToken.isEmpty else { return }
        request.setValue("Bearer \(localToken)", forHTTPHeaderField: "Authorization")
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 6
        configuration.timeoutIntervalForResource = 180
        return URLSession(configuration: configuration)
    }
}
