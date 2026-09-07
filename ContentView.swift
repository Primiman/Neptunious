import SwiftUI
import AVFoundation
struct ContentView: View {
    @State private var prompt = ""
    @State private var lyrics = ""
    @State private var isGenerating = false
    @State private var statusText = "Ready"
    @State private var audioPlayer: AVAudioPlayer?
    private let spaceURL =
        "https://kines9661-acestepv15ai.hf.space"
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
    private func generateSong() {
        isGenerating = true
        statusText = "Connecting to ACE-Step..."
        Task {
            do {
                let eventID = try await startGeneration()
                await MainActor.run {
                    statusText = "ACE-Step is generating..."
                }
                let audioURL =
                    try await waitForGeneration(eventID)
                await MainActor.run {
                    statusText = "Downloading audio..."
                }
                try await downloadAndPlay(from: audioURL)
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
    // MARK: Start Gradio job
    private func startGeneration() async throws -> String {
        guard let url = URL(
            string:
                "\(spaceURL)/gradio_api/call/generate_music"
        ) else {
            throw MusicError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Content-Type"
        )
        let duration = 60.0
        let bpm = NSNull()
        let language = "sv"
        let instrumental = false
        let guidanceScale = 7.0
        let seed = -1
        let body: [String: Any] = [
            "data": [
                prompt,
                lyrics.isEmpty ? "[Instrumental]" : lyrics,
                duration,
                bpm,
                language,
                instrumental,
                guidanceScale,
                seed
            ]
        ]
        request.httpBody =
            try JSONSerialization.data(
                withJSONObject: body
            )
        let (data, response) =
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
                String(data: data, encoding: .utf8)
                ?? "Unknown server error"
            throw MusicError.serverError(
                "HTTP \(httpResponse.statusCode): \(message)"
            )
        }
        guard
            let json =
                try JSONSerialization.jsonObject(
                    with: data
                ) as? [String: Any],
            let eventID =
                json["event_id"] as? String
        else {
            throw MusicError.invalidAPIResponse
        }
        return eventID
    }
    // MARK: Wait for Gradio result
    private func waitForGeneration(
        _ eventID: String
    ) async throws -> URL {
        guard let url = URL(
            string:
                "\(spaceURL)/gradio_api/call/generate_music/\(eventID)"
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
                "Generation status HTTP \(httpResponse.statusCode)"
            )
        }
        var buffer = ""
        for try await line in bytes.lines {
            buffer += line + "\n"
            if line.hasPrefix("event: complete") {
                continue
            }
            if line.hasPrefix("data: ") {
                let jsonText =
                    String(line.dropFirst(6))
                if let data =
                    jsonText.data(
                        using: .utf8
                    ) {
                    if let result =
                        try? JSONSerialization.jsonObject(
                            with: data
                        ) as? [[Any]] {
                        if
                            let first = result.first,
                            let audioObject =
                                first.first as? [String: Any]
                        {
                            if
                                let path =
                                    audioObject["path"] as? String
                            {
                                if path.hasPrefix("http") {
                                    return URL(
                                        string: path
                                    )!
                                }
                                return URL(
                                    string:
                                        "\(spaceURL)/file=\(path)"
                                )!
                            }
                            if
                                let urlString =
                                    audioObject["url"] as? String,
                                let audioURL =
                                    URL(
                                        string: urlString
                                    )
                            {
                                return audioURL
                            }
                        }
                    }
                    if
                        let error =
                            try? JSONSerialization.jsonObject(
                                with: data
                            ) as? [String: Any],
                        let message =
                            error["error"] as? String
                    {
                        throw MusicError.serverError(
                            message
                        )
                    }
                }
            }
        }
        throw MusicError.invalidAPIResponse
    }
    // MARK: Download and play
    private func downloadAndPlay(
        from url: URL
    ) async throws {
        let (data, response) =
            try await URLSession.shared.data(
                from: url
            )
        guard
            let httpResponse =
                response as? HTTPURLResponse,
            (200...299).contains(
                httpResponse.statusCode
            )
        else {
            throw MusicError.audioDownloadFailed
        }
        let fileURL =
            FileManager.default
                .temporaryDirectory
                .appendingPathComponent(
                    "generated_song.wav"
                )
        try data.write(to: fileURL)
        await MainActor.run {
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
}
enum MusicError: LocalizedError {
    case invalidURL
    case invalidResponse
    case invalidAPIResponse
    case audioDownloadFailed
    case serverError(String)
    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid ACE-Step URL."
        case .invalidResponse:
            return "Invalid response from ACE-Step."
        case .invalidAPIResponse:
            return "Unexpected response from ACE-Step."
        case .audioDownloadFailed:
            return "Could not download generated audio."
        case .serverError(let message):
            return message
        }
    }
}
