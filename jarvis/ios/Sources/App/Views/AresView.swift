import SwiftUI
import Supabase

struct AresView: View {
    @State private var program = Ares.defaultProgram
    @State private var sessions: [Ares.Session] = []
    @State private var dayID: String?
    @State private var draft: [String: [Ares.SetEntry]] = [:]
    @State private var notes: [String: String] = [:]
    @State private var abs = false
    @State private var status: String?
    @State private var restEnd: Date?

    private var day: Ares.Day? { program.days.first { $0.id == dayID } ?? program.days.first }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(program.days) { d in
                                Button { dayID = d.id; draft = [:] } label: {
                                    VStack(alignment: .leading) { Text(d.n).bold(); Text(d.t ?? "").font(.caption2) }
                                        .padding(10)
                                        .background(d.id == day?.id ? Theme.gold.opacity(0.25) : Theme.panel, in: .rect(cornerRadius: 10))
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                    if let note = day?.note { Text(note).font(.footnote).foregroundStyle(.secondary) }
                    if let restEnd { RestBanner(end: restEnd) { self.restEnd = nil } }
                    ForEach(day?.items ?? [], id: \.self) { item in card(item) }
                    Toggle("Abdominales hechos", isOn: $abs)
                    Button { Task { await save() } } label: { Text("Terminar y guardar").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                    if let status { Text(status).font(.footnote).foregroundStyle(.secondary) }
                }
                .padding()
            }
            .navigationTitle("ARES")
            .task { await load() }
        }
    }

    @ViewBuilder
    private func card(_ item: Ares.Item) -> some View {
        let k = Ares.key(item)
        let v = Ares.verdict(item, sessions: sessions)
        let plan = Ares.planned(v, item)
        let roles = Ares.roles(item.mode, item.sets)
        let mode = Ares.modes[item.mode]
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(program.ex[item.ex]?["n"] ?? item.ex).font(.headline)
                Spacer()
                Text(mode?.label ?? item.mode).font(.caption).foregroundStyle(item.mode == "F" ? Theme.gold : .secondary)
            }
            HStack(alignment: .top, spacing: 8) {
                Circle().fill(color(v.state)).frame(width: 10, height: 10).padding(.top, 5)
                VStack(alignment: .leading, spacing: 2) {
                    Text(v.head).font(.subheadline.bold()).foregroundStyle(color(v.state))
                    if let l = v.last { Text("Última primera serie: \(Ares.fmt(l.w)) kg × \(l.r)").font(.caption) }
                    Text(v.why).font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(Array(roles.enumerated()), id: \.offset) { i, role in
                HStack {
                    VStack(alignment: .leading) { Text(role.0).font(.subheadline); Text("\(role.1.lowerBound)–\(role.1.upperBound) reps").font(.caption2).foregroundStyle(.secondary) }
                        .frame(width: 80, alignment: .leading)
                    TextField(i < plan.count ? Ares.fmt(plan[i]) : "kg", value: binding(k, i, \.w, count: roles.count), format: .number)
                        .keyboardType(.decimalPad).textFieldStyle(.roundedBorder)
                    TextField("reps", value: binding(k, i, \.r, count: roles.count), format: .number)
                        .keyboardType(.numberPad).textFieldStyle(.roundedBorder)
                }
            }
            HStack {
                if !plan.isEmpty {
                    Button("Rellenar pautados") {
                        draft[k] = (0..<roles.count).map { i in .init(w: i < plan.count ? plan[i] : nil, r: draft[k]?[safe: i]?.r) }
                    }.font(.caption)
                }
                Spacer()
                Button("Descanso \(mode?.rest ?? 90) s") {
                    let s = mode?.rest ?? 90
                    restEnd = .now.addingTimeInterval(TimeInterval(s))
                    Ares.scheduleRest(seconds: s, exercise: program.ex[item.ex]?["n"] ?? item.ex)
                }.font(.caption).buttonStyle(.bordered)
            }
            TextField("Notas (asiento, agarre, sensaciones…)", text: Binding(get: { notes[k] ?? "" }, set: { notes[k] = $0 }), axis: .vertical)
                .font(.caption).textFieldStyle(.roundedBorder)
        }
        .padding().background(Theme.panel, in: .rect(cornerRadius: 14))
    }

    private func binding<T>(_ k: String, _ i: Int, _ path: WritableKeyPath<Ares.SetEntry, T?>, count: Int) -> Binding<T?> {
        Binding(
            get: { draft[k]?[safe: i]?[keyPath: path] },
            set: { v in
                var arr = draft[k] ?? []
                while arr.count < count { arr.append(.init(w: nil, r: nil)) }
                arr[i][keyPath: path] = v
                draft[k] = arr
            })
    }

    private func color(_ s: Ares.Verdict.State) -> Color {
        switch s { case .up: .green; case .hold: .orange; case .down: .red; case .new: .gray }
    }

    private func load() async {
        let client = Backend.shared.client
        struct P: Decodable { var program: Ares.Program }
        if let p: [P] = try? await client.from("ares_program").select("program").eq("id", value: "current").execute().value, let first = p.first {
            program = first.program
        }
        sessions = (try? await client.from("ares_sessions").select().order("ts", ascending: false).limit(200).execute().value) ?? []
        if dayID == nil { dayID = Ares.nextDay(program, sessions: sessions) }
    }

    private func save() async {
        guard let day else { return }
        var entries: [String: Ares.Entry] = [:]
        for item in day.items {
            let k = Ares.key(item)
            let sets = (draft[k] ?? []).filter { $0.w != nil && $0.r != nil }
            if !sets.isEmpty { entries[k] = .init(sets: sets, uni: nil, note: notes[k].flatMap { $0.isEmpty ? nil : $0 }) }
        }
        guard !entries.isEmpty else { status = "No hay series que guardar."; return }
        let now = Date()
        let s = Ares.Session(id: "s-\(Int64(now.timeIntervalSince1970 * 1000))",
                             date: now.formatted(Date.ISO8601FormatStyle(timeZone: .current).year().month().day()),
                             day: day.id, abs: abs, entries: entries, ts: Int64(now.timeIntervalSince1970 * 1000))
        do {
            try await Backend.shared.client.from("ares_sessions").insert(s).execute()
            sessions.insert(s, at: 0)
            draft = [:]; notes = [:]; abs = false
            status = "Sesión guardada."
            dayID = Ares.nextDay(program, sessions: sessions)
        } catch {
            status = "No se pudo guardar: \(error.localizedDescription)"
        }
    }
}

struct RestBanner: View {
    let end: Date
    let onDone: () -> Void
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let left = max(0, Int(end.timeIntervalSince(ctx.date)))
            HStack {
                Text("Descanso").font(.caption)
                Spacer()
                Text(String(format: "%d:%02d", left / 60, left % 60)).font(.title2.monospacedDigit().bold())
                    .foregroundStyle(left == 0 ? .green : Theme.gold)
                Button("Quitar", action: onDone).font(.caption)
            }
            .padding().background(Theme.panel, in: .rect(cornerRadius: 12))
        }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
