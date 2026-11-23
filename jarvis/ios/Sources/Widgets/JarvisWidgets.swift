import WidgetKit
import SwiftUI

/// Los widgets leen la última lectura que la app dejó en el App Group:
/// no necesitan red ni sesión, y se recargan cada vez que la app sincroniza.
struct Entry: TimelineEntry { let date: Date; let today: Today? }

struct Provider: TimelineProvider {
    func placeholder(in _: Context) -> Entry { Entry(date: .now, today: nil) }
    func getSnapshot(in _: Context, completion: @escaping (Entry) -> Void) { completion(Entry(date: .now, today: SharedStore.load())) }
    func getTimeline(in _: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        completion(Timeline(entries: [Entry(date: .now, today: SharedStore.load())], policy: .after(.now.addingTimeInterval(3600))))
    }
}

private let gold = Color(red: 0.79, green: 0.64, blue: 0.42)

private func lightColor(_ t: Today?) -> Color {
    switch t?.light ?? .unknown {
    case .green: .green
    case .amber: .orange
    case .red: .red
    case .unknown: .gray
    }
}

struct ReadinessWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: Entry

    var body: some View {
        let t = entry.today
        switch family {
        case .accessoryCircular:
            Gauge(value: Double(t?.readiness ?? 0), in: 0...100) { Text("R") } currentValueLabel: { Text(t?.readiness.map(String.init) ?? "—") }
                .gaugeStyle(.accessoryCircular)
        case .accessoryRectangular:
            VStack(alignment: .leading) {
                Text("JARVIS").font(.caption2.bold())
                Text("Readiness \(t?.readiness.map(String.init) ?? "—")").font(.headline)
                Text("TSB \(t?.load.map { String(format: "%.0f", $0.tsb) } ?? "—")").font(.caption)
            }
        case .systemMedium:
            HStack(spacing: 16) {
                ring(t)
                VStack(alignment: .leading, spacing: 4) {
                    Text(t?.verdict ?? "Abre JARVIS para sincronizar").font(.subheadline.bold())
                    Text("Sueño \(t?.sleep?.score.map { "\(Int($0))" } ?? "—") · TSB \(t?.load.map { String(format: "%.0f", $0.tsb) } ?? "—")").font(.caption)
                    if let h = t?.midas?.front.first?.headline { Text(h).font(.caption2).foregroundStyle(.secondary).lineLimit(2) }
                    if t?.isStale == true { Text("Datos de salud sin actualizar").font(.caption2).foregroundStyle(.orange) }
                }
            }
        default:
            VStack(alignment: .leading) {
                Text("JARVIS").font(.caption2.bold()).foregroundStyle(gold)
                Spacer()
                ring(t)
                Spacer()
                if t?.isStale == true { Text("Sin datos nuevos").font(.caption2).foregroundStyle(.orange) }
            }
        }
    }

    private func ring(_ t: Today?) -> some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.15), lineWidth: 8)
            Circle().trim(from: 0, to: Double(t?.readiness ?? 0) / 100)
                .stroke(lightColor(t), style: .init(lineWidth: 8, lineCap: .round)).rotationEffect(.degrees(-90))
            Text(t?.readiness.map(String.init) ?? "—").font(.title.bold())
        }
        .frame(width: 72, height: 72)
    }
}

struct ReadinessWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "JarvisReadiness", provider: Provider()) { entry in
            ReadinessWidgetView(entry: entry).containerBackground(Color.black, for: .widget)
        }
        .configurationDisplayName("JARVIS · readiness")
        .description("Semáforo del día, sueño, carga y titular de MIDAS.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])
    }
}

@main
struct JarvisWidgetBundle: WidgetBundle {
    var body: some Widget { ReadinessWidget() }
}
