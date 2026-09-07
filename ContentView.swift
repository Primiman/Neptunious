import SwiftUI
import AVFoundation
struct ContentView: View {
    @State private var prompt: String = ""
    @State private var lyrics: String = ""
    @State private var isGenerating = false
    @State private var statusText = "Ready"
    @State private var audioPlayer: AVAudioPlayer?
    // Hugging Face Space running ACE-Step
    private let apiURL = URL(
        string: "https://acloudcenter-ace-music-generator.hf.space/run/generate"
    )!
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
                        Text(isGenerating ? "Generating..." : "Generate Song")
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
                .disabled(isGenerating || prompt.isEmpty)
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
    // MARK: - Generate Song
    private func generateSong() {
        isGenerating = true
        statusText = "Sending request to Hugging Face..."
        Task {
            do {
                let audioURL = try await requestSong()
                await MainActor.run {
                    statusText = "Song generated!"
                }
                try await downloadAndPlayAudio(from: audioURL)
                await MainActor.run {
                    statusText = "Playing generated song"
                }
            } catch {
                await MainActor.run {
                    statusText = "Error: \(error.localizedDescription)"
                    isGenerating = false
                }
            }
        }
    }
    // MARK: - API Request
    private func requestSong() async throws -> URL {
        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Content-Type"
        )
        // The Space is public, so a token is not required for the
        // basic API call. We can add your HF token later if needed
        // for authenticated ZeroGPU quota.
        let body: [String: Any] = [
            "data": [
                30,                 // duration in seconds
                prompt,             // music description / tags
                lyrics.isEmpty
                    ? "[instrumental]"
                    : lyrics,       // lyrics
                60,                 // inference steps
                15.0                // guidance scale
            ]
        ]
        request.httpBody = try JSONSerialization.data(
            withJSONObject: body
        )
        let (data, response) = try await URLSession.shared.data(
            for: request
        )
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MusicError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let serverMessage =
                String(data: data, encoding: .utf8)
                ?? "Unknown server error"
            throw MusicError.serverError(
                "HTTP \(httpResponse.statusCode): \(serverMessage)"
            )
        }
        let json = try JSONSerialization.jsonObject(
            with: data
        ) as? [String: Any]
        guard
            let resultData = json?["data"] as? [[String: Any]],
            let firstResult = resultData.first
        else {
            throw MusicError.invalidAPIResponse
        }
        // Gradio normally returns the generated audio as:
        // data[0].url
        if let urlString = firstResult["url"] as? String,
           let url = URL(string: urlString) {
            return url
        }
        // Some Gradio versions can return a filepath instead.
        if let path = firstResult["path"] as? String {
            if path.hasPrefix("http://") ||
                path.hasPrefix("https://") {
                guard let url = URL(string: path) else {
                    throw MusicError.invalidAudioURL
                }
                return url
            }
            throw MusicError.invalidAudioURL
        }
        throw MusicError.invalidAudioURL
    }
    // MARK: - Download & Play
    private func downloadAndPlayAudio(from url: URL) async throws {
        await MainActor.run {
            statusText = "Downloading generated audio..."
        }
        let (data, response) = try await URLSession.shared.data(
            from: url
        )
        guard
            let httpResponse = response as? HTTPURLResponse,
            (200...299).contains(httpResponse.statusCode)
        else {
            throw MusicError.audioDownloadFailed
        }
        let fileURL = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("generated_song.mp3")
        try data.write(to: fileURL)
        await MainActor.run {
            do {
                audioPlayer = try AVAudioPlayer(
                    contentsOf: fileURL
                )
                audioPlayer?.prepareToPlay()
                audioPlayer?.play()
                isGenerating = false
            } catch {
                isGenerating = false
            }
        }
    }
}
// MARK: - Errors
enum MusicError: LocalizedError {
    case invalidResponse
    case invalidAPIResponse
    case invalidAudioURL
    case audioDownloadFailed
    case serverError(String)
    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from Hugging Face."
        case .invalidAPIResponse:
            return "Hugging Face returned an unexpected response."
        case .invalidAudioURL:
            return "The generated audio URL was invalid."
        case .audioDownloadFailed:
            return "Could not download the generated song."
        case .serverError(let message):
            return message
        }
    }
}
