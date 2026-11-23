import Foundation
import UserNotifications

/// ARES · tracker de fuerza. Misma lógica de progresión que el ARES Tracker web:
/// se sube de nivel tras tocar el tope de reps en la primera serie durante
/// 2 semanas distintas; se baja un 10 % tras dos sesiones bajo el mínimo.
enum Ares {
    struct Mode { let label: String; let rest: Int; let roles: [Int: [(String, ClosedRange<Int>)]]; let pct: [Int: [Double]] }

    static let modes: [String: Mode] = [
        "F": .init(label: "Fuerza", rest: 150,
                   roles: [3: [("Top", 5...6), ("Load", 6...8), ("Backoff", 8...10)], 2: [("Top", 5...6), ("Backoff", 8...10)]],
                   pct: [3: [1, 0.925, 0.825], 2: [1, 0.825]]),
        "H": .init(label: "Hipertrofia", rest: 90,
                   roles: [3: [("Top", 8...10), ("Load", 10...12), ("Backoff", 12...15)], 2: [("Top", 8...10), ("Backoff", 12...15)]],
                   pct: [3: [1, 0.925, 0.825], 2: [1, 0.825]]),
    ]
    static let step = 5.0, rounding = 0.5, weeksRequired = 2

    struct Item: Codable, Hashable { var ex: String; var mode: String; var sets: Int }
    struct Day: Codable, Identifiable, Hashable { var id: String; var n: String; var t: String?; var note: String?; var opt: Bool?; var items: [Item] }
    struct Program: Codable { var ex: [String: [String: String]]; var days: [Day] }

    static let defaultProgram = Program(
        ex: ["press": ["n": "Press en polea"], "cruces": ["n": "Cruces en polea"], "curl": ["n": "Curl en polea"],
             "ext": ["n": "Extensión de tríceps en polea"], "remo": ["n": "Remo en T"], "jalon": ["n": "Jalón"],
             "quad": ["n": "Cuádriceps"], "isq": ["n": "Isquios"]],
        days: [
            .init(id: "A", n: "Día A", t: "Fuerza · Pecho", items: [.init(ex: "press", mode: "F", sets: 3), .init(ex: "cruces", mode: "H", sets: 3), .init(ex: "curl", mode: "H", sets: 2), .init(ex: "ext", mode: "H", sets: 2)]),
            .init(id: "B", n: "Día B", t: "Fuerza · Espalda", items: [.init(ex: "remo", mode: "F", sets: 3), .init(ex: "jalon", mode: "H", sets: 3), .init(ex: "curl", mode: "H", sets: 2), .init(ex: "ext", mode: "H", sets: 2)]),
            .init(id: "C", n: "Día C", t: "Hipertrofia · Mixto", items: [.init(ex: "press", mode: "H", sets: 3), .init(ex: "remo", mode: "H", sets: 3), .init(ex: "curl", mode: "H", sets: 2), .init(ex: "ext", mode: "H", sets: 2)]),
            .init(id: "D", n: "Día D", t: "Hipertrofia · Pierna", note: "Cuádriceps e isquios en biserie: 2 vueltas.",
                  items: [.init(ex: "cruces", mode: "H", sets: 3), .init(ex: "remo", mode: "H", sets: 3), .init(ex: "quad", mode: "H", sets: 2), .init(ex: "isq", mode: "H", sets: 2)]),
        ])

