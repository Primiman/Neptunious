import SwiftUI
import AVFoundation

struct ContentView: View {
    @State private var prompt = ""
    @State private var lyrics = ""
    @State private var isGenerating = false
    @State private var statusText = "Ready"
    @State private var audioPlayer: AVAudioPlayer?

    // Official ACE-Step 1.5 Hugging Face Space
    private let baseURL = "https://ace-step-ace-step-v1-5.hf.space"

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
                        isGenerating || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? Color.gray
                        : Color.blue
                    )
                    .foregroundColor(.white)
                    .cornerRadius(12)
                }
                .disabled(
                    isGenerating ||
                    prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
        statusText = "Sending to ACE-Step..."

        Task {
            do {
                let jobID = try await createGenerationJob()

                await MainActor.run {
                    statusText = "Generation queued..."
                }

                let audioURL = try await waitForJob(jobID)

                await MainActor.run {
                    statusText = "Downloading WAV..."
                }

                try await downloadAndPlayAudio(from: audioURL)

                await MainActor.run {
                    statusText = "Song generated!"
                    isGenerating = false
                }

            } catch {
                await MainActor.run {
                    statusText = "Error: \(error.localizedDescription)"
                    isGenerating = false
                }
            }
        }
    }

    // MARK: - Create Job

    private func createGenerationJob() async throws -> String {
        guard let url = URL(
            string: "\(baseURL)/v1/music/generate"
        ) else {
            throw MusicError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Content-Type"
        )

        let body: [String: Any] = [
            "caption": prompt,
            "lyrics": lyrics.isEmpty ? "[instrumental]" : lyrics,
            "thinking": true,
            "vocal_language": "sv",
            "audio_format": "wav",
            "audio_duration": 60,
            "model": "acestep-v15-turbo",
            "inference_steps": 8,
            "batch_size": 1
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
            let message =
                String(data: data, encoding: .utf8)
                ?? "Unknown server error"

            throw MusicError.serverError(
                "HTTP \(httpResponse.statusCode): \(message)"
            )
        }

        guard
            let json = try JSONSerialization.jsonObject(
                with: data
            ) as? [String: Any],
            let jobID = json["job_id"] as? String
        else {
            throw MusicError.invalidAPIResponse
        }

        return jobID
    }

    // MARK: - Poll Job

    private func waitForJob(_ jobID: String) async throws -> URL {
        guard let url = URL(
            string: "\(baseURL)/v1/jobs/\(jobID)"
        ) else {
            throw MusicError.invalidURL
        }

        while true {
            try await Task.sleep(
                nanoseconds: 2_000_000_000
            )

            let (data, response) = try await URLSession.shared.data(
                from: url
            )

            guard let httpResponse = response as? HTTPURLResponse else {
                throw MusicError.invalidResponse
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                throw MusicError.serverError(
                    "Job status HTTP \(httpResponse.statusCode)"
                )
            }

            guard
                let json = try JSONSerialization.jsonObject(
                    with: data
                ) as? [String: Any],
                let status = json["status"] as? String
            else {
                throw MusicError.invalidAPIResponse
            }

            if status == "queued" {
                if let position = json["queue_position"] as? Int {
                    await MainActor.run {
                        statusText =
                            "Queued — position \(position)..."
                    }
                } else {
                    await MainActor.run {
                        statusText = "Queued..."
                    }
                }

                continue
            }

            if status == "running" {
                await MainActor.run {
                    statusText = "ACE-Step is generating..."
                }

                continue
            }

            if status == "failed" {
                let errorMessage =
                    json["error"] as? String
                    ?? "Generation failed."

                throw MusicError.serverError(errorMessage)
            }

            if status == "succeeded" {
                guard
                    let result = json["result"] as? [String: Any],
                    let audioPath =
                        result["first_audio_path"] as? String
                else {
                    throw MusicError.invalidAPIResponse
                }

                guard
                    let audioURL = URL(
                        string: "\(baseURL)\(audioPath)"
                    )
                else {
                    throw MusicError.invalidAudioURL
                }

                return audioURL
            }
        }
    }

    // MARK: - Download + Play

    private func downloadAndPlayAudio(from url: URL) async throws {
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
            .appendingPathComponent("generated_song.wav")

        try data.write(to: fileURL)

        await MainActor.run {
            do {
                audioPlayer = try AVAudioPlayer(
                    contentsOf: fileURL
                )

                audioPlayer?.prepareToPlay()
                audioPlayer?.play()

            } catch {
                statusText =
                    "Audio playback error: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - Errors

enum MusicError: LocalizedError {
    case invalidURL
    case invalidResponse
    case invalidAPIResponse
    case invalidAudioURL
    case audioDownloadFailed
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid ACE-Step URL."

        case .invalidResponse:
            return "Invalid response from ACE-Step."

        case .invalidAPIResponse:
            return "ACE-Step returned an unexpected response."

        case .invalidAudioURL:
            return "ACE-Step returned an invalid audio URL."

        case .audioDownloadFailed:
            return "Could not download the generated audio."

        case .serverError(let message):
            return message
        }
    }
}
