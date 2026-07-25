import Foundation
import UserNotifications

/// Outils RAPIDES de One geres LOCALEMENT (fast-path), sans passer par le gateway
/// Hermes : l'heure courante, un minuteur, un rappel simple. Portee : le trivial et
/// le temps-reel restent dans l'app (latence ~0, hors-ligne), tandis que tout ce qui
/// touche la memoire, les fichiers, les comptes, le web ou une tache multi-etapes est
/// delegue a Hermes via l'outil `execute` (OneHermesBridge). Le dispatch nom -> local
/// vs delegation vit dans OneToolCallRouter.
///
/// Les notifications locales (UNUserNotificationCenter) ne demandent AUCUNE cle
/// Info.plist (contrairement au micro/camera) ; l'autorisation est demandee a l'usage
/// et un refus renvoie un message d'echec exploitable a Gemini (jamais de crash).
@MainActor
enum OneLocalTools {

    /// Noms des outils geres localement (fast-path). Tout nom absent de cet ensemble
    /// est delegue a Hermes par OneToolCallRouter.
    static let toolNames: Set<String> = ["get_current_time", "set_timer", "set_reminder"]

    /// true si `name` est un outil rapide local (et non une delegation Hermes).
    static func isLocal(_ name: String) -> Bool { toolNames.contains(name) }

    /// Route un appel d'outil local vers son implementation. L'appelant garantit
    /// deja `isLocal(name) == true`.
    static func handle(name: String, args: [String: Any]) async -> OneToolResult {
        switch name {
        case "get_current_time":
            return getCurrentTime()
        case "set_timer":
            return await setTimer(args: args)
        case "set_reminder":
            return await setReminder(args: args)
        default:
            return .failure("Unknown local tool: \(name)")
        }
    }

    // MARK: - Push proactif : detail complet -> notification locale

    /// [Contrat de sortie, pattern Siri] Poste une notification locale iOS portant le
    /// detail COMPLET (`details`) d'un resultat pousse par Hermes, pendant que One en
    /// lit a voix haute la version orale (`spoken`). Objectif : rendre le detail
    /// consultable hors-voix (centre de notifications) sans encombrer l'oral.
    ///
    /// Tolerant et non bloquant : un `details` vide est ignore, un refus/absence
    /// d'autorisation n'a aucun effet visible (pas de crash, pas d'erreur remontee),
    /// et l'echec de programmation est avale (le canal vocal reste la source de verite).
    /// Reutilise `requestAuthorizationIfNeeded()` (jamais de second prompt apres refus).
    static func postProactiveDetails(_ details: String) async {
        let trimmed = details.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let granted = await requestAuthorizationIfNeeded()
        guard granted else { return }

        let content = UNMutableNotificationContent()
        content.title = "Hermes"
        // Tronque raisonnablement : iOS n'affiche qu'un extrait, et une payload de
        // notification a une taille limitee. Le detail integral vivra dans le canal
        // app/chat plus tard ; ici la notification sert de rappel consultable.
        content.body = String(trimmed.prefix(2000))
        content.sound = .default
        content.userInfo = ["source": "one.proactive", "kind": "details"]

        // trigger nil = declenchement immediat : la notif apparait tout de suite et
        // reste dans le centre de notifications pour consultation hors-voix.
        let request = UNNotificationRequest(
            identifier: "one-details-\(UUID().uuidString)", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    // MARK: - get_current_time

    private static func getCurrentTime() -> OneToolResult {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.dateFormat = "EEEE d MMMM yyyy 'a' HH'h'mm"
        let now = Date()
        let readable = formatter.string(from: now)
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.timeZone = .current
        let iso = isoFormatter.string(from: now)
        return .success("Il est \(readable). (ISO \(TimeZone.current.identifier): \(iso))")
    }

    // MARK: - set_timer

    private static func setTimer(args: [String: Any]) async -> OneToolResult {
        let seconds = doubleArg(args, keys: ["seconds", "duration_seconds", "in_seconds"])
        guard let seconds, seconds >= 1 else {
            return .failure(
                "Duree de minuteur invalide : precise un nombre de secondes >= 1 dans 'seconds'.")
        }
        let label = stringArg(args, keys: ["label", "title", "name"]) ?? "Minuteur"

        let granted = await requestAuthorizationIfNeeded()
        guard granted else {
            return .failure(
                "Impossible de regler le minuteur : les notifications sont refusees. "
                    + "Dis a l'utilisateur d'autoriser les notifications pour One dans Reglages.")
        }

        let content = UNMutableNotificationContent()
        content.title = "Minuteur One"
        content.body = label
        content.sound = .default
        content.userInfo = ["source": "one.local", "kind": "timer"]

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false)
        let request = UNNotificationRequest(
            identifier: "one-timer-\(UUID().uuidString)", content: content, trigger: trigger)

        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            return .failure("Echec de programmation du minuteur : \(error.localizedDescription)")
        }

        return .success("Minuteur \"\(label)\" regle : je te previens dans \(readableDuration(seconds)).")
    }

