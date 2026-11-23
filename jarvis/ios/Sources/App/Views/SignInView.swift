import SwiftUI

/// Acceso con código de un solo uso enviado al correo del propietario.
/// No se crean cuentas: solo entra el usuario registrado como propietario.
struct SignInView: View {
    @EnvironmentObject private var backend: Backend
    @State private var email = ""
    @State private var code = ""
    @State private var sent = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Text("JARVIS").font(.system(size: 44, weight: .bold, design: .serif)).foregroundStyle(Theme.gold)
            Text("Entorno de control personal").foregroundStyle(.secondary)
            Spacer()
            if !sent {
                TextField("Correo", text: $email)
                    .textContentType(.emailAddress).keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .padding().background(Theme.panel, in: .rect(cornerRadius: 12))
                Button("Enviarme un código") { run { try await backend.sendCode(to: email); sent = true } }
                    .buttonStyle(.borderedProminent).disabled(email.isEmpty || busy)
            } else {
                TextField("Código de 6 dígitos", text: $code)
                    .textContentType(.oneTimeCode).keyboardType(.numberPad)
                    .padding().background(Theme.panel, in: .rect(cornerRadius: 12))
                Button("Entrar") { run { try await backend.verify(email: email, code: code) } }
                    .buttonStyle(.borderedProminent).disabled(code.count < 6 || busy)
                Button("Cambiar correo") { sent = false; code = "" }.font(.footnote)
            }
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            Spacer()
        }
        .padding(24)
    }

    private func run(_ op: @escaping () async throws -> Void) {
        busy = true; error = nil
        Task {
            do { try await op() } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}
