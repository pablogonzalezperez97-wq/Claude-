import SwiftUI

struct RootView: View {
    @EnvironmentObject private var backend: Backend

    var body: some View {
        TabView {
            TodayView().tabItem { Label("Hoy", systemImage: "sun.max") }
            AgentsView().tabItem { Label("Agentes", systemImage: "person.3") }
            AresView().tabItem { Label("Entreno", systemImage: "dumbbell") }
            AskView().tabItem { Label("JARVIS", systemImage: "waveform") }
        }
        .task { await backend.refreshToday() }
    }
}

// MARK: - Hoy: briefing, semáforo y auditoría de ULTRÓN

struct TodayView: View {
    @EnvironmentObject private var backend: Backend

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let t = backend.today {
                        UltronBanner(today: t)
                        ReadinessCard(today: t)
                        HStack(spacing: 12) {
                            Stat(title: "Sueño", value: t.sleep?.score.map { "\(Int($0))" } ?? "—",
                                 sub: t.sleep?.durationMin.map { hm($0) } ?? "")
                            Stat(title: "HRV", value: t.vitals?.hrv.map { "\(Int($0)) ms" } ?? "—",
                                 sub: t.z?.hrv.map { String(format: "z %+.1f", $0) } ?? "")
                            Stat(title: "FC reposo", value: t.vitals?.rhr.map { "\(Int($0))" } ?? "—",
                                 sub: t.z?.rhr.map { String(format: "z %+.1f", $0) } ?? "")
                        }
                        LoadCard(today: t)
                        if let m = t.midas, !m.front.isEmpty { MidasFront(midas: m) }
                        if let d = t.donna, !d.active.isEmpty { DonnaCard(orders: d.active) }
                    } else {
                        ContentUnavailableView("Cargando tu día", systemImage: "hourglass")
                    }
                    if let e = backend.lastError { Text(e).font(.footnote).foregroundStyle(.red) }
                }
                .padding()
            }
            .navigationTitle(greeting)
            .refreshable {
                await HealthSync.shared.syncAndUpload(days: 3)
                await backend.refreshToday()
            }
            .toolbar {
                Menu {
                    Button("Sincronizar 30 días de Salud") { Task { await HealthSync.shared.syncAndUpload(days: 30) } }
                    Button("Cerrar sesión", role: .destructive) { Task { await backend.signOut() } }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
    }

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: .now)
        return h < 14 ? "Buenos días" : h < 21 ? "Buenas tardes" : "Buenas noches"
    }
}

func hm(_ minutes: Double) -> String { "\(Int(minutes) / 60) h \(Int(minutes) % 60) min" }

struct UltronBanner: View {
    let today: Today
    var body: some View {
        let items = today.checks.map { ($0.level, $0.text) } + today.alerts.map { ($0.level, $0.text) }
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Label("ULTRÓN", systemImage: "exclamationmark.shield").font(.caption.bold()).foregroundStyle(.orange)
                ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                    Text(it.1).font(.subheadline).foregroundStyle(it.0 == "critical" ? .red : .primary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding().background(Color.orange.opacity(0.12), in: .rect(cornerRadius: 14))
        }
    }
}

struct ReadinessCard: View {
    let today: Today
    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle().stroke(Theme.line, lineWidth: 10)
                Circle().trim(from: 0, to: Double(today.readiness ?? 0) / 100)
                    .stroke(Theme.color(today.light), style: .init(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(today.readiness.map(String.init) ?? "—").font(.system(size: 34, weight: .bold, design: .rounded))
            }
            .frame(width: 96, height: 96)
            VStack(alignment: .leading, spacing: 4) {
                Text("ARES · readiness").font(.caption).foregroundStyle(.secondary)
                Text(today.verdict).font(.headline)
                if let d = today.date { Text("Datos de \(d)").font(.caption2).foregroundStyle(.secondary) }
            }
            Spacer()
        }
        .padding().background(Theme.panel, in: .rect(cornerRadius: 16))
    }
}

struct Stat: View {
    let title: String, value: String, sub: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.bold()).monospacedDigit()
            Text(sub).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12).background(Theme.panel, in: .rect(cornerRadius: 14))
    }
}

struct LoadCard: View {
    let today: Today
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Carga de entrenamiento").font(.caption).foregroundStyle(.secondary)
            HStack {
                Stat(title: "CTL 42 d", value: f(today.load?.ctl), sub: "forma")
                Stat(title: "ATL 7 d", value: f(today.load?.atl), sub: "fatiga")
                Stat(title: "TSB", value: f(today.load?.tsb), sub: (today.load?.tsb ?? 0) < -15 ? "fatiga alta" : "balance")
            }
        }
    }
    private func f(_ v: Double?) -> String { v.map { String(format: "%.0f", $0) } ?? "—" }
}

struct MidasFront: View {
    let midas: Today.Midas
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("MIDAS · portada").font(.caption).foregroundStyle(Theme.gold)
            ForEach(midas.front) { s in
                VStack(alignment: .leading, spacing: 2) {
                    if let c = s.category { Text(c.uppercased()).font(.caption2).foregroundStyle(Theme.gold) }
                    Text(s.headline).font(.headline)
                    if let sum = s.summary { Text(sum).font(.subheadline).foregroundStyle(.secondary).lineLimit(3) }
                }
            }
        }
        .padding().frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: .rect(cornerRadius: 16))
    }
}

struct DonnaCard: View {
    let orders: [Today.Order]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Donna · pedidos en curso").font(.caption).foregroundStyle(.secondary)
            ForEach(orders) { o in
                HStack {
                    Text(o.shop).font(.subheadline)
                    Spacer()
                    Text(o.status.replacingOccurrences(of: "_", with: " ")).font(.caption)
                    if let eta = o.eta { Text(eta).font(.caption2).foregroundStyle(.secondary) }
                }
            }
        }
        .padding().background(Theme.panel, in: .rect(cornerRadius: 16))
    }
}
