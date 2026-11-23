import Foundation

/// Respuesta de la función jarvis-today. La comparten la app y los widgets.
struct Today: Codable, Equatable {
    struct Z: Codable, Equatable { var hrv, rhr, sleep, temp, resp: Double? }
    struct Vitals: Codable, Equatable { var hrv, rhr, steps, activeKcal, weightKg: Double? }
    struct Sleep: Codable, Equatable {
        var date: String
        var score, durationMin, deepMin, remMin, awakeMin: Double?
        var start, end: String?
    }
    struct Load: Codable, Equatable { var date: String; var load, ctl, atl, tsb: Double }
    struct Macros: Codable, Equatable { var kcal, proteinG, carbsG, fatG: Double?; var meals: Int? }
    struct Nutrition: Codable, Equatable { var photo: Macros; var health: Macros? }
    struct Story: Codable, Equatable, Identifiable { var id: String; var headline: String; var category: String?; var summary: String? }
    struct Midas: Codable, Equatable { var edition: String; var generatedAt: String; var front: [Story] }
    struct Order: Codable, Equatable, Identifiable {
        var id: String; var shop: String; var status: String
        var carrier: String?; var eta: String?; var note: String?
    }
    struct Donna: Codable, Equatable { var active: [Order] }
    struct Alert: Codable, Equatable, Identifiable { var id: Int; var agent: String; var level: String; var text: String }
    struct Check: Codable, Equatable { var level: String; var text: String }
    struct Freshness: Codable, Equatable { var lastHealthUpdate: String?; var lastHealthkitSync: String? }

    var generatedAt: String
    var date: String?
    var readiness: Int?
    var z: Z?
    var vitals: Vitals?
    var sleep: Sleep?
    var load: Load?
    var loadSeries: [Load]?
    var nutrition: Nutrition?
    var midas: Midas?
    var donna: Donna?
    var alerts: [Alert]
    var freshness: Freshness?
    var checks: [Check]

    static let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase; return d
    }()
    static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.keyEncodingStrategy = .convertToSnakeCase; return e
    }()
}

extension Today {
    /// Semáforo del día: readiness + estado de carga, igual que ARES en el Hub.
    enum Light: String { case green, amber, red, unknown }

    var light: Light {
        guard let r = readiness else { return .unknown }
        let tsb = load?.tsb ?? 0
        if r < 35 || tsb < -25 { return .red }
        if r < 50 || tsb < -15 { return .amber }
        return .green
    }

    var verdict: String {
        switch light {
        case .green: return "Verde: puedes apretar."
        case .amber: return "Ámbar: entrena, pero sin buscar récords."
        case .red: return "Rojo: prioriza recuperar."
        case .unknown: return "Sin datos suficientes para un veredicto."
        }
    }

    var isStale: Bool { checks.contains { $0.level != "info" } }
}

/// Caché compartida (App Group) para que los widgets lean sin red ni sesión.
enum SharedStore {
    static let group = "group.es.jarvis"
    private static let key = "today.v1"

    static func save(_ today: Today) {
        guard let data = try? Today.encoder.encode(today) else { return }
        UserDefaults(suiteName: group)?.set(data, forKey: key)
    }

    static func load() -> Today? {
        guard let data = UserDefaults(suiteName: group)?.data(forKey: key) else { return nil }
        return try? Today.decoder.decode(Today.self, from: data)
    }
}
