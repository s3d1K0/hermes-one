import Foundation

/// Configuration du mode vocal "One" (Gemini Live), porte depuis VisionClaw
/// (samples/CameraAccess/CameraAccess/Gemini/GeminiConfig.swift). Simplifiee :
/// pas de reglages utilisateur, pas de video, pas de pont OpenClaw/Hermes ici.
enum OneConfig {
    static let websocketBaseURL = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
    static let model = "models/gemini-2.5-flash-native-audio-preview-12-2025"

    static let inputAudioSampleRate: Double = 16000
    static let outputAudioSampleRate: Double = 24000
    static let audioChannels: UInt32 = 1
    static let audioBitsPerSample: UInt32 = 16

    static let systemInstruction = """
        You are a helpful voice assistant. Keep responses concise and natural, \
        as if speaking in a real conversation. You have no memory between \
        sessions and no ability to take actions outside of talking with the user.
        """

    static var apiKey: String { OneSecrets.geminiAPIKey }

    static var liveURL: URL? {
        guard isConfigured else { return nil }
        return URL(string: "\(websocketBaseURL)?key=\(apiKey)")
    }

    static var isConfigured: Bool {
        apiKey != "YOUR_GEMINI_API_KEY" && !apiKey.isEmpty
    }
}
