import AppIntents

/// "Oye Siri, pregunta a JARVIS…": la respuesta la lee Siri en voz alta.
struct AskJarvisIntent: AppIntent {
    static let title: LocalizedStringResource = "Preguntar a JARVIS"
    static let description = IntentDescription("Hace una pregunta a JARVIS con tus datos de hoy.")
    static let openAppWhenRun = false

    @Parameter(title: "Pregunta", requestValueDialog: "¿Qué quieres saber?")
    var question: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let answer = try await Backend.shared.ask(question, voice: true)
        return .result(dialog: "\(answer)")
    }
}

/// "Oye Siri, briefing de JARVIS": estado del día sin abrir la app.
struct BriefingIntent: AppIntent {
    static let title: LocalizedStringResource = "Briefing de JARVIS"
    static let description = IntentDescription("Resume tu readiness, sueño, carga y lo importante de hoy.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        await HealthSync.shared.syncAndUpload(days: 2)
        let answer = try await Backend.shared.ask(
            "Dame el briefing de hoy en menos de 70 palabras: readiness y qué significa para entrenar, sueño, carga, y si hay algo de ULTRÓN, Donna o MIDAS que deba saber.",
            voice: true)
        return .result(dialog: "\(answer)")
    }
}

/// "Oye Siri, ¿cómo estoy?": respuesta inmediata sin IA, a partir de la última lectura.
struct ReadinessIntent: AppIntent {
    static let title: LocalizedStringResource = "Readiness de hoy"
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        await Backend.shared.refreshToday()
        guard let t = await Backend.shared.today, let r = t.readiness else {
            return .result(dialog: "Todavía no tengo datos de hoy.")
        }
        var text = "Readiness \(r). \(t.verdict)"
        if t.isStale { text += " Ojo: los datos de salud no están al día." }
        return .result(dialog: "\(text)")
    }
}

struct JarvisShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: BriefingIntent(), phrases: ["Briefing de \(.applicationName)", "Buenos días \(.applicationName)"],
                    shortTitle: "Briefing", systemImageName: "sun.max")
        AppShortcut(intent: ReadinessIntent(), phrases: ["¿Cómo estoy hoy en \(.applicationName)?", "Readiness de \(.applicationName)"],
                    shortTitle: "Readiness", systemImageName: "heart.text.square")
        AppShortcut(intent: AskJarvisIntent(), phrases: ["Pregunta a \(.applicationName)", "Hablar con \(.applicationName)"],
                    shortTitle: "Preguntar", systemImageName: "waveform")
    }
}
