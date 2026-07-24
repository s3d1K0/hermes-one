import Foundation

/// Route les appels d'outil emis par Gemini Live vers le gateway Hermes
/// (OneHermesBridge), porte depuis VisionClaw
/// (samples/CameraAccess/CameraAccess/OpenClaw/ToolCallRouter.swift).
@MainActor
final class OneToolCallRouter {
    private let bridge: OneHermesBridge
    private var inFlightTasks: [String: Task<Void, Never>] = [:]
    private var consecutiveFailures = 0
    private let maxConsecutiveFailures = 3

    init(bridge: OneHermesBridge) {
        self.bridge = bridge
    }

    /// Route un appel d'outil de Gemini vers le gateway Hermes. Appelle
    /// `sendResponse` avec le dictionnaire JSON a renvoyer comme message
    /// toolResponse.
    func handleToolCall(
        _ call: OneFunctionCall,
        sendResponse: @escaping ([String: Any]) -> Void
    ) {
        let callId = call.id
        let callName = call.name

        NSLog(
            "[OneToolCall] Received: %@ (id: %@) args: %@",
            callName, callId, String(describing: call.args))

        // Coupe-circuit : arrete d'envoyer des appels d'outil apres des echecs repetes.
        if consecutiveFailures >= maxConsecutiveFailures {
            NSLog(
                "[OneToolCall] Circuit breaker open (%d consecutive failures), rejecting %@",
                consecutiveFailures, callId)
            let errorResult: OneToolResult = .failure(
                "Tool execution is temporarily unavailable after \(consecutiveFailures) consecutive failures. "
                    + "Please tell the user you cannot complete this action right now and suggest they check their gateway connection."
            )
            let response = buildToolResponse(callId: callId, name: callName, result: errorResult)
            sendResponse(response)
            return
        }

        let task = Task { @MainActor in
            let taskDesc = call.args["task"] as? String ?? String(describing: call.args)
            let result = await bridge.delegateTask(task: taskDesc, toolName: callName)

            guard !Task.isCancelled else {
                NSLog("[OneToolCall] Task %@ was cancelled, skipping response", callId)
                return
            }

            switch result {
            case .success:
                self.consecutiveFailures = 0
            case .failure:
                self.consecutiveFailures += 1
            }

            NSLog(
                "[OneToolCall] Result for %@ (id: %@): %@",
                callName, callId, String(describing: result))

            let response = self.buildToolResponse(callId: callId, name: callName, result: result)
            sendResponse(response)

            self.inFlightTasks.removeValue(forKey: callId)
        }

        inFlightTasks[callId] = task
    }

    /// Annule des appels d'outil en cours specifiques (depuis toolCallCancellation).
    func cancelToolCalls(ids: [String]) {
        for id in ids {
            if let task = inFlightTasks[id] {
                NSLog("[OneToolCall] Cancelling in-flight call: %@", id)
                task.cancel()
                inFlightTasks.removeValue(forKey: id)
            }
        }
        bridge.lastToolCallStatus = .cancelled(ids.first ?? "unknown")
    }

    /// Annule tous les appels d'outil en cours (a l'arret de la session).
    func cancelAll() {
        for (id, task) in inFlightTasks {
            NSLog("[OneToolCall] Cancelling in-flight call: %@", id)
            task.cancel()
        }
        inFlightTasks.removeAll()
        consecutiveFailures = 0
    }

    // MARK: - Private

    private func buildToolResponse(
        callId: String,
        name: String,
        result: OneToolResult
    ) -> [String: Any] {
        return [
            "toolResponse": [
                "functionResponses": [
                    [
                        "id": callId,
                        "name": name,
                        "response": result.responseValue,
                    ]
                ]
            ]
        ]
    }
}
