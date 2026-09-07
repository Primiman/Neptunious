import SwiftUI
import AVFoundation

struct ContentView: View {
    @State private var prompt: String = ""
    @State private var isGenerating = false
    @State private var errorMessage: String?
    @State private var lastAudioURL: URL?
    @State private var showSettings = false
    @State private var player: AVAudioPlayer?
    @State private var isPlaying = false

    private let service = MusicGenService()

    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                Text("Describe the track you want")
                    .font(.headline)

                TextEditor(text: $prompt)
                    .frame(height: 120)
                    .padding(8)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.gray.opacity(0.3))
                    )

                Text("e.g. \"lo-fi hip hop, mellow piano, rain sounds, 90 bpm\"")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button(action: generate) {
                    HStack {
                        if isGenerating {
                            ProgressView()
                                .padding(.trailing, 4)
                        }
                        Text(isGenerating ? "Generating…" : "Generate")
                            .bold()
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(prompt.trimmingCharacters(in: .whitespaces).isEmpty ? Color.gray : Color.accentColor)
                    .foregroundColor(.white)
                    .cornerRadius(12)
                }
                .disabled(isGenerating || prompt.trimmingCharacters(in: .whitespaces).isEmpty)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                }

                if lastAudioURL != nil {
                    VStack(spacing: 12) {
                        Button(action: togglePlayback) {
                            Label(isPlaying ? "Pause" : "Play", systemImage: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                .font(.title2)
                        }

                        Button(action: shareFile) {
                            Label("Save / Share", systemImage: "square.and.arrow.up")
                        }
                    }
                    .padding(.top, 8)
                }

                Spacer()

                Text("Powered by a free, open MusicGen model via Hugging Face — not affiliated with Suno. Quality and reliability are best-effort on the free tier.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
            .navigationTitle("SunoLite")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
        }
    }

    private func generate() {
        errorMessage = nil
        isGenerating = true
        isPlaying = false
        player?.stop()

        Task {
            do {
                let data = try await service.generate(prompt: prompt)
                let url = try save(data: data)
                await MainActor.run {
                    self.lastAudioURL = url
                    self.isGenerating = false
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isGenerating = false
                }
            }
        }
    }

    private func save(data: Data) throws -> URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let filename = "sunolite_\(Int(Date().timeIntervalSince1970)).wav"
        let url = dir.appendingPathComponent(filename)
        try data.write(to: url)
        return url
    }

    private func togglePlayback() {
        guard let url = lastAudioURL else { return }
        if isPlaying {
            player?.pause()
            isPlaying = false
        } else {
            if player == nil {
                player = try? AVAudioPlayer(contentsOf: url)
            }
            player?.play()
            isPlaying = true
        }
    }

    private func shareFile() {
        guard let url = lastAudioURL else { return }
        let activityVC = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let root = scene.windows.first?.rootViewController {
            root.present(activityVC, animated: true)
        }
    }
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var token: String = APITokenStore.shared.token ?? ""

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Hugging Face API Token"),
                        footer: Text("Get a free token at huggingface.co → Settings → Access Tokens. It's stored only on this device.")) {
                    SecureField("hf_xxxxxxxxxxxx", text: $token)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        APITokenStore.shared.token = token
                        dismiss()
                    }
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
