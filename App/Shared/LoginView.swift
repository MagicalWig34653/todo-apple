import SwiftUI

struct LoginView: View {
    @Environment(AppModel.self) private var model
    @State private var showSetup = false
    @State private var showOther = false
    @State private var setupToken = ""
    @State private var displayName = ""
    @State private var username = ""
    @State private var password = ""

    var body: some View {
        @Bindable var model = model
        Form {
            Section("login.server") {
                TextField("login.serverURL", text: $model.serverURL)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never).keyboardType(.URL)
                    #endif
                    .onSubmit { Task { await model.refreshCapabilities() } }
                Button("login.checkServer") { Task { await model.refreshCapabilities() } }
            }
            Section {
                Button("login.passkey") { Task { await model.loginWithPasskey() } }
                    .disabled(model.busy || model.capabilities?.passkey != true)
            }
            Section {
                DisclosureGroup("login.setup", isExpanded: $showSetup) {
                    Text(model.capabilities?.bootstrapOpen == true ? "login.setup.bootstrap" : "login.setup.invitation")
                        .font(.footnote).foregroundStyle(.secondary)
                    TextField("login.setup.token", text: $setupToken).autocorrectionDisabled()
                    TextField("login.setup.name", text: $displayName)
                    Button("login.setup.create") {
                        Task { await model.register(token: setupToken, displayName: displayName) }
                    }
                    .disabled(model.busy || setupToken.isEmpty || displayName.isEmpty)
                }
            }
            if model.capabilities?.password == true {
                Section {
                    DisclosureGroup("login.other", isExpanded: $showOther) {
                        TextField("login.username", text: $username).autocorrectionDisabled()
                        SecureField("login.password", text: $password)
                        Button("login.passwordSignIn") {
                            Task { await model.loginWithPassword(username: username, password: password) }
                        }
                        .disabled(model.busy || username.isEmpty || password.isEmpty)
                    }
                }
            }
            if let key = model.errorKey {
                Section { Text(LocalizedStringKey(key)).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 520)
        .task { await model.refreshCapabilities() }
    }
}
