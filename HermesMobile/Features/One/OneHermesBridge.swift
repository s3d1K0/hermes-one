import Foundation
import Observation

/// Etat de connexion HTTP au gateway Hermes (OpenClaw).
enum OneHermesConnectionState: Equatable {
    case notConfigured
    case checking
    case connected
    case unreachable(String)
}

/// Pont HTTP vers le gateway Hermes (OpenClaw), porte depuis VisionClaw
/// (samples/CameraAccess/CameraAccess/OpenClaw/OpenClawBridge.swift). Delegue
/// les taches recues via l'outil `execute` de Gemini Live au gateway Hermes
/// (endpoint compatible OpenAI `/v1/chat/completions`), avec continuite de
/// conversation via l'en-tete `x-openclaw-session-key`.
@Observable
@MainActor
final class OneHermesBridge {
    var lastToolCallStatus: OneToolCallStatus = .idle
    var connectionState: OneHermesConnectionState = .notConfigured

    private let session: URLSession
    private let pingSession: URLSession
    private var sessionKey: String
    private var conversationHistory: [[String: String]] = []
    private let maxHistoryTurns = 10

    private static let stableSessionKey = "agent:main:glass"

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        self.session = URLSession(configuration: config)

        let pingConfig = URLSessionConfiguration.default
        pingConfig.timeoutIntervalForRequest = 5
        self.pingSession = URLSession(configuration: pingConfig)

        self.sessionKey = OneHermesBridge.stableSessionKey
    }

    func checkConnection() async {
        guard OneConfig.isGatewayConfigured else {
            connectionState = .notConfigured
            return
        }
        connectionState = .checking
        guard let url = URL(string: "\(OneConfig.gatewayHost):\(OneConfig.gatewayPort)/v1/chat/completions") else {
            connectionState = .unreachable("Invalid URL")
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(OneConfig.gatewayToken)", forHTTPHeaderField: "Authorization")
        request.setValue("glass", forHTTPHeaderField: "x-openclaw-message-channel")
        do {
            let (_, response) = try await pingSession.data(for: request)
            if let http = response as? HTTPURLResponse, (200...499).contains(http.statusCode) {
                connectionState = .connected
                NSLog("[OneHermesBridge] Gateway reachable (HTTP %d)", http.statusCode)
            } else {
                connectionState = .unreachable("Unexpected response")
            }
        } catch {
            connectionState = .unreachable(error.localizedDescription)
            NSLog("[OneHermesBridge] Gateway unreachable: %@", error.localizedDescription)
        }
    }

    func resetSession() {
        conversationHistory = []
        NSLog("[OneHermesBridge] Session reset (key retained: %@)", sessionKey)
    }

    // MARK: - Agent Chat (session continuity via x-openclaw-session-key header)

    func delegateTask(
        task: String,
        toolName: String = "execute"
    ) async -> OneToolResult {
        lastToolCallStatus = .executing(toolName)

        guard let url = URL(string: "\(OneConfig.gatewayHost):\(OneConfig.gatewayPort)/v1/chat/completions") else {
            lastToolCallStatus = .failed(toolName, "Invalid URL")
            return .failure("Invalid gateway URL")
        }

        // Ajoute le nouveau message utilisateur a l'historique de conversation.
        conversationHistory.append(["role": "user", "content": task])

        // Coupe l'historique pour ne garder que les tours les plus recents (paires user+assistant).
        if conversationHistory.count > maxHistoryTurns * 2 {
            conversationHistory = Array(conversationHistory.suffix(maxHistoryTurns * 2))
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(OneConfig.gatewayToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(sessionKey, forHTTPHeaderField: "x-openclaw-session-key")
        request.setValue("glass", forHTTPHeaderField: "x-openclaw-message-channel")

        let body: [String: Any] = [
            "model": "openclaw",
            "messages": conversationHistory,
            "stream": false,
        ]

        NSLog("[OneHermesBridge] Sending %d messages in conversation", conversationHistory.count)

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await session.data(for: request)
            let httpResponse = response as? HTTPURLResponse

            guard let statusCode = httpResponse?.statusCode, (200...299).contains(statusCode) else {
                let code = httpResponse?.statusCode ?? 0
                let bodyStr = String(data: data, encoding: .utf8) ?? "no body"
                NSLog("[OneHermesBridge] Chat failed: HTTP %d - %@", code, String(bodyStr.prefix(200)))
                lastToolCallStatus = .failed(toolName, "HTTP \(code)")
                return .failure("Agent returned HTTP \(code)")
            }

            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let choices = json["choices"] as? [[String: Any]],
                let first = choices.first,
                let message = first["message"] as? [String: Any],
                let content = message["content"] as? String
            {
                // Ajoute la reponse de l'assistant a l'historique pour la continuite.
                conversationHistory.append(["role": "assistant", "content": content])
                NSLog("[OneHermesBridge] Agent result: %@", String(content.prefix(200)))
                lastToolCallStatus = .completed(toolName)
                return .success(content)
            }

            let raw = String(data: data, encoding: .utf8) ?? "OK"
            conversationHistory.append(["role": "assistant", "content": raw])
            NSLog("[OneHermesBridge] Agent raw: %@", String(raw.prefix(200)))
            lastToolCallStatus = .completed(toolName)
            return .success(raw)
        } catch {
            NSLog("[OneHermesBridge] Agent error: %@", error.localizedDescription)
            lastToolCallStatus = .failed(toolName, error.localizedDescription)
            return .failure("Agent error: \(error.localizedDescription)")
        }
    }
}
