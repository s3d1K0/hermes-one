import Foundation

/// Client WebSocket d'evenements/heartbeat du gateway Hermes (OpenClaw), porte
/// depuis VisionClaw (samples/CameraAccess/CameraAccess/OpenClaw/OpenClawEventClient.swift).
/// Recoit les heartbeats/cron pousses par le gateway et les remonte via
/// `onNotification` pour que One puisse "reveiller" Gemini et lire la reponse
/// (cf. OneVoiceSessionViewModel.deliverProactive).
final class OneEventClient {
    var onNotification: ((String) -> Void)?

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
        // Ne notifier que si le heartbeat a un vrai contenu (pas les silencieux).
        guard status == "sent", let preview = payload["preview"] as? String, !preview.isEmpty else {
            return
        }

        let silent = payload["silent"] as? Bool ?? false
        guard !silent else { return }

        NSLog("[OneEventWS] Heartbeat notification: %@", String(preview.prefix(100)))
        onNotification?("[Notification from your assistant] \(preview)")
    }

    private func handleCronEvent(_ payload: [String: Any]) {
        let action = payload["action"] as? String ?? ""
        guard action == "finished" else { return }

        let summary = payload["summary"] as? String
            ?? payload["result"] as? String
            ?? ""
        guard !summary.isEmpty else { return }

        NSLog("[OneEventWS] Cron notification: %@", String(summary.prefix(100)))
        onNotification?("[Scheduled update] \(summary)")
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