    /// Una serie: el tracker web guardaba los valores como texto, así que se aceptan ambos.
    struct SetEntry: Codable, Hashable {
        var w: Double?; var r: Int?
        init(w: Double?, r: Int?) { self.w = w; self.r = r }
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            w = (try? c.decode(Double.self, forKey: .w)) ?? Double((try? c.decode(String.self, forKey: .w))?.replacingOccurrences(of: ",", with: ".") ?? "")
            r = (try? c.decode(Int.self, forKey: .r)) ?? Int((try? c.decode(String.self, forKey: .r)) ?? "")
        }
    }
    struct Entry: Codable, Hashable { var sets: [SetEntry]; var uni: Bool?; var note: String? }
    struct Session: Codable, Identifiable { var id: String; var date: String; var day: String; var abs: Bool; var entries: [String: Entry]; var ts: Int64 }

    struct Verdict { enum State { case up, hold, down, new }; var state: State; var next: Double?; var head: String; var why: String; var last: (w: Double, r: Int)? }

    static func key(_ it: Item) -> String { "\(it.ex)-\(it.mode)" }
    static func roundW(_ x: Double) -> Double { (x / rounding).rounded() * rounding }
    static func fmt(_ x: Double) -> String { x.formatted(.number.precision(.fractionLength(0...1)).locale(Locale(identifier: "es_ES"))) }

    static func roles(_ mode: String, _ n: Int) -> [(String, ClosedRange<Int>)] {
        guard let m = modes[mode] else { return [] }
        return m.roles[n] ?? m.roles.values.first ?? []
    }

    static func isoWeek(_ date: String) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
        var cal = Calendar(identifier: .iso8601); cal.timeZone = .current
        guard let d = f.date(from: date) else { return date }
        let c = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: d)
        return "\(c.yearForWeekOfYear ?? 0)-W\(c.weekOfYear ?? 0)"
    }

    static func verdict(_ item: Item, sessions: [Session], forcedUp: Bool = false) -> Verdict {
        let k = key(item)
        let range = roles(item.mode, item.sets).first?.1 ?? 8...10
        let tops: [(date: String, w: Double, r: Int)] = sessions.sorted { $0.ts < $1.ts }.compactMap { s in
            guard let first = s.entries[k]?.sets.first, let w = first.w, let r = first.r, w > 0, r > 0 else { return nil }
            return (s.date, w, r)
        }
        guard let last = tops.last else {
            return .init(state: forcedUp ? .up : .new, next: nil, head: "Sin registro",
                         why: "Elige una carga con la que hagas \(range.lowerBound)–\(range.upperBound) reps en la primera serie.", last: nil)
        }
        var stepUp = step
        for i in stride(from: tops.count - 1, to: 0, by: -1) where tops[i].w - tops[i - 1].w > 0 { stepUp = tops[i].w - tops[i - 1].w; break }
        let prev = tops.count > 1 ? tops[tops.count - 2] : nil
        let (mn, mx) = (range.lowerBound, range.upperBound)
        if forcedUp { return .init(state: .up, next: last.w + stepUp, head: "Sube nivel · ≈ \(fmt(last.w + stepUp)) kg", why: "Subida marcada a mano.", last: (last.w, last.r)) }
        if last.r >= mx {
            let weeks = Set(tops.filter { $0.w == last.w && $0.r >= mx }.map { isoWeek($0.date) })
            if weeks.count >= weeksRequired {
                return .init(state: .up, next: last.w + stepUp, head: "Sube nivel · ≈ \(fmt(last.w + stepUp)) kg",
                             why: "Tope de \(mx) reps con \(fmt(last.w)) kg en \(weeks.count) semanas distintas.", last: (last.w, last.r))
            }
            return .init(state: .hold, next: last.w, head: "Mantén · \(fmt(last.w)) kg",
                         why: "Tope de \(mx) reps (\(weeks.count) de \(weeksRequired) semanas). Repítelo otra semana para subir.", last: (last.w, last.r))
        }
        if last.r >= mn { return .init(state: .hold, next: last.w, head: "Mantén · \(fmt(last.w)) kg", why: "\(last.r) reps, dentro del rango. Busca llegar a \(mx).", last: (last.w, last.r)) }
        if let prev, prev.r < mn {
            let n = roundW(last.w * 0.9)
            return .init(state: .down, next: n, head: "Baja · ≈ \(fmt(n)) kg", why: "Dos sesiones bajo \(mn) reps. Baja un 10 %.", last: (last.w, last.r))
        }
        return .init(state: .hold, next: last.w, head: "Mantén · \(fmt(last.w)) kg", why: "\(last.r) reps, bajo el mínimo. Si se repite, toca bajar.", last: (last.w, last.r))
    }

    static func planned(_ v: Verdict, _ item: Item) -> [Double] {
        guard let next = v.next, let pct = modes[item.mode]?.pct[item.sets] else { return [] }
        return pct.enumerated().map { $0.offset == 0 ? next : roundW(next * $0.element) }
    }

    static func nextDay(_ program: Program, sessions: [Session]) -> String? {
        let order = program.days.filter { $0.opt != true }.map(\.id)
        guard let lastDay = sessions.max(by: { $0.ts < $1.ts })?.day, let i = order.firstIndex(of: lastDay) else { return order.first }
        return order[(i + 1) % order.count]
    }

    /// Aviso de fin de descanso: suena aunque el iPhone esté en el bolsillo.
    static func scheduleRest(seconds: Int, exercise: String) {
        let c = UNMutableNotificationContent()
        c.title = "ARES · descanso terminado"
        c.body = "Siguiente serie de \(exercise)."
        c.sound = .default
        c.interruptionLevel = .timeSensitive
        let req = UNNotificationRequest(identifier: "ares-rest", content: c,
                                        trigger: UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(seconds), repeats: false))
        UNUserNotificationCenter.current().add(req)
    }
}
