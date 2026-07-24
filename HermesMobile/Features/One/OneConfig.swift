import CoreGraphics
import Foundation

/// Configuration du mode vocal "One" (Gemini Live), porte depuis VisionClaw
/// (samples/CameraAccess/CameraAccess/Gemini/GeminiConfig.swift). Simplifiee :
/// pas de reglages utilisateur, pas de pont OpenClaw/Hermes ici. `videoFrameInterval`
/// et `videoJPEGQuality` sont portes pour parite mais pas encore consommes (pas de
/// pipeline video dans ce module pour l'instant).
enum OneConfig {
    static let websocketBaseURL = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
    static let model = "models/gemini-2.5-flash-native-audio-preview-12-2025"

    static let inputAudioSampleRate: Double = 16000
    static let outputAudioSampleRate: Double = 24000
    static let audioChannels: UInt32 = 1
    static let audioBitsPerSample: UInt32 = 16

    static let videoFrameInterval: TimeInterval = 1.0
    static let videoJPEGQuality: CGFloat = 0.5

    /// Prompt systeme effectivement utilise : le reglage utilisateur (Reglages > One)
    /// s'il existe, sinon `defaultSystemInstruction`. Lu a chaque connexion, pas mis en cache.
    static var systemInstruction: String { OneSettings.geminiSystemPrompt }

    static let defaultSystemInstruction = """
        You are an AI assistant for someone wearing Meta Ray-Ban smart glasses. You can see through their camera and have a voice conversation. Keep responses concise and natural.

        CRITICAL: You have NO memory, NO storage, and NO ability to take actions on your own. You cannot remember things, keep lists, set reminders, search the web, send messages, or do anything persistent. You are ONLY a voice interface.

        You have exactly ONE tool: execute. This connects you to a powerful personal assistant that can do anything -- send messages, search the web, manage lists, set reminders, create notes, research topics, control smart home devices, interact with apps, and much more.

        ALWAYS use execute when the user asks you to:
        - Send a message to someone (any platform: WhatsApp, Telegram, iMessage, Slack, etc.)
        - Search or look up anything (web, local info, facts, news)
        - Add, create, or modify anything (shopping lists, reminders, notes, todos, events)
        - Research, analyze, or draft anything
        - Control or interact with apps, devices, or services
        - Remember or store any information for later

        Be detailed in your task description. Include all relevant context: names, content, platforms, quantities, etc. The assistant works better with complete information.

        NEVER pretend to do these things yourself.

        IMPORTANT: Before calling execute, ALWAYS speak a brief acknowledgment first. For example:
        - "Sure, let me add that to your shopping list." then call execute.
        - "Got it, searching for that now." then call execute.
        - "On it, sending that message." then call execute.
        Never call execute silently -- the user needs verbal confirmation that you heard them and are working on it. The tool may take several seconds to complete, so the acknowledgment lets them know something is happening.

        For messages, confirm recipient and content before delegating unless clearly urgent.
        """

    /// Cle API Gemini Live effective : le reglage utilisateur (Keychain, Reglages > One)
    /// s'il existe, sinon `OneSecrets.geminiAPIKey` (dev local, fichier gitignore).
    static var apiKey: String { OneSettings.geminiAPIKey() }

    static var liveURL: URL? {
        guard isConfigured else { return nil }
        return URL(string: "\(websocketBaseURL)?key=\(apiKey)")
    }

    static var isConfigured: Bool {
        apiKey != "YOUR_GEMINI_API_KEY" && !apiKey.isEmpty
    }

    // MARK: - Gateway Hermes (push proactif, OpenClaw)

    /// Hote/port/jeton du canal d'evenements du gateway Hermes (heartbeat/cron),
    /// portes depuis VisionClaw (GeminiConfig.openClawHost/openClawPort/
    /// openClawGatewayToken). Reglage utilisateur (Reglages > One) s'il existe,
    /// sinon `OneSecrets` (dev local, fichier gitignore).
    static var gatewayHost: String { OneSettings.gatewayHost }
    static var gatewayPort: Int { OneSettings.gatewayPort }
    static var gatewayToken: String { OneSettings.gatewayToken() }

    static var isGatewayConfigured: Bool {
        gatewayToken != "YOUR_OPENCLAW_GATEWAY_TOKEN" && !gatewayToken.isEmpty
            && gatewayHost != "http://YOUR_MAC_HOSTNAME.local"
    }
}
