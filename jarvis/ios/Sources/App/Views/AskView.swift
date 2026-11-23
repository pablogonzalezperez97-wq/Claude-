import SwiftUI
import AVFoundation

/// Conversación con JARVIS. Las respuestas se pueden escuchar en voz alta.
struct AskView: View {
    @EnvironmentObject private var backend: Backend
    @State private var messages: [Backend.ChatMsg] = []
    @State private var input = ""
    @State private var busy = false
    @State private var speak = false
    private let synth = AVSpeechSynthesizer()

    private let suggestions = ["¿Cómo estoy hoy?", "¿Entreno fuerte o suave?", "¿Qué tal he dormido esta semana?", "Resúmeme la portada de MIDAS"]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            if messages.isEmpty {
                                ForEach(suggestions, id: \.self) { s in
                                    Button(s) { send(s) }.buttonStyle(.bordered)
                                }
                            }
                            ForEach(Array(messages.enumerated()), id: \.offset) { i, m in
                                Text(m.content)
                                    .padding(12)
                                    .background(m.role == "user" ? Theme.gold.opacity(0.2) : Theme.panel, in: .rect(cornerRadius: 14))
                                    .frame(maxWidth: .infinity, alignment: m.role == "user" ? .trailing : .leading)
                                    .id(i)
                            }
                            if busy { ProgressView().padding() }
                        }
                        .padding()
                    }
                    .onChange(of: messages.count) { _, n in withAnimation { proxy.scrollTo(n - 1) } }
                }
                HStack {
                    TextField("Pregunta a JARVIS", text: $input, axis: .vertical)
                        .lineLimit(1...4)
                        .padding(10).background(Theme.panel, in: .rect(cornerRadius: 12))
                    Button { send(input) } label: { Image(systemName: "arrow.up.circle.fill").font(.title) }
                        .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                }
                .padding()
            }
            .navigationTitle("JARVIS")
            .toolbar {
                Toggle(isOn: $speak) { Image(systemName: speak ? "speaker.wave.2.fill" : "speaker.slash") }
                    .toggleStyle(.button)
            }
        }
    }

    private func send(_ text: String) {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        let history = messages
        messages.append(.init(role: "user", content: q))
        input = ""; busy = true
        Task {
            let answer = (try? await backend.ask(q, history: history, voice: speak)) ?? "No he podido contactar con JARVIS."
            messages.append(.init(role: "assistant", content: answer))
            busy = false
            if speak {
                let u = AVSpeechUtterance(string: answer)
                u.voice = AVSpeechSynthesisVoice(language: "es-ES")
                synth.speak(u)
            }
        }
    }
}
