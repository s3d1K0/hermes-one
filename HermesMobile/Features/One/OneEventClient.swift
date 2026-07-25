import Foundation

/// Client WebSocket d'evenements/heartbeat du gateway Hermes (OpenClaw), porte
/// depuis VisionClaw (samples/CameraAccess/CameraAccess/OpenClaw/OpenClawEventClient.swift).
/// Recoit les heartbeats/cron pousses par le gateway et les remonte via
/// `onNotification` pour que One puisse "reveiller" Gemini et lire la reponse
/// (cf. OneVoiceSessionViewModel.deliverProactive).
final class OneEventClient {
    /// Remonte un push proactif : `spoken` = texte oral pret a lire (deja cadre par
    /// l'appelant), `details` = resultat complet optionnel (routine vers une
    /// notification locale iOS). `details` est nil tant que le serveur n'envoie pas
    /// encore le champ (retro-compat, cf. `handleHeartbeatEvent`).
    var onNotification: ((_ spoken: String, _ details: String?) -> Void)?

    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession?
    private var isConnected = false
    private var shouldReconnect = false
    private var reconnectDelay: TimeInterval = 2
    private let maxReconnectDelay: TimeInterval = 30

    func connect() {
        guard OneConfig.isGatewayConfigured else {
            NSLog("[OneEventWS] Not configured, skipping")
            return
        }

        shouldReconnect = true
        reconnectDelay = 2
        establishConnection()
    }

    func disconnect() {
        shouldReconnect = false
        isConnected = false
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        session?.invalidateAndCancel()
        session = nil
        NSLog("[OneEventWS] Disconnected")
    }

    // MARK: - Private

    private func establishConnection() {
        let host = OneConfig.gatewayHost
            .replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: "https://", with: "")
        let port = OneConfig.gatewayPort
        guard let url = URL(string: "ws://\(host):\(port)") else {
            NSLog("[OneEventWS] Invalid URL")
            return
        }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        session = URLSession(configuration: config)
        webSocketTask = session?.webSocketTask(with: url)
        webSocketTask?.resume()

        NSLog("[OneEventWS] Connecting to %@", url.absoluteString)
        startReceiving()
    }

    private func startReceiving() {
        webSocketTask?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handleMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.handleMessage(text)
                    }
                @unknown default:
                    break
                }
                self.startReceiving()
            case .failure(let error):
                NSLog("[OneEventWS] Receive error: %@", error.localizedDescription)
                self.isConnected = false
                self.scheduleReconnect()
            }
        }
    }

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        if type == "event" {
            handleEvent(json)
        } else if type == "res" {
            let ok = json["ok"] as? Bool ?? false
            if ok {
                NSLog("[OneEventWS] Connected and authenticated")
                isConnected = true
                reconnectDelay = 2
            } else {
                let error = json["error"] as? [String: Any]
                let msg = error?["message"] as? String ?? "unknown"
                NSLog("[OneEventWS] Connect failed: %@", msg)
            }
        }
    }

    private func handleEvent(_ json: [String: Any]) {
        guard let event = json["event"] as? String else { return }
        let payload = json["payload"] as? [String: Any] ?? [:]

        switch event {
        case "connect.challenge":
            sendConnectHandshake()

        case "heartbeat":
            handleHeartbeatEvent(payload)

        case "cron":
            handleCronEvent(payload)

        default:
            break
        }
    }

    private func sendConnectHandshake() {
        let connectMsg: [String: Any] = [
            "type": "req",
            "id": UUID().uuidString,
            "method": "connect",
            "params": [
                "minProtocol": 3,
                "maxProtocol": 3,
                "client": [
                    "id": "hermes-one-ios",
                    "displayName": "Hermes One",
                    "version": "1.0",
                    "platform": "ios",
                    "mode": "node"
                ],
                "role": "node",
                "scopes": [] as [String],
                "caps": ["voice"],
                "commands": [] as [String],
                "permissions": [:] as [String: Any],
                "auth": [
                    "token": OneConfig.gatewayToken
                ]
            ] as [String: Any]
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: connectMsg),
              let string = String(data: data, encoding: .utf8) else { return }
        webSocketTask?.send(.string(string)) { error in
            if let error {
                NSLog("[OneEventWS] Handshake send error: %@", error.localizedDescription)
            }
        }
    }

    private func handleHeartbeatEvent(_ payload: [String: Any]) {
        let status = payload["status"] as? String ?? ""
        // [Contrat de sortie, pattern Siri] `spoken` (2-3 phrases orales pretes a
        // dire) est prioritaire ; `preview` reste le repli retro-compatible tant que
        // le serveur ne l'envoie pas encore. On ne notifie que si le heartbeat a un
        // vrai contenu oral (pas les silencieux/vides).
        let spoken = nonEmptyString(payload["spoken"])
        let preview = nonEmptyString(payload["preview"])
        guard status == "sent", let toSpeak = spoken ?? preview else { return }

        let silent = payload["silent"] as? Bool ?? false
        guard !silent else { return }

        // `details` (resultat complet) : optionnel, route vers une notification locale
        // par le consommateur. nil tant que le serveur ne l'envoie pas (retro-compat).
        let details = nonEmptyString(payload["details"])

        NSLog("[OneEventWS] Heartbeat notification: %@", String(toSpeak.prefix(100)))
        onNotification?("[Notification from your assistant] \(toSpeak)", details)
    }

    private func handleCronEvent(_ payload: [String: Any]) {
        let action = payload["action"] as? String ?? ""
        guard action == "finished" else { return }

        // [Contrat de sortie] `spoken` prioritaire ; repli retro-compat sur
        // summary/result (le texte actuel) tant que le serveur ne l'envoie pas.
        let spoken = nonEmptyString(payload["spoken"])
        let summary = nonEmptyString(payload["summary"]) ?? nonEmptyString(payload["result"])
        guard let toSpeak = spoken ?? summary else { return }

        let details = nonEmptyString(payload["details"])

        NSLog("[OneEventWS] Cron notification: %@", String(toSpeak.prefix(100)))
        onNotification?("[Scheduled update] \(toSpeak)", details)
    }

    /// Decodage tolerant d'un champ texte optionnel du payload (spoken/details/
    /// preview/summary/result) : retourne la chaine non vide apres trim, sinon nil.
    /// Ne crashe jamais sur un champ absent ou d'un autre type.
    private func nonEmptyString(_ value: Any?) -> String? {
        guard let s = value as? String else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func scheduleReconnect() {
        guard shouldReconnect else { return }
        NSLog("[OneEventWS] Reconnecting in %.0fs", reconnectDelay)
        DispatchQueue.main.asyncAfter(deadline: .now() + reconnectDelay) { [weak self] in
            guard let self, self.shouldReconnect else { return }
            self.reconnectDelay = min(self.reconnectDelay * 2, self.maxReconnectDelay)
            self.establishConnection()
        }
    }
}
