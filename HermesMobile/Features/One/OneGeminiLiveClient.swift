import Foundation

/// Etat de connexion au websocket Gemini Live.
enum OneConnectionState: Equatable {
    case disconnected
    case connecting
    case settingUp
    case ready
    case error(String)
}

/// Client Gemini Live natif (URLSessionWebSocketTask), porte depuis VisionClaw
/// (samples/CameraAccess/CameraAccess/Gemini/GeminiLiveService.swift).
/// Simplifie : pas de video, pas d'appel d'outils (Gemini seul pour l'instant).
@MainActor
final class OneGeminiLiveClient {
    private(set) var connectionState: OneConnectionState = .disconnected
    private(set) var isModelSpeaking: Bool = false

    var onAudioReceived: ((Data) -> Void)?
    var onTurnComplete: (() -> Void)?
    var onInterrupted: (() -> Void)?
    var onDisconnected: ((String?) -> Void)?
    var onInputTranscription: ((String) -> Void)?
    var onOutputTranscription: ((String) -> Void)?
    /// Reserve pour une future delegation d'outils ; ne fait rien pour l'instant.
    var onToolCall: (([String: Any]) -> Void)?

    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var connectContinuation: CheckedContinuation<Bool, Never>?
    private let delegate = OneWebSocketDelegate()
    private var urlSession: URLSession!
    private let sendQueue = DispatchQueue(label: "one.gemini.send", qos: .userInitiated)

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        self.urlSession = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    func connect() async -> Bool {
        guard let url = OneConfig.liveURL else {
            connectionState = .error("No API key configured")
            return false
        }

        connectionState = .connecting

        let result = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            self.connectContinuation = continuation

            self.delegate.onOpen = { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    self.connectionState = .settingUp
                    self.sendSetupMessage()
                    self.startReceiving()
                }
            }

            self.delegate.onClose = { [weak self] code, reason in
                guard let self else { return }
                let reasonStr = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "no reason"
                Task { @MainActor in
                    self.resolveConnect(success: false)
                    self.connectionState = .disconnected
                    self.isModelSpeaking = false
                    self.onDisconnected?("Connection closed (code \(code.rawValue): \(reasonStr))")
                }
            }

            self.delegate.onError = { [weak self] error in
                guard let self else { return }
                let msg = error?.localizedDescription ?? "Unknown error"
                Task { @MainActor in
                    self.resolveConnect(success: false)
                    self.connectionState = .error(msg)
                    self.isModelSpeaking = false
                    self.onDisconnected?(msg)
                }
            }

            self.webSocketTask = self.urlSession.webSocketTask(with: url)
            self.webSocketTask?.resume()