    // MARK: - set_reminder

    private static func setReminder(args: [String: Any]) async -> OneToolResult {
        let label = stringArg(args, keys: ["label", "title", "text", "name"]) ?? "Rappel"

        // Cible temporelle : soit une date/heure ISO 8601 (ou "yyyy-MM-dd HH:mm"),
        // soit un delai relatif en secondes. Tolerant : on essaie les deux.
        guard let fireDate = resolveFireDate(args: args) else {
            return .failure(
                "Heure de rappel invalide : donne 'datetime' au format ISO 8601 (heure locale) "
                    + "ou 'seconds_from_now'.")
        }

        guard fireDate.timeIntervalSinceNow >= 1 else {
            return .failure("L'heure du rappel est deja passee : choisis un moment futur.")
        }

        let granted = await requestAuthorizationIfNeeded()
        guard granted else {
            return .failure(
                "Impossible de creer le rappel : les notifications sont refusees. "
                    + "Dis a l'utilisateur d'autoriser les notifications pour One dans Reglages.")
        }

        let content = UNMutableNotificationContent()
        content.title = "Rappel One"
        content.body = label
        content.sound = .default
        content.userInfo = ["source": "one.local", "kind": "reminder"]

        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: fireDate)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(
            identifier: "one-reminder-\(UUID().uuidString)", content: content, trigger: trigger)

        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            return .failure("Echec de programmation du rappel : \(error.localizedDescription)")
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.dateFormat = "EEEE d MMMM 'a' HH'h'mm"
        return .success("Rappel \"\(label)\" programme pour \(formatter.string(from: fireDate)).")
    }

    // MARK: - Helpers

    /// Demande l'autorisation notifications si elle n'a pas encore ete accordee.
    /// Ne relance pas de prompt si l'utilisateur a deja refuse (renvoie false).
    private static func requestAuthorizationIfNeeded() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        @unknown default:
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        }
    }

    /// Resout la date de declenchement d'un rappel a partir d'arguments tolerants :
    /// datetime ISO 8601, "yyyy-MM-dd HH:mm", ou delai relatif en secondes.
    private static func resolveFireDate(args: [String: Any]) -> Date? {
        if let iso = stringArg(args, keys: ["datetime", "date", "time", "iso8601", "when"]) {
            if let d = parseDate(iso) { return d }
        }
        if let secs = doubleArg(args, keys: ["seconds_from_now", "in_seconds", "seconds", "delay_seconds"]) {
            return Date().addingTimeInterval(secs)
        }
        return nil
    }

    private static func parseDate(_ string: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)

        let isoFrac = ISO8601DateFormatter()
        isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = isoFrac.date(from: trimmed) { return d }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: trimmed) { return d }

        // Formats tolerants en heure locale (sans fuseau explicite).
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm"] {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.timeZone = TimeZone.current
            df.dateFormat = format
            if let d = df.date(from: trimmed) { return d }
        }
        return nil
    }

    private static func stringArg(_ args: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let s = args[key] as? String, !s.trimmingCharacters(in: .whitespaces).isEmpty {
                return s
            }
        }
        return nil
    }

    private static func doubleArg(_ args: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            if let d = args[key] as? Double { return d }
            if let i = args[key] as? Int { return Double(i) }
            if let s = args[key] as? String, let d = Double(s) { return d }
        }
        return nil
    }

    private static func readableDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total) seconde\(total > 1 ? "s" : "")" }
        let minutes = total / 60
        let rem = total % 60
        if rem == 0 { return "\(minutes) minute\(minutes > 1 ? "s" : "")" }
        return "\(minutes) min \(rem) s"
    }
}
