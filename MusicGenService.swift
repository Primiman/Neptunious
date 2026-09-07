import Foundation

enum MusicGenError: LocalizedError {
    case missingToken
    case badResponse(String)
    case modelLoading(Int)
    case httpError(Int, String)

    var errorDescription: String? {
        switch self {
        case .missingToken:
            return "No Hugging Face API token set. Add one in Settings."
        case .badResponse(let msg):
            return "Bad response: \(msg)"
        case .modelLoading(let seconds):
            return "Model is warming up on Hugging Face's side (~\(seconds)s). Try again shortly."
        case .httpError(let code, let msg):
            return "HTTP \(code): \(msg)"
        }
    }
}

/// Talks to Hugging Face's free serverless Inference API running a MusicGen model.
/// Docs: https://huggingface.co/docs/api-inference
final class MusicGenService {

    // Swap this to "facebook/musicgen-medium" for better quality / slower & more likely to be rate limited.
    static let defaultModel = "facebook/musicgen-small"

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Generates audio for a text prompt. Returns raw audio data (wav/flac depending on model) on success.
    func generate(prompt: String, model: String = MusicGenService.defaultModel) async throws -> Data {
        guard let token = APITokenStore.shared.token, !token.isEmpty else {
            throw MusicGenError.missingToken
        }

        guard let url = URL(string: "https://api-inference.huggingface.co/models/\(model)") else {
            throw MusicGenError.badResponse("Invalid model URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // wait_for_model tells HF to queue the request instead of instantly 503'ing
        // while the model spins up on their shared infra.
        let body: [String: Any] = [
            "inputs": prompt,
            "options": ["wait_for_model": true]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 120

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw MusicGenError.badResponse("No HTTP response")
        }

        switch http.statusCode {
        case 200:
            // Success: raw audio bytes come back directly.
            return data
        case 503:
            // Model still loading — HF returns JSON with an estimated_time.
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let estimated = json["estimated_time"] as? Double {
                throw MusicGenError.modelLoading(Int(estimated))
            }
            throw MusicGenError.modelLoading(20)
        case 429:
            throw MusicGenError.httpError(429, "Rate limited by Hugging Face's free tier. Wait a bit and retry.")
        default:
            let msg = String(data: data, encoding: .utf8) ?? "unknown error"
            throw MusicGenError.httpError(http.statusCode, msg)
        }
    }
}

/// Simple local-only storage for the user's HF token. Never leaves the device except
/// as an Authorization header to Hugging Face's API.
final class APITokenStore {
    static let shared = APITokenStore()
    private let key = "hf_api_token"

    var token: String? {
        get { UserDefaults.standard.string(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}
