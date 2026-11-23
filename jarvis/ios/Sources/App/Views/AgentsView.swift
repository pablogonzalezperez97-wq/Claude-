import SwiftUI
import PhotosUI
import Supabase

struct AgentsView: View {
    var body: some View {
        NavigationStack {
            List {
                NavigationLink { MidasView() } label: { AgentRow(name: "MIDAS", role: "Finanzas y noticias · 7:15", icon: "chart.line.uptrend.xyaxis") }
                NavigationLink { AuraView() } label: { AgentRow(name: "AURA", role: "Nutrición · comidas por foto", icon: "fork.knife") }
                NavigationLink { DonnaView() } label: { AgentRow(name: "Donna", role: "Pedidos y envíos · 3 al día", icon: "shippingbox") }
            }
            .navigationTitle("Agentes")
        }
    }
}

struct AgentRow: View {
    let name: String, role: String, icon: String
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.title2).foregroundStyle(Theme.gold).frame(width: 32)
            VStack(alignment: .leading) {
                Text(name).font(.headline)
                Text(role).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - MIDAS

struct Story: Decodable, Identifiable {
    struct Source: Decodable { var outlet: String; var title: String?; var url: String? }
    var id: String
    var topic: String
    var front: Bool?
    var category: String?
    var headline: String
    var summary: String
    var takeaway: String?
    var impact: String?
    var background: String?
    var sources: [Source]?
}

struct Edition: Decodable, Identifiable {
    var id: String; var date: String; var kind: String; var stories: [Story]
}

struct MidasView: View {
    @State private var editions: [Edition] = []
    private let topics = ["global_markets": "Finanzas globales", "etf": "ETF", "crypto": "Cripto", "real_estate": "Inmobiliario", "positions": "Mis posiciones"]

    var body: some View {
        List {
            ForEach(editions) { ed in
                Section(ed.kind == "morning" ? "Edición \(ed.date)" : "Actualización \(ed.date)") {
                    ForEach(ed.stories.sorted { ($0.front ?? false) && !($1.front ?? false) }) { s in
                        NavigationLink { StoryView(story: s) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text((topics[s.topic] ?? s.topic).uppercased()).font(.caption2).foregroundStyle(Theme.gold)
                                Text(s.headline).font(.subheadline.weight(s.front == true ? .bold : .regular))
                            }
                        }
                    }
                }
            }
            Text("Información, no asesoramiento financiero.").font(.caption2).foregroundStyle(.secondary)
        }
        .navigationTitle("MIDAS")
        .task {
            editions = (try? await Backend.shared.client.from("midas_editions")
                .select("id, date, kind, stories").order("generated_at", ascending: false).limit(4)
                .execute().value) ?? []
        }
    }
}

struct StoryView: View {
    let story: Story
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(story.headline).font(.title2.bold())
                Text(story.summary)
                if let t = story.takeaway { Text(t).padding().background(Theme.gold.opacity(0.15), in: .rect(cornerRadius: 12)) }
                if let i = story.impact { Text(i).foregroundStyle(.secondary) }
                if let b = story.background { Text(b).foregroundStyle(.secondary) }
                ForEach(story.sources ?? [], id: \.outlet) { src in
                    if let u = src.url, let url = URL(string: u), u.hasPrefix("https://") {
                        Link(src.outlet + (src.title.map { " · " + $0 } ?? ""), destination: url).font(.footnote)
                    } else {
                        Text(src.outlet).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .padding()
        }
    }
}

// MARK: - Donna

struct OrderRow: Decodable, Identifiable {
    var id: String; var shop: String; var status: String; var carrier: String?; var tracking: String?
    var lastEvent: String?; var eta: String?; var note: String?
    enum CodingKeys: String, CodingKey { case id, shop, status, carrier, tracking, eta, note, lastEvent = "last_event" }
}