            // Timeout apres 15 secondes.
            Task {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                await MainActor.run {
                    self.resolveConnect(success: false)
                    if self.connectionState == .connecting || self.connectionState == .settingUp {
                        self.connectionState = .error("Connection timed out")
                    }
                }
            }
        }

        return result
    }

    func disconnect() {
        receiveTask?.cancel()
        receiveTask = nil
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        delegate.onOpen = nil
        delegate.onClose = nil
        delegate.onError = nil
        onToolCall = nil
        connectionState = .disconnected
        isModelSpeaking = false
        resolveConnect(success: false)
    }

    func sendAudio(_ data: Data) {
        guard connectionState == .ready else { return }
        sendQueue.async { [weak self] in
            let base64 = data.base64EncodedString()
            let json: [String: Any] = [
                "realtimeInput": [
                    "audio": [
                        "mimeType": "audio/pcm;rate=16000",
                        "data": base64,
                    ]
                ]
            ]
            self?.sendJSON(json)
        }
    }

    func sendText(_ text: String) {
        guard connectionState == .ready else { return }
        sendQueue.async { [weak self] in
            // turnComplete: true est indispensable — sans lui, Gemini Live ajoute
            // le texte au contexte mais ne genere aucune reponse (donc rien n'est
            // vocalise). Fix conserve depuis VisionClaw.
            let msg: [String: Any] = [
                "clientContent": [
                    "turns": [
                        ["role": "user", "parts": [["text": text]]]
                    ],
                    "turnComplete": true,
                ]
            ]
            self?.sendJSON(msg)
        }
    }

    // MARK: - Private

    private func resolveConnect(success: Bool) {
        if let cont = connectContinuation {
            connectContinuation = nil
            cont.resume(returning: success)
        }
    }

    private func sendSetupMessage() {
        let setup: [String: Any] = [
            "setup": [
                "model": OneConfig.model,
                "generationConfig": [
                    "responseModalities": ["AUDIO"],
                    "thinkingConfig": [
                        "thinkingBudget": 0
                    ],
                ],
                "systemInstruction": [
                    "parts": [
                        ["text": OneConfig.systemInstruction]
                    ]
                ],
                "realtimeInputConfig": [
                    "automaticActivityDetection": [
                        "disabled": false,
                        "startOfSpeechSensitivity": "START_SENSITIVITY_HIGH",
                        "endOfSpeechSensitivity": "END_SENSITIVITY_LOW",
                        "silenceDurationMs": 500,
                        "prefixPaddingMs": 40,
                    ],
                    "activityHandling": "START_OF_ACTIVITY_INTERRUPTS",
                    "turnCoverage": "TURN_INCLUDES_ALL_INPUT",
                ],
                "contextWindowCompression": [
                    "slidingWindow": [
                        "targetTokens": 80000
                    ]
                ],
                "inputAudioTranscription": [:] as [String: Any],
                "outputAudioTranscription": [:] as [String: Any],
            ]
        ]
        sendJSON(setup)
    }

    private func sendJSON(_ json: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: json),
            let string = String(data: data, encoding: .utf8)
        else {
            return
        }
        webSocketTask?.send(.string(string)) { _ in }
    }

    private func startReceiving() {
        receiveTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                guard let task = self.webSocketTask else { break }
                do {
                    let message = try await task.receive()
                    switch message {
                    case .string(let text):
                        await self.handleMessage(text)
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) {
                            await self.handleMessage(text)
                        }
                    @unknown default:
                        break
                    }
                } catch {
                    if !Task.isCancelled {
                        let reason = error.localizedDescription
                        await MainActor.run {
                            self.resolveConnect(success: false)
                            self.connectionState = .disconnected
                            self.isModelSpeaking = false
                            self.onDisconnected?(reason)
                        }
                    }
                    break
                }
            }
        }
    }

    private func handleMessage(_ text: String) async {
        guard let data = text.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return
        }

        // Setup complete.
        if json["setupComplete"] != nil {
            connectionState = .ready
            resolveConnect(success: true)
            return
        }

        // GoAway - le serveur va bientot fermer.
        if let goAway = json["goAway"] as? [String: Any] {
            let timeLeft = goAway["timeLeft"] as? [String: Any]
            let seconds = timeLeft?["seconds"] as? Int ?? 0
            connectionState = .disconnected
            isModelSpeaking = false
            onDisconnected?("Server closing (time left: \(seconds)s)")
            return
        }

        // Appel d'outil (non gere pour l'instant : Gemini seul).
        if json["toolCall"] != nil {
            onToolCall?(json)
            return
        }

        // Contenu serveur.
        if let serverContent = json["serverContent"] as? [String: Any] {
            if let interrupted = serverContent["interrupted"] as? Bool, interrupted {
                isModelSpeaking = false
                onInterrupted?()
                return
            }

            if let modelTurn = serverContent["modelTurn"] as? [String: Any],
                let parts = modelTurn["parts"] as? [[String: Any]]
            {
                for part in parts {
                    if let inlineData = part["inlineData"] as? [String: Any],
                        let mimeType = inlineData["mimeType"] as? String,
                        mimeType.hasPrefix("audio/pcm"),
                        let base64Data = inlineData["data"] as? String,
                        let audioData = Data(base64Encoded: base64Data)
                    {
                        isModelSpeaking = true
                        onAudioReceived?(audioData)
                    }
                }
            }

            if let turnComplete = serverContent["turnComplete"] as? Bool, turnComplete {
                isModelSpeaking = false
                onTurnComplete?()
            }

            if let inputTranscription = serverContent["inputTranscription"] as? [String: Any],
                let text = inputTranscription["text"] as? String, !text.isEmpty
            {
                onInputTranscription?(text)
            }
            if let outputTranscription = serverContent["outputTranscription"] as? [String: Any],
                let text = outputTranscription["text"] as? String, !text.isEmpty
            {
                onOutputTranscription?(text)
            }
        }
    }
}

// MARK: - WebSocket Delegate

private class OneWebSocketDelegate: NSObject, URLSessionWebSocketDelegate {
    var onOpen: ((String?) -> Void)?
    var onClose: ((URLSessionWebSocketTask.CloseCode, Data?) -> Void)?
    var onError: ((Error?) -> Void)?

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        onOpen?(`protocol`)
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        onClose?(closeCode, reason)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            onError?(error)
        }
    }
}
