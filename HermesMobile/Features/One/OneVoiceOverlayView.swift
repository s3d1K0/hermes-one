import SwiftUI

/// Overlay vocal « One » (stub : ouvrir/fermer ; branchement Gemini Live a venir).
struct OneVoiceOverlayView: View {
  let onClose: () -> Void
  var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()
      VStack(spacing: 24) {
        Image(systemName: "waveform.circle.fill").font(.system(size: 64)).foregroundStyle(.white)
        Text("One").font(.largeTitle.bold()).foregroundStyle(.white)
        Text("Mode vocal — branchement Gemini Live a venir").foregroundStyle(.white.opacity(0.7))
        Button("Fermer") { onClose() }.buttonStyle(.borderedProminent).padding(.top, 12)
      }
    }
  }
}
