import SwiftUI
import AVFoundation
struct ContentView: View {
    @State private var prompt = ""
    @State private var lyrics = ""
    @State private var isGenerating = false
    @State private var statusText = "Ready"
    @State private var audioPlayer: AVAudioPlayer?
    // Victor / Hugging Face ACE-Step 1.5 ZeroGPU Space
    private let baseURL =
        "https://victor-ace-step-jam.hf.space"
    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text("AI Music Generator")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                TextField(
                    "What kind of song?",
                    text: $prompt,
                    axis: .vertical
                )
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...6)
                TextField(
                    "Lyrics",
                    text: $lyrics,
                    axis: .vertical
                )
                .textFieldStyle(.roundedBorder)
                .lineLimit(8...15)
                Button {
                    generateSong()
                } label: {
                    HStack {
                        if isGenerating {
                            ProgressView()
                                .tint(.white)
                        }
                        Text(
                            isGenerating
                            ? "Generating..."
                            : "Generate Song"
                        )
                        .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(
                        isGenerating || prompt.isEmpty
                        ? Color.gray
                        : Color.blue
                    )
                    .foregroundColor(.white)
                    .cornerRadius(12)
                }
                .disabled(
                    isGenerating || prompt.isEmpty
                )
                Text(statusText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Spacer()
            }
            .padding()
            .navigationTitle("Music")
        }
    }
    // MARK: - Generate
    private func generateSong() {
        isGenerating = true
        statusText = "Sending to ACE-Step..."
        Task {
            do {
                let eventID = try await startGeneration()
                await MainActor.run {
                    statusText = "ACE-Step is generating..."
                }
                let wavData =
                    try await waitForGeneration(eventID)
                await MainActor.run {
                    statusText = "Loading WAV..."
                }
                try playWAV(data: wavData)
                await MainActor.run {
                    statusText = "Song generated!"
                    isGenerating = false
                }
            } catch {
                await MainActor.run {
                    statusText =
                        "Error: \(error.localizedDescription)"
                    isGenerating = false
                }
            }
        }
    }
    // MARK: - Start Gradio job
    private func startGeneration() async throws -> String {
        guard let url = URL(
            string:
                "\(baseURL)/gradio_api/call/generate"
        ) else {
            throw MusicError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Content-Type"
        )
        let data: [Any] = [
            prompt,
            lyrics.isEmpty ? "[Instrumental]" : lyrics,
            60.0,   // audio_duration
            8,      // infer_step
            7.0,    // guidance_scale
            -1,     // random seed
            "",     // lora_name_or_path
            0.8     // lora_weight
        ]
        request.httpBody =
            try JSONSerialization.data(
                withJSONObject: ["data": data]
            )
        let (responseData, response) =
            try await URLSession.shared.data(
                for: request
            )
        guard
            let httpResponse =
                response as? HTTPURLResponse
        else {
            throw MusicError.invalidResponse
        }
        guard
            (200...299).contains(
                httpResponse.statusCode
            )
        else {
            let message =
                String(
                    data: responseData,
                    encoding: .utf8
                )
                ?? "Unknown server error"
            throw MusicError.serverError(
                "HTTP \(httpResponse.statusCode): \(message)"
            )
        }
        guard
            let json =
                try JSONSerialization.jsonObject(
                    with: responseData
                ) as? [String: Any],
            let eventID =
                json["event_id"] as? String
        else {
            throw MusicError.invalidAPIResponse
        }
        return eventID
    }
    // MARK: - Wait for result
    private func waitForGeneration(
        _ eventID: String
    ) async throws -> Data {
        guard let url = URL(
            string:
                "\(baseURL)/gradio_api/call/generate/\(eventID)"
        ) else {
            throw MusicError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let (bytes, response) =
            try await URLSession.shared.bytes(
                for: request
            )
        guard
            let httpResponse =
                response as? HTTPURLResponse
        else {
            throw MusicError.invalidResponse
        }
        guard
            (200...299).contains(
                httpResponse.statusCode
            )
        else {
            throw MusicError.serverError(
                "Generation request failed: HTTP \(httpResponse.statusCode)"
            )
        }
        for try await line in bytes.lines {
            guard line.hasPrefix("data: ")
            else {
                continue
            }
            let payload =
                String(line.dropFirst(6))
            guard
                let payloadData =
                    payload.data(using: .utf8)
            else {
                continue
            }
            // Error returned by Gradio
            if
                let errorObject =
                    try? JSONSerialization.jsonObject(
                        with: payloadData
                    ) as? [String: Any],
                let error =
                    errorObject["error"] as? String
            {
                throw MusicError.serverError(error)
            }
            // The generate API returns a JSON string:
            // "data:audio/wav;base64,..."
            if
                let result =
                    try? JSONSerialization.jsonObject(
                        with: payloadData
                    ) as? String,
                result.hasPrefix("data:audio/wav;base64,")
            {
                let prefix =
                    "data:audio/wav;base64,"
                let base64 =
                    String(
                        result.dropFirst(prefix.count)
                    )
                guard
                    let audioData =
                        Data(base64Encoded: base64)
                else {
                    throw MusicError.invalidAudioData
                }
                return audioData
            }
            // Some Gradio versions wrap the output
            // inside an array.
            if
                let result =
                    try? JSONSerialization.jsonObject(
                        with: payloadData
                    ) as? [Any],
                let first =
                    result.first as? String,
                first.hasPrefix("data:audio/wav;base64,")
            {
                let prefix =
                    "data:audio/wav;base64,"
                let base64 =
                    String(
                        first.dropFirst(prefix.count)
                    )
                guard
                    let audioData =
                        Data(base64Encoded: base64)
                else {
                    throw MusicError.invalidAudioData
                }
                return audioData
            }
        }
        throw MusicError.invalidAPIResponse
    }
    // MARK: - Play WAV
    private func playWAV(data: Data) throws {
        let fileURL =
            FileManager.default
                .temporaryDirectory
                .appendingPathComponent(
                    "generated_song.wav"
                )
        try data.write(to: fileURL)
        awaitMainActor {
            do {
                audioPlayer =
                    try AVAudioPlayer(
                        contentsOf: fileURL
                    )
                audioPlayer?.prepareToPlay()
                audioPlayer?.play()
            } catch {
                statusText =
                    "Playback error: \(error.localizedDescription)"
            }
        }
    }
    private func awaitMainActor(
        _ action: @escaping () -> Void
    ) {
        Task { @MainActor in
            action()
        }
    }
}
// MARK: - Errors
enum MusicError: LocalizedError {
    case invalidURL
    case invalidResponse
    case invalidAPIResponse
    case invalidAudioData
    case serverError(String)
    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid ACE-Step URL."
        case .invalidResponse:
            return "Invalid response from ACE-Step."
        case .invalidAPIResponse:
            return "Unexpected response from ACE-Step."
        case .invalidAudioData:
            return "The generated WAV data was invalid."
        case .serverError(let message):
            return message
        }
    }
}
