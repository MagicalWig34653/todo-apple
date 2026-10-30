import SwiftUI
import TodoCore

/// Logo mark: three nested rounded cards with a checkmark (the app icon motif), drawn in the brand color.
struct LogoMark: View {
    var size: CGFloat = 88

    var body: some View {
        let card = size * 0.62
        let step = size * 0.13
        let radius = size * 0.18
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Color.brand.opacity(0.28)).frame(width: card, height: card)
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Color.brand.opacity(0.58)).frame(width: card, height: card).offset(x: step, y: step)
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Color.brand).frame(width: card, height: card).offset(x: step * 2, y: step * 2)
                .shadow(color: Color.brand.opacity(0.35), radius: size * 0.1, y: size * 0.04)
                .overlay {
                    Image(systemName: "checkmark")
                        .font(.system(size: card * 0.46, weight: .heavy))
                        .foregroundStyle(.white)
                        .offset(x: step * 2, y: step * 2)
                }
        }
        .frame(width: card + step * 2, height: card + step * 2, alignment: .topLeading)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private enum ConnectionState: Equatable {
    case unknown, checking, ok, failed
}

private enum LoginSheet: String, Identifiable {
    case server, register, password
    var id: String { rawValue }
}

struct LoginView: View {
    @Environment(AppModel.self) private var model
    @State private var sheet: LoginSheet?
    @State private var connection: ConnectionState = .unknown

    var body: some View {
        ZStack {
            Color.canvas.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 28) {
                    header
                    card
                    secondaryActions
                }
                .frame(maxWidth: 460)
                .padding(.horizontal, 20)
                .padding(.vertical, 32)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
        }
        .sheet(item: $sheet) { which in
            switch which {
            case .server: ServerSheet(connection: $connection)
            case .register: RegistrationSheet()
            case .password: PasswordSheet()
            }
        }
        .task {
            await check()
            #if DEBUG
            sheet = LoginSheet(rawValue: ProcessInfo.processInfo.environment["TODO_DEBUG_LOGIN_SHEET"] ?? "")
            #endif
        }
    }

    private func check() async {
        connection = .checking
        await model.refreshCapabilities()
        connection = model.capabilities != nil ? .ok : .failed
    }

    // MARK: Parts

    private var header: some View {
        VStack(spacing: 14) {
            LogoMark(size: 96)
            Text(verbatim: "Todo").font(.system(.largeTitle, design: .rounded, weight: .bold))
            Text("login.tagline").font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(.top, 24)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var card: some View {
        VStack(spacing: 16) {
            serverRow
            if let key = model.errorKey, sheet == nil {
                ErrorBanner(key: key)
            }
            Button {
                Haptics.tap()
                Task { await model.loginWithPasskey() }
            } label: {
                HStack(spacing: 10) {
                    if model.busy { ProgressView().tint(.white) } else { Image(systemName: "key.fill") }
                    Text("login.passkey")
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(model.busy || model.capabilities?.passkey != true)
            .accessibilityHint(Text("login.passkey.hint"))
        }
        .padding(20)
        .background(Color.canvasRaised, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Color.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.05), radius: 16, y: 6)
    }

    private var serverRow: some View {
        Button { sheet = .server } label: {
            HStack(spacing: 12) {
                Image(systemName: "server.rack").foregroundStyle(.secondary).frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text("login.server").font(.caption).foregroundStyle(.secondary)
                    Text(verbatim: hostText).font(.subheadline.weight(.medium)).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 8)
                ConnectionBadge(state: connection)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(Color.canvas, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("login.server"))
        .accessibilityValue(Text(verbatim: hostText + ", " + connection.accessibilityText))
        .accessibilityHint(Text("login.server.hint"))
    }

    private var hostText: String {
        if let url = URL(string: model.serverURL), let host = url.host {
            return url.port.map { "\(host):\($0)" } ?? host
        }
        return model.serverURL
    }

    private var secondaryActions: some View {
        VStack(spacing: 6) {
            Button("login.register") { sheet = .register }
                .disabled(model.capabilities == nil)
            if model.capabilities?.password == true {
                Button("login.passwordOption") { sheet = .password }
            }
        }
        .buttonStyle(.borderless)
        .font(.body.weight(.medium))
        .tint(Color.brand)
        .controlSize(.large)
    }
}

// MARK: Components

private extension ConnectionState {
    var accessibilityText: String {
        switch self {
        case .unknown: String(localized: "login.status.unknown")
        case .checking: String(localized: "login.status.checking")
        case .ok: String(localized: "login.status.ok")
        case .failed: String(localized: "login.status.failed")
        }
    }
}

private struct ConnectionBadge: View {
    let state: ConnectionState

    var body: some View {
        switch state {
        case .unknown: Circle().fill(Color.secondary.opacity(0.4)).frame(width: 9, height: 9)
        case .checking: ProgressView().controlSize(.small)
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.green)
        case .failed: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Color.dueOverdue)
        }
    }
}

struct ErrorBanner: View {
    let key: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.dueOverdue)
            Text(LocalizedStringKey(key)).font(.subheadline).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.dueOverdue.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 28)
            .padding(.vertical, 14).padding(.horizontal, 16)
            .background(Color.brand.opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.4),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(Rectangle())
    }
}

