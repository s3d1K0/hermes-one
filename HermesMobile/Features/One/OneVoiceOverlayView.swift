import SwiftUI

/// Overlay vocal "One" : mode vocal temps reel branche sur Gemini Live
/// (porte depuis VisionClaw). Capture le micro, joue les reponses audio et
/// affiche les transcriptions en direct.
struct OneVoiceOverlayView: View {
    /// Session vocale partagee, possede par `OneSessionController` (app-level) et
    /// non plus creee localement : c'est ce ViewModel qu'un push proactif reveille
    /// avant meme que l'overlay ne soit presente.
    let vm: OneVoiceSessionViewModel
    let onClose: () -> Void

    @State private var isPulsing = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 32) {
                Spacer()

                indicator

                Text(statusLabel)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)

                if let message = errorMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red.opacity(0.9))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                Spacer()

                transcripts

                Button {
                    close()
                } label: {
                    Text("Stop")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .padding(.horizontal, 40)
                .padding(.bottom, 24)
            }
            .padding(.top, 48)
        }
        .task {
            // Filet idempotent : le demarrage est pilote par OneSessionController
            // (present() / onProactivePush), pas par ce .task. On ne (re)demarre
            // ici que si la session est encore au repos (overlay presente sans
            // qu'un start ait ete declenche) ; sinon no-op, pour un chemin de
            // demarrage unique et deterministe (fin de la course de double-start
            // heritee de la vague 2).
            if vm.phase == .idle {
                await vm.start()
            }
        }
        .onDisappear {
            // Ne stoppe que si la session tourne encore. Quand la fin est
            // programmatique (timer d'inactivite / sleepAfterTurn -> stop()),
            // phase est deja .idle et onSessionEnded a baisse le flag qui
            // declenche ce dismiss : un 2e stop() ici couperait net l'annonce
            // TTS "One desactive" que le 1er stop() differe volontairement.
            if vm.phase != .idle {
                vm.stop()
            }
        }
        .onAppear {
            isPulsing = true
        }
    }

    private func close() {
        vm.stop()
        onClose()
    }

    // MARK: - Subviews

    private var indicator: some View {
        ZStack {
            Circle()
                .fill(indicatorColor.opacity(0.25))
                .frame(width: 160, height: 160)
                .scaleEffect(isPulsing && isActivePhase ? 1.15 : 1.0)
                .animation(
                    isActivePhase
                        ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                        : .default,
                    value: isPulsing
                )

            Circle()
                .fill(indicatorColor.opacity(0.45))
                .frame(width: 110, height: 110)

            Image(systemName: iconName)
                .font(.system(size: 44))
                .foregroundStyle(.white)
        }
    }

    private var transcripts: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !vm.aiTranscript.isEmpty {
                transcriptBubble(text: vm.aiTranscript, alignment: .leading, tint: .blue)
            }
            if !vm.userTranscript.isEmpty {
                transcriptBubble(text: vm.userTranscript, alignment: .trailing, tint: .gray)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .frame(minHeight: 100, alignment: .bottom)
    }

    private func transcriptBubble(text: String, alignment: HorizontalAlignment, tint: Color)
        -> some View
    {
        HStack {
            if alignment == .trailing { Spacer(minLength: 24) }
            Text(text)
                .font(.body)
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(tint.opacity(0.25), in: RoundedRectangle(cornerRadius: 16))
            if alignment == .leading { Spacer(minLength: 24) }
        }
    }

    // MARK: - Derived state

    private var isActivePhase: Bool {
        switch vm.phase {
        case .connecting, .listening, .speaking: return true
        case .idle, .error: return false
        }
    }

    private var indicatorColor: Color {
        switch vm.phase {
        case .idle, .connecting: return .gray
        case .listening: return .green
        case .speaking: return .blue
        case .error: return .red
        }
    }

    private var iconName: String {
        switch vm.phase {
        case .idle, .connecting: return "waveform.circle"
        case .listening: return "mic.fill"
        case .speaking: return "waveform.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    private var statusLabel: String {
        switch vm.phase {
        case .idle: return "One"
        case .connecting: return "Connexion..."
        case .listening: return "A l'ecoute"
        case .speaking: return "One parle"
        case .error: return "Erreur"
        }
    }

    private var errorMessage: String? {
        if case .error(let message) = vm.phase { return message }
        return nil
    }
}
