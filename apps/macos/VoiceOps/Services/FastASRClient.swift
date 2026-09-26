import Foundation

final class FastASRClient {
    private let baseURL = URL(string: "http://127.0.0.1:8790")!
    private let session: URLSession
    private let token: String

    init(token: String = SidecarLauncher.shared.localToken) {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 6
        config.timeoutIntervalForResource = 6
        self.session = URLSession(configuration: config)
        self.token = token
    }

    struct StartResp: Decodable {
        let session_id: String
    }

    struct PushReq: Encodable {
        let session_id: String
        let samples_b64: String
        let sample_rate: Int
    }

    struct PushResp: Decodable {
        let text: String
        let latency_ms: Int?
    }

    struct EndReq: Encodable {
        let session_id: String
    }

    struct EndResp: Decodable {
        let text: String
    }

    func startSession() async throws -> String {
        var req = URLRequest(url: baseURL.appendingPathComponent("/v1/fast_asr/start"))
        req.httpMethod = "POST"
        authorize(&req)
        let (data, resp) = try await session.data(for: req)
        try validate(resp: resp)
        return try JSONDecoder().decode(StartResp.self, from: data).session_id
    }

    func pushSamples(sessionID: String, samples: Data, sampleRate: Int) async throws -> (String, Int?) {
        let payload = PushReq(
            session_id: sessionID,
            samples_b64: samples.base64EncodedString(),
            sample_rate: sampleRate
        )
        var req = URLRequest(url: baseURL.appendingPathComponent("/v1/fast_asr/push"))
        req.httpMethod = "POST"
        authorize(&req)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(payload)

        let (data, resp) = try await session.data(for: req)
        try validate(resp: resp)
        let decoded = try JSONDecoder().decode(PushResp.self, from: data)
        return (decoded.text, decoded.latency_ms)
    }

    func endSession(sessionID: String) async throws -> String {
        let payload = EndReq(session_id: sessionID)
        var req = URLRequest(url: baseURL.appendingPathComponent("/v1/fast_asr/end"))
        req.httpMethod = "POST"
        authorize(&req)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(payload)

        let (data, resp) = try await session.data(for: req)
        try validate(resp: resp)
        return try JSONDecoder().decode(EndResp.self, from: data).text
    }

    private func validate(resp: URLResponse) throws {
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "FastASRClient", code: 1)
        }
    }

    private func authorize(_ request: inout URLRequest) {
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
}