private struct FieldRow<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.footnote.weight(.medium)).foregroundStyle(.secondary)
            content
                .textFieldStyle(.plain)
                .padding(.horizontal, 14).padding(.vertical, 12)
                .background(Color.canvasRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.hairline, lineWidth: 1))
        }
    }
}

/// Shared chrome of the three sheets: large title, scrolling content, close button.
private struct SheetScaffold<Content: View>: View {
    let title: LocalizedStringKey
    @Environment(\.dismiss) private var dismiss
    @ViewBuilder var content: Content

    var body: some View {
        NavigationStack {
            ZStack {
                Color.canvas.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) { content }
                        .frame(maxWidth: 520).padding(20).frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.large)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("login.close") { dismiss() } }
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 420)
        #endif
    }
}

// MARK: Sheets

private struct ServerSheet: View {
    @Environment(AppModel.self) private var model
    @Binding var connection: ConnectionState

    var body: some View {
        @Bindable var model = model
        SheetScaffold(title: "login.server") {
            Text("login.server.explain").font(.subheadline).foregroundStyle(.secondary)
            FieldRow(title: "login.serverURL") {
                TextField("login.serverURL.placeholder", text: $model.serverURL)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never).keyboardType(.URL).submitLabel(.go)
                    #endif
                    .onSubmit { Task { await check() } }
            }
            statusView
            Button {
                Task { await check() }
            } label: {
                HStack(spacing: 10) {
                    if connection == .checking { ProgressView().tint(.white) } else { Image(systemName: "bolt.horizontal.fill") }
                    Text("login.checkServer")
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(connection == .checking)
        }
    }

    @ViewBuilder private var statusView: some View {
        switch connection {
        case .ok:
            Label("login.status.ok", systemImage: "checkmark.circle.fill").foregroundStyle(Color.green).font(.subheadline.weight(.medium))
        case .failed:
            ErrorBanner(key: model.errorKey ?? "error.network")
        case .checking:
            Label("login.status.checking", systemImage: "hourglass").foregroundStyle(.secondary).font(.subheadline)
        case .unknown: EmptyView()
        }
    }

    private func check() async {
        connection = .checking
        // The health endpoint tells an unreachable host apart from a missing API.
        let reachable: Bool
        if let client = model.client { reachable = (try? await client.ready()) != nil } else { reachable = false }
        await model.refreshCapabilities()
        connection = reachable && model.capabilities != nil ? .ok : .failed
        if connection == .ok { Haptics.success() }
    }
}

private struct RegistrationSheet: View {
    @Environment(AppModel.self) private var model
    @State private var setupToken = ""
    @State private var displayName = ""
    @FocusState private var focus: Field?
    private enum Field { case token, name }

    var body: some View {
        SheetScaffold(title: "login.register") {
            Text(model.capabilities?.bootstrapOpen == true ? "login.setup.bootstrap" : "login.setup.invitation")
                .font(.subheadline).foregroundStyle(.secondary)
            FieldRow(title: "login.setup.token") {
                TextField("login.setup.token", text: $setupToken)
                    .focused($focus, equals: .token)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never).submitLabel(.next)
                    #endif
                    .onSubmit { focus = .name }
            }
            FieldRow(title: "login.setup.name") {
                TextField("login.setup.name", text: $displayName)
                    .focused($focus, equals: .name)
                    #if os(iOS)
                    .textContentType(.name).submitLabel(.go)
                    #endif
                    .onSubmit(submit)
            }
            if let key = model.errorKey { ErrorBanner(key: key) }
            Button(action: submit) {
                HStack(spacing: 10) {
                    if model.busy { ProgressView().tint(.white) } else { Image(systemName: "key.fill") }
                    Text("login.setup.create")
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!canSubmit)
        }
        .onAppear { model.errorKey = nil }
    }

    private var canSubmit: Bool {
        !model.busy && !setupToken.trimmingCharacters(in: .whitespaces).isEmpty
            && !displayName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func submit() {
        guard canSubmit else { return }
        Task { await model.register(token: setupToken, displayName: displayName) }
    }
}

private struct PasswordSheet: View {
    @Environment(AppModel.self) private var model
    @State private var username = ""
    @State private var password = ""
    @FocusState private var focus: Field?
    private enum Field { case user, password }

    var body: some View {
        SheetScaffold(title: "login.passwordOption") {
            Text("login.password.explain").font(.subheadline).foregroundStyle(.secondary)
            FieldRow(title: "login.username") {
                TextField("login.username", text: $username)
                    .focused($focus, equals: .user)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never).textContentType(.username).submitLabel(.next)
                    #endif
                    .onSubmit { focus = .password }
            }
            FieldRow(title: "login.password") {
                SecureField("login.password", text: $password)
                    .focused($focus, equals: .password)
                    #if os(iOS)
                    .textContentType(.password).submitLabel(.go)
                    #endif
                    .onSubmit(submit)
            }
            if let key = model.errorKey { ErrorBanner(key: key) }
            Button(action: submit) {
                HStack(spacing: 10) {
                    if model.busy { ProgressView().tint(.white) }
                    Text("login.passwordSignIn")
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!canSubmit)
        }
        .onAppear { model.errorKey = nil }
    }

    private var canSubmit: Bool { !model.busy && !username.isEmpty && !password.isEmpty }

    private func submit() {
        guard canSubmit else { return }
        Task { await model.loginWithPassword(username: username, password: password) }
    }
}
