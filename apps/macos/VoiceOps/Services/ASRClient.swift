import Foundation

protocol FinalASRTranscribing {
    func transcribeDetailed(wavURL: URL) async throws -> ASRClient.Transcription
}

final class ASRClient: FinalASRTranscribing {
    private let baseURL = URL(string: "http://127.0.0.1:8765")!
    private let session: URLSession
    private let localToken: String

    struct Resp: Decodable {
        let text: String
        let queue_ms: Int?
        let infer_ms: Int?
        let total_ms: Int?
        let model_id: String?
        let model_hash: String?
    }

    struct Transcription: Sendable {
        let text: String
        let queueMs: Int?
        let inferMs: Int?
        let totalMs: Int?
        let modelID: String?
        let modelHash: String?
    }

    init(
        session: URLSession = ASRClient.makeSession(),
        localToken: String = SidecarLauncher.shared.localToken
    ) {
        self.session = session
        self.localToken = localToken
    }

    func transcribe(wavURL: URL) async throws -> String {
        try await transcribeDetailed(wavURL: wavURL).text
    }

    func transcribeDetailed(wavURL: URL) async throws -> Transcription {
        var request = URLRequest(url: baseURL.appendingPathComponent("/v1/asr/transcribe-wav"))
        request.httpMethod = "POST"
        request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        authorize(&request)
        let (data, response) = try await session.upload(for: request, fromFile: wavURL)
        if (response as? HTTPURLResponse)?.statusCode == 404 {
            // Sidecars installed before the streaming upload endpoint existed
            // still support the multipart endpoint. Keep upgrades seamless while
            // the launcher replaces that process on the next clean restart.
            return try await transcribeDetailed(wavData: Data(contentsOf: wavURL))
        }
        return try decode(data: data, response: response)
    }

    func transcribe(wavData: Data) async throws -> String {
        try await transcribeDetailed(wavData: wavData).text
    }

    func transcribeDetailed(wavData: Data) async throws -> Transcription {
        var req = URLRequest(url: baseURL.appendingPathComponent("/v1/asr/transcribe"))
        req.httpMethod = "POST"
        authorize(&req)

        let boundary = "----VoiceOpsBoundary\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func add(_ s: String) { body.append(s.data(using: .utf8)!) }

        add("--\(boundary)\r\n")
        add("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n")
        add("Content-Type: audio/wav\r\n\r\n")
        body.append(wavData)
        add("\r\n--\(boundary)--\r\n")

        req.httpBody = body

        let (data, resp) = try await session.data(for: req)
        return try decode(data: data, response: resp)
    }

    private func decode(data: Data, response: URLResponse) throws -> Transcription {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "ASRClient", code: 1)
        }
        let response = try JSONDecoder().decode(Resp.self, from: data)
        return Transcription(
            text: response.text,
            queueMs: response.queue_ms,
            inferMs: response.infer_ms,
            totalMs: response.total_ms,
            modelID: response.model_id,
            modelHash: response.model_hash
        )
    }

    private func authorize(_ request: inout URLRequest) {
        guard !localToken.isEmpty else { return }
        request.setValue("Bearer \(localToken)", forHTTPHeaderField: "Authorization")
    }

    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 120
        return URLSession(configuration: config)
    }
}
