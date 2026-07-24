//
// OneWakeWidgets.swift
//
// [One] Points d'entree « reveil externe » de One, hors du bouton du chat :
// - `OneLockControl` : controle Centre de controle (iOS 18+), un bouton qui
//   declenche `OneActivationIntent`.
// - `OneLockWidget`  : widget ecran-verrouille (.accessoryCircular) et tuile
//   ecran d'accueil (.systemSmall), bouton `Button(intent:)` (iOS 17+).
// Les deux declenchent `OneActivationIntent` -> reveil en 1 tap, sans micro
// allume au prealable. Ce fichier est membre de la seule target widget.
//
// Porte depuis VisionClaw (HermesWidget/HermesControl.swift + HermesLockWidget.swift).
//

import AppIntents
import SwiftUI
import WidgetKit

// MARK: - Centre de controle (iOS 18+)

@available(iOS 18.0, *)
struct OneLockControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.uzairansar.hermesmobile.onecontrol") {
            ControlWidgetButton(action: OneActivationIntent()) {
                Label("One", systemImage: "waveform.circle.fill")
            }
        }
        .displayName("Parler a One")
    }
}

// MARK: - Widget ecran-verrouille / ecran d'accueil

struct OneWakeEntry: TimelineEntry { let date: Date }

struct OneWakeProvider: TimelineProvider {
    func placeholder(in context: Context) -> OneWakeEntry { OneWakeEntry(date: Date()) }

    func getSnapshot(in context: Context, completion: @escaping (OneWakeEntry) -> Void) {
        completion(OneWakeEntry(date: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<OneWakeEntry>) -> Void) {
        completion(Timeline(entries: [OneWakeEntry(date: Date())], policy: .never))
    }
}

struct OneWakeEntryView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryCircular:
            Button(intent: OneActivationIntent()) {
                Image(systemName: "waveform.circle.fill")
                    .font(.title2)
            }
            .buttonStyle(.plain)
            .containerBackground(.clear, for: .widget)
        default:
            Button(intent: OneActivationIntent()) {
                VStack(spacing: 6) {
                    Image(systemName: "waveform.circle.fill")
                        .font(.system(size: 40))
                    Text("Parler a One")
                        .font(.caption)
                        .fontWeight(.medium)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .buttonStyle(.plain)
            .containerBackground(.fill.tertiary, for: .widget)
        }
    }
}

struct OneLockWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.uzairansar.hermesmobile.onelock", provider: OneWakeProvider()) { _ in
            OneWakeEntryView()
        }
        .configurationDisplayName("Parler a One")
        .description("Ouvre l'assistant vocal One.")
        .supportedFamilies([.accessoryCircular, .systemSmall])
    }
}
