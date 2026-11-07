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
                        .foregroundStyle(Color.onBrand)
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
    case server, register, password, recovery
    var id: String { rawValue }
}

/// Named sizes of this screen (no tokens exist for them in `Theme`).
private enum LoginMetrics {
    /// Width of the sign-in column and the sheet column.
    static let columnMax: CGFloat = 460
    static let sheetColumnMax: CGFloat = 520
    static let logo: CGFloat = 96
    static let logoMax: CGFloat = 144
    #if os(macOS)
    static let sheetMin = CGSize(width: 440, height: 420)
    static let sheetIdeal = CGSize(width: 520, height: 560)
    #endif
}

struct LoginView: View {
    @Environment(AppModel.self) private var model
    @State private var sheet: LoginSheet?
    @State private var connection: ConnectionState
    @ScaledMetric(relativeTo: .largeTitle) private var logoSize = LoginMetrics.logo
    /// `false` in previews: the server check would replace the prepared state.
    private let runsCheck: Bool

    init() {
        _connection = State(initialValue: .unknown)
        runsCheck = true
    }

    fileprivate init(connection: ConnectionState, runsCheck: Bool) {
        _connection = State(initialValue: connection)
        self.runsCheck = runsCheck
    }

    var body: some View {
        ZStack {
            Color.canvas.ignoresSafeArea()
            ScrollView {
                VStack(spacing: Space.xl) {
                    header
                    card
                    secondaryActions
                }
                .readableWidth(LoginMetrics.columnMax)
                .pageMargins()
                .padding(.vertical, Space.xxl)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
        }
        .sheet(item: $sheet) { which in
            switch which {
            case .server: ServerSheet(connection: $connection)
            case .register: RegistrationSheet()
            case .password: PasswordSheet()
            case .recovery: RecoverySheet()
            }
        }
        .task {
            guard runsCheck else { return }
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
        VStack(spacing: Space.m) {
            LogoMark(size: min(logoSize, LoginMetrics.logoMax))
            Text("app.title").font(.system(.largeTitle, design: .rounded, weight: .bold))
            Text("login.tagline").font(.body).foregroundStyle(Color.textSecondary).multilineTextAlignment(.center)
        }
        .padding(.top, Space.xl)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var card: some View {
        VStack(spacing: Space.l) {
            serverRow
            if let key = model.errorKey, sheet == nil {
                ErrorBanner(key: key, detail: model.errorDetail, host: model.serverHost)
            }
            Button {
                Haptics.tap()
                Task { await model.loginWithPasskey() }
            } label: {
                HStack(spacing: Space.s) {
                    if model.busy { ProgressView().tint(Color.onBrand) } else { Image(systemName: "key.fill") }
                    Text("login.passkey")
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(model.busy || model.capabilities?.passkey != true)
            .accessibilityHint(Text("login.passkey.hint"))
        }
        .padding(Space.l)
        .cardSurface(radius: Radius.l)
    }

    private var serverRow: some View {
        Button { sheet = .server } label: {
            HStack(spacing: Space.m) {
                Image(systemName: "server.rack").foregroundStyle(Color.textSecondary).scaledSquare(Space.xl, relativeTo: .subheadline)
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text("login.server").font(.caption).foregroundStyle(Color.textSecondary)
                    Text(verbatim: hostText).font(.subheadline.weight(.medium)).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: Space.s)
                ConnectionBadge(state: connection)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Color.textSecondary)
            }
            .padding(.horizontal, Space.m).padding(.vertical, Space.m)
            .background(Color.canvas, in: RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
            .tapTarget()
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
        VStack(spacing: Space.xs) {
            Button("login.recovery") { model.resetRecovery(); sheet = .recovery }
                .disabled(model.capabilities == nil).tapTarget()
            Button("login.register") { sheet = .register }
                .disabled(model.capabilities == nil).tapTarget()
            if model.capabilities?.password == true {
                Button("login.passwordOption") { sheet = .password }.tapTarget()
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
        case .unknown: Circle().fill(Color.textSecondary.opacity(0.5)).scaledSquare(Space.s, relativeTo: .caption)
        case .checking: ProgressView().controlSize(.small)
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.dueToday)
        case .failed: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Color.dueOverdue)
        }
    }
}

struct ErrorBanner: View {
    let key: String
    /// Raw cause (for example the system error code), shown small below the text.
    var detail: String?
    /// Server host substituted for `%@` in texts that name the domain.
    var host: String?

    private var message: String {
        let text = Bundle.main.localizedString(forKey: key, value: key, table: nil)
        return text.contains("%@") ? String(format: text, host ?? "") : text
    }

    var body: some View {
        HStack(alignment: .top, spacing: Space.s) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.dueOverdue)
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(verbatim: message).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(verbatim: detail).font(.caption).foregroundStyle(Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Space.m)
        .background(Color.dueOverdue.opacity(0.12), in: RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(isEnabled ? Color.onBrand : Color.textSecondary)
            .frame(maxWidth: .infinity)
            .tapTarget()
            .padding(.vertical, Space.s).padding(.horizontal, Space.l)
            .background(isEnabled ? Color.brand.opacity(configuration.isPressed ? 0.85 : 1) : Color.hairline,
                        in: RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
            .contentShape(Rectangle())
    }
}

private struct FieldRow<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(title).font(.footnote.weight(.medium)).foregroundStyle(Color.textSecondary)
            content
                .textFieldStyle(.plain)
                .padding(.horizontal, Space.m).padding(.vertical, Space.m)
                .background(Color.canvasRaised, in: RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.m, style: .continuous).stroke(Color.hairline, lineWidth: 1))
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
                    VStack(alignment: .leading, spacing: Space.l) { content }
                        .readableWidth(LoginMetrics.sheetColumnMax)
                        .pageMargins()
                        .padding(.vertical, Space.l)
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
        .frame(minWidth: LoginMetrics.sheetMin.width, idealWidth: LoginMetrics.sheetIdeal.width,
               minHeight: LoginMetrics.sheetMin.height, idealHeight: LoginMetrics.sheetIdeal.height)
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
            Text("login.server.explain").font(.subheadline).foregroundStyle(Color.textSecondary)
            FieldRow(title: "login.serverURL") {
                TextField(accessible: "login.serverURL.placeholder", text: $model.serverURL)
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
                HStack(spacing: Space.s) {
                    if connection == .checking { ProgressView().tint(Color.onBrand) } else { Image(systemName: "bolt.horizontal.fill") }
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
            Label("login.status.ok", systemImage: "checkmark.circle.fill").foregroundStyle(Color.dueToday).font(.subheadline.weight(.medium))
        case .failed:
            ErrorBanner(key: model.errorKey ?? "error.network")
        case .checking:
            Label("login.status.checking", systemImage: "hourglass").foregroundStyle(Color.textSecondary).font(.subheadline)
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
                .font(.subheadline).foregroundStyle(Color.textSecondary)
            FieldRow(title: "login.setup.token") {
                TextField(accessible: "login.setup.token", text: $setupToken)
                    .focused($focus, equals: .token)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never).submitLabel(.next)
                    #endif
                    .onSubmit { focus = .name }
            }
            FieldRow(title: "login.setup.name") {
                TextField(accessible: "login.setup.name", text: $displayName)
                    .focused($focus, equals: .name)
                    #if os(iOS)
                    .textContentType(.name).submitLabel(.go)
                    #endif
                    .onSubmit(submit)
            }
            if let key = model.errorKey { ErrorBanner(key: key, detail: model.errorDetail, host: model.serverHost) }
            Button(action: submit) {
                HStack(spacing: Space.s) {
                    if model.busy { ProgressView().tint(Color.onBrand) } else { Image(systemName: "key.fill") }
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
            Text("login.password.explain").font(.subheadline).foregroundStyle(Color.textSecondary)
            FieldRow(title: "login.username") {
                TextField(accessible: "login.username", text: $username)
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
            if let key = model.errorKey { ErrorBanner(key: key, detail: model.errorDetail, host: model.serverHost) }
            Button(action: submit) {
                HStack(spacing: Space.s) {
                    if model.busy { ProgressView().tint(Color.onBrand) }
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

private struct RecoverySheet: View {
    @Environment(AppModel.self) private var model
    @State private var code = ""
    @State private var passkeyName = ""
    @FocusState private var focused: Bool

    var body: some View {
        SheetScaffold(title: "recovery.title") {
            Text("recovery.explain").font(.subheadline).foregroundStyle(Color.textSecondary)
            if model.recoveryToken == nil {
                FieldRow(title: "recovery.code") {
                    TextField(accessible: "recovery.code", text: $code)
                        .focused($focused)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                        #if os(iOS)
                        .textInputAutocapitalization(.never).submitLabel(.go)
                        #endif
                        .onSubmit(submit)
                }
            } else {
                Label("recovery.accepted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Color.dueToday).font(.subheadline.weight(.medium))
            }
            FieldRow(title: "recovery.passkeyName") {
                TextField(accessible: "recovery.passkeyName", text: $passkeyName)
                    .onSubmit(submit)
            }
            if let key = model.errorKey { ErrorBanner(key: key, detail: model.errorDetail, host: model.serverHost) }
            Button(action: submit) {
                HStack(spacing: Space.s) {
                    if model.busy { ProgressView().tint(Color.onBrand) } else { Image(systemName: "key.fill") }
                    Text(model.recoveryToken == nil ? "recovery.submit" : "recovery.retry")
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!canSubmit)
        }
        .onAppear { model.resetRecovery(); focused = true }
    }

    private var canSubmit: Bool {
        !model.busy && (model.recoveryToken != nil || !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private func submit() {
        guard canSubmit else { return }
        Task { await model.recover(code: code, passkeyName: passkeyName) }
    }
}

// MARK: Previews

#if DEBUG
private enum LoginPreviewState: String, CaseIterable {
    case unreachable, connected, error, registration, password, recovery

    @MainActor var model: AppModel {
        let model = AppModel()
        model.serverURL = "https://todo.example.com"
        let caps = Capabilities(passkey: true, password: true, bootstrapOpen: false)
        switch self {
        case .unreachable:
            model.capabilities = nil
            model.errorKey = "error.network"
        case .connected, .registration, .password, .recovery:
            model.capabilities = caps
        case .error:
            model.capabilities = caps
            model.errorKey = "error.passkey.failed"
            model.errorDetail = "ASAuthorizationError 1001"
        }
        return model
    }
}

private struct LoginPreview: View {
    let state: LoginPreviewState
    var body: some View {
        let model = state.model
        Group {
            switch state {
            case .unreachable: LoginView(connection: .failed, runsCheck: false)
            case .connected, .error: LoginView(connection: .ok, runsCheck: false)
            case .registration: RegistrationSheet()
            case .password: PasswordSheet()
            case .recovery: RecoverySheet()
            }
        }
        .environment(model)
    }
}

#Preview("Login unreachable light") { LoginPreview(state: .unreachable).preferredColorScheme(.light) }
#Preview("Login unreachable dark") { LoginPreview(state: .unreachable).preferredColorScheme(.dark) }
#Preview("Login unreachable accessibility5") { LoginPreview(state: .unreachable).dynamicTypeSize(.accessibility5) }
#Preview("Login connected light") { LoginPreview(state: .connected).preferredColorScheme(.light) }
#Preview("Login connected dark") { LoginPreview(state: .connected).preferredColorScheme(.dark) }
#Preview("Login connected accessibility5") { LoginPreview(state: .connected).dynamicTypeSize(.accessibility5) }
#Preview("Login error light") { LoginPreview(state: .error).preferredColorScheme(.light) }
#Preview("Login error dark") { LoginPreview(state: .error).preferredColorScheme(.dark) }
#Preview("Login error accessibility5") { LoginPreview(state: .error).dynamicTypeSize(.accessibility5) }
#Preview("Registration light") { LoginPreview(state: .registration).preferredColorScheme(.light) }
#Preview("Registration dark") { LoginPreview(state: .registration).preferredColorScheme(.dark) }
#Preview("Registration accessibility5") { LoginPreview(state: .registration).dynamicTypeSize(.accessibility5) }
#Preview("Password light") { LoginPreview(state: .password).preferredColorScheme(.light) }
#Preview("Password dark") { LoginPreview(state: .password).preferredColorScheme(.dark) }
#Preview("Password accessibility5") { LoginPreview(state: .password).dynamicTypeSize(.accessibility5) }
#Preview("Recovery light") { LoginPreview(state: .recovery).preferredColorScheme(.light) }
#Preview("Recovery dark") { LoginPreview(state: .recovery).preferredColorScheme(.dark) }
#Preview("Recovery accessibility5") { LoginPreview(state: .recovery).dynamicTypeSize(.accessibility5) }

private struct ServerSheetPreview: View {
    var body: some View {
        ServerSheet(connection: .constant(.failed)).environment(LoginPreviewState.unreachable.model)
    }
}
#Preview("Server sheet unreachable light") { ServerSheetPreview().preferredColorScheme(.light) }
#Preview("Server sheet unreachable accessibility5") { ServerSheetPreview().dynamicTypeSize(.accessibility5) }
#endif