struct DonnaView: View {
    @State private var orders: [OrderRow] = []
    var body: some View {
        List(orders) { o in
            VStack(alignment: .leading, spacing: 4) {
                HStack { Text(o.shop).font(.headline); Spacer(); Text(o.status.replacingOccurrences(of: "_", with: " ")).font(.caption) }
                if let c = o.carrier { Text([c, o.tracking].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }
                if let e = o.eta { Text("Entrega prevista: \(e)").font(.caption) }
                if let n = o.note { Text(n).font(.caption2).foregroundStyle(.secondary) }
            }
        }
        .overlay { if orders.isEmpty { ContentUnavailableView("Sin pedidos en seguimiento", systemImage: "shippingbox") } }
        .navigationTitle("Donna")
        .task {
            orders = (try? await Backend.shared.client.from("donna_orders").select()
                .order("last_event", ascending: false).execute().value) ?? []
        }
    }
}

// MARK: - AURA: foto de comida → inbox → la tarea programada calcula macros

struct MealRow: Decodable, Identifiable {
    var id: String; var date: String; var meal: String; var kcal: Double?; var label: String?
    var proteinG: Double?; var confidence: String?
    enum CodingKeys: String, CodingKey { case id, date, meal, kcal, label, confidence, proteinG = "protein_g" }
}

struct AuraView: View {
    @State private var meals: [MealRow] = []
    @State private var pick: PhotosPickerItem?
    @State private var meal = "comida"
    @State private var racion = "normal"
    @State private var grasa = "normal"
    @State private var resto = "todo"
    @State private var status: String?

    var body: some View {
        Form {
            Section("Nueva comida") {
                Picker("Comida", selection: $meal) { ForEach(["desayuno", "comida", "merienda", "cena", "otro"], id: \.self, content: Text.init) }
                Picker("Ración", selection: $racion) { ForEach(["pequeña", "normal", "grande"], id: \.self, content: Text.init) }
                Picker("Grasa añadida", selection: $grasa) { ForEach(["poca", "normal", "mucha"], id: \.self, content: Text.init) }
                Picker("Cuánto comiste", selection: $resto) {
                    Text("Todo").tag("todo"); Text("Casi todo").tag("casi_todo"); Text("La mitad").tag("mitad")
                }
                PhotosPicker("Elegir o hacer foto", selection: $pick, matching: .images)
                if let status { Text(status).font(.footnote).foregroundStyle(.secondary) }
            }
            Section("Últimas comidas") {
                ForEach(meals) { m in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(m.label ?? m.meal).font(.subheadline)
                            Text("\(m.date) · \(m.meal)").font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(m.kcal.map { "\(Int($0)) kcal" } ?? "—").monospacedDigit()
                    }
                }
            }
        }
        .navigationTitle("AURA")
        .onChange(of: pick) { _, item in if let item { Task { await upload(item) } } }
        .task { await loadMeals() }
    }

    private func loadMeals() async {
        meals = (try? await Backend.shared.client.from("aura_meals").select()
            .order("created_at", ascending: false).limit(20).execute().value) ?? []
    }

    private func upload(_ item: PhotosPickerItem) async {
        status = "Subiendo…"
        defer { pick = nil }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let img = UIImage(data: data), let jpeg = img.resized(maxSide: 1024).jpegData(compressionQuality: 0.6) else {
            status = "No se pudo leer la foto."; return
        }
        struct Row: Encodable { var date: String; var meal: String; var answers: [String: String]; var image: String }
        do {
            try await Backend.shared.client.from("aura_inbox").insert(Row(
                date: Date.now.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day()), meal: meal,
                answers: ["racion": racion, "grasa": grasa, "resto": resto],
                image: "data:image/jpeg;base64," + jpeg.base64EncodedString())).execute()
            status = "Enviada. AURA la analizará en su próxima pasada y borrará la foto."
        } catch {
            status = "Error al enviar: \(error.localizedDescription)"
        }
    }
}

extension UIImage {
    func resized(maxSide: CGFloat) -> UIImage {
        let scale = min(1, maxSide / max(size.width, size.height))
        guard scale < 1 else { return self }
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        return UIGraphicsImageRenderer(size: target).image { _ in draw(in: CGRect(origin: .zero, size: target)) }
    }
}
