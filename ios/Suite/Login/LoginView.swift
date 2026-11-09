import SwiftUI

struct LoginView: View {
    @Environment(AppSession.self) private var session

    @State private var site = ""
    @State private var email = ""
    @State private var password = ""
    @State private var isSigningIn = false
    @State private var error: String?
    @FocusState private var focus: Field?

    private enum Field { case site, email, password }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    header
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                }
                Section {
                    TextField("suite.frappe.io", text: $site)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .focused($focus, equals: .site)
                        .submitLabel(.next)
                        .onSubmit { focus = .email }
                } header: {
                    Text("Site")
                }
                Section {
                    TextField("Email", text: $email)
                        .textContentType(.username)
                        .keyboardType(.emailAddress)
                        .focused($focus, equals: .email)
                        .submitLabel(.next)
                        .onSubmit { focus = .password }
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .focused($focus, equals: .password)
                        .submitLabel(.go)
                        .onSubmit(signIn)
                } header: {
                    Text("Account")
                } footer: {
                    if let error {
                        Text(error).foregroundStyle(.red)
                    }
                }
                Section {
                    Button(action: signIn) {
                        HStack {
                            Spacer()
                            if isSigningIn { ProgressView() } else { Text("Sign in").bold() }
                            Spacer()
                        }
                    }
                    .disabled(!canSubmit)
                }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        }
        .onAppear {
            site = session.lastSite ?? ""
            focus = site.isEmpty ? .site : .email
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 40, weight: .medium))
                .foregroundStyle(.primary)
            Text("Frappe Suite")
                .font(.largeTitle.bold())
            Text("Sign in to your site.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private var canSubmit: Bool {
        !isSigningIn && !site.isEmpty && !email.isEmpty && !password.isEmpty
    }

    private func signIn() {
        guard canSubmit else { return }
        isSigningIn = true
        error = nil
        Task {
            defer { isSigningIn = false }
            do {
                try await session.signIn(site: site, email: email, password: password)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
