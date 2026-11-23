import Foundation
import Supabase
import WidgetKit

/// Acceso a Supabase: sesión del propietario, funciones y tablas de los agentes.
@MainActor
final class Backend: ObservableObject {
    static let shared = Backend()

    let client: SupabaseClient
    @Published private(set) var signedIn = false
    @Published var today: Today? = SharedStore.load()
    @Published var lastError: String?

    private init() {
        let info = Bundle.main.infoDictionary ?? [:]
        let url = URL(string: info["SUPABASE_URL"] as? String ?? "")!
        let key = info["SUPABASE_PUBLISHABLE_KEY"] as? String ?? ""
        client = SupabaseClient(supabaseURL: url, supabaseKey: key)
        Task { await observeAuth() }
    }

    private func observeAuth() async {
        for await (_, session) in client.auth.authStateChanges {
            signedIn = session != nil
        }
    }

    // MARK: Acceso con código por correo (sin contraseña)

    func sendCode(to email: String) async throws {
        try await client.auth.signInWithOTP(email: email, shouldCreateUser: false)
    }

    func verify(email: String, code: String) async throws {
        try await client.auth.verifyOTP(email: email, token: code, type: .email)
    }

    func signOut() async { try? await client.auth.signOut() }

    // MARK: Funciones

    func refreshToday() async {
        do {
            let t: Today = try await client.functions.invoke("jarvis-today", options: .init(method: .get), decoder: Today.decoder)
            today = t
            lastError = nil
            SharedStore.save(t)
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            lastError = "No se pudo actualizar: \(error.localizedDescription)"
        }
    }

    struct AskReply: Decodable { var answer: String?; var error: String? }
    struct ChatMsg: Codable { var role: String; var content: String }

    func ask(_ question: String, history: [ChatMsg] = [], voice: Bool = false) async throws -> String {
        struct Body: Encodable { var question: String; var history: [ChatMsg]; var voice: Bool }
        let reply: AskReply = try await client.functions.invoke(
            "jarvis-ask", options: .init(body: Body(question: question, history: history, voice: voice)))
        return reply.answer ?? "JARVIS no ha podido responder (\(reply.error ?? "error"))."
    }

    func uploadHealth(_ payload: HealthPayload) async throws {
        try await client.functions.invoke("healthkit-sync", options: .init(body: payload))
    }

    func registerDevice(token: String) async {
        struct Row: Encodable { var token: String; var platform = "ios"; var environment: String }
        #if DEBUG
        let env = "sandbox"
        #else
        let env = "production"
        #endif
        _ = try? await client.from("devices").upsert(Row(token: token, environment: env)).execute()
    }
}
