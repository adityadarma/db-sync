import SwiftUI
import Foundation
import AppKit

private enum SmallFont {
    static let captionSize = NSFont.preferredFont(forTextStyle: .caption1).pointSize + 1
    static let caption = Font.system(size: captionSize)
    static let monospacedCaption = Font.system(size: captionSize, design: .monospaced)
    static let subheadline = Font.system(size: NSFont.preferredFont(forTextStyle: .subheadline).pointSize + 1)
}

enum L10n {
    static func text(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: Locale.autoupdatingCurrent, arguments: arguments)
    }
}

private struct FormCard: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    var highlighted = false

    func body(content: Content) -> some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                highlighted ? Color.accentColor.opacity(colorScheme == .dark ? 0.14 : 0.07)
                    : Color.primary.opacity(colorScheme == .dark ? 0.105 : 0.035),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(highlighted ? Color.accentColor.opacity(0.65)
                                  : Color.primary.opacity(colorScheme == .dark ? 0.22 : 0.15))
            }
    }
}

private struct FormInput: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.35 : 0.23))
            }
    }
}

private struct FormPicker: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .padding(3)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.32 : 0.19))
            }
    }
}

/// Keeps the normal macOS title-bar safe area while hiding the duplicate title.
/// A hidden title bar lets scroll content pass underneath the traffic lights.
private struct WindowChromeConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            view.window?.titleVisibility = .hidden
            view.window?.titlebarAppearsTransparent = false
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.window?.titleVisibility = .hidden
        nsView.window?.titlebarAppearsTransparent = false
    }
}

struct Profile: Codable, Identifiable, Hashable {
    let id: String
    var name: String
    var host: String
    var port: Int
    var user: String
    var database: String?
    var isTablePlus: Bool?
    var driver: String?
    var ssh: SSHConfiguration? = nil

    static func == (lhs: Profile, rhs: Profile) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// TablePlus connection IDs can change when a plist is restored or copied.
    /// Database credentials are shared by the server account, so use that stable
    /// identity for the app's Keychain item instead of the plist record ID.
    var passwordKey: String {
        let normalizedDriver = (driver ?? NativeDatabaseDriver.mysql.rawValue).lowercased()
        return "v2|\(normalizedDriver)|\(host.lowercased())|\(port)|\(user.lowercased())"
    }
}

struct SSHConfiguration: Codable, Hashable, Sendable {
    var host: String
    var port: Int
    var user: String
    var privateKeyPath: String?
}

enum ProfileStore {
    private static var directory: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return root.appendingPathComponent("dev.adityadarma.dbsync", isDirectory: true)
    }
    private static var file: URL { directory.appendingPathComponent("connections.json") }

    static func load() throws -> [Profile] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        return try JSONDecoder().decode([Profile].self, from: Data(contentsOf: file))
    }

    static func save(_ profiles: [Profile]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(profiles).write(to: file, options: .atomic)
    }
}

enum BridgeError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let message) = self { return L10n.text(message) }
        return nil
    }
}

@MainActor final class SyncModel: ObservableObject {
    @Published var profiles: [Profile] = []
    @Published var busy = false
    @Published var status = L10n.text("Memuat koneksi…")
    @Published var preview: [String: Any]?
    @Published var connectionPath: String = UserDefaults.standard.string(forKey: "tableplus.connections.path") ?? ""

    private let databaseAdapters = NativeDatabaseAdapterRegistry()

    init() { Task { await loadProfiles() } }

    func chooseConnectionFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.prompt = L10n.text("Impor Koneksi")
        panel.message = L10n.text("Pilih folder yang berisi Connections.plist TablePlus.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        connectionPath = url.path
        UserDefaults.standard.set(connectionPath, forKey: "tableplus.connections.path")
        Task { await importTablePlusConnections() }
    }

    func listDatabases(for profile: Profile, password: String) async throws -> [String] {
        let endpoint = NativeDatabaseEndpoint(
            host: profile.host,
            port: profile.port,
            user: profile.user,
            password: password,
            database: "",
            driver: NativeDatabaseDriver(tablePlusValue: profile.driver), ssh: profile.ssh
        )
        return try await databaseAdapters.adapter(for: endpoint.driver).listDatabases(for: endpoint)
    }

    func savedPassword(for profile: Profile) -> String? {
        NativePasswordStore.password(for: profile.passwordKey, legacyConnectionIDs: [profile.id])
    }

    func savePassword(_ password: String, for profile: Profile) throws {
        try NativePasswordStore.save(password, for: profile.passwordKey)
    }

    func removeSavedPassword(for profile: Profile) throws {
        try NativePasswordStore.removePassword(for: profile.passwordKey, legacyConnectionIDs: [profile.id])
    }

    func previewStructure(_ input: [String: Any]) async throws -> [String: Any] {
        guard let request = NativeStructureRequest(dictionary: input) else {
            throw BridgeError.message("Konfigurasi koneksi struktur tidak valid.")
        }
        return try await databaseAdapters.adapter(for: request.source.driver).previewStructure(request).dictionary()
    }

    func applyStructure(_ input: [String: Any], fingerprint: String, confirmation: String) async throws -> Int {
        guard let request = NativeStructureRequest(dictionary: input) else {
            throw BridgeError.message("Konfigurasi koneksi struktur tidak valid.")
        }
        guard confirmation == request.destination.database else {
            throw BridgeError.message("Ketik nama database tujuan untuk mengonfirmasi.")
        }
        return try await databaseAdapters.adapter(for: request.source.driver).applyStructure(request, fingerprint: fingerprint)
    }

    func previewData(_ input: [String: Any]) async throws -> [String: Any] {
        guard let request = NativeStructureRequest(dictionary: input) else {
            throw BridgeError.message("Konfigurasi koneksi data tidak valid.")
        }
        return try await databaseAdapters.adapter(for: request.source.driver).previewData(request).previewDictionary()
    }

    func applyData(_ input: [String: Any], fingerprint: String, confirmation: String) async throws -> (tables: Int, inserted: Int, updated: Int, deleted: Int) {
        guard let request = NativeStructureRequest(dictionary: input) else {
            throw BridgeError.message("Konfigurasi koneksi data tidak valid.")
        }
        guard confirmation == request.destination.database else {
            throw BridgeError.message("Ketik nama database tujuan untuk mengonfirmasi.")
        }
        let result = try await databaseAdapters.adapter(for: request.source.driver).applyData(request, fingerprint: fingerprint)
        return result
    }

    func dataDetails(_ input: [String: Any]) async throws -> [String: Any] {
        guard let request = NativeStructureRequest(dictionary: input),
              let table = input["table"] as? String,
              let kind = input["kind"] as? String,
              let fingerprint = input["tableFingerprint"] as? String else {
            throw BridgeError.message("Konfigurasi rincian data tidak valid.")
        }
        let details = try await databaseAdapters.adapter(for: request.source.driver).dataDetails(
            request, table: table, kind: kind,
            offset: input["offset"] as? Int ?? 0,
            limit: input["limit"] as? Int ?? 20,
            tableFingerprint: fingerprint)
        return details.dictionary()
    }

    private func tablePlusProfilesFromDisk() throws -> [Profile] {
        var loaded: [Profile] = []
        if let plistURL = connectionsPlistURL(),
           let data = try? Data(contentsOf: plistURL),
           let raw = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [[String: Any]] {
            loaded += raw.compactMap { item in
                guard let driver = item["Driver"] as? String,
                      driver == "MySQL" || driver == "MariaDB" else { return nil }
                let name = (item["ConnectionName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let host = (item["DatabaseHost"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let user = (item["DatabaseUser"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let name, !name.isEmpty, let host, !host.isEmpty, let user, !user.isEmpty else { return nil }
                let port = (item["DatabasePort"] as? NSNumber)?.intValue ?? Int(item["DatabasePort"] as? String ?? "") ?? 3306
                guard (1...65535).contains(port) else { return nil }
                let rawID = String(describing: item["ID"] ?? UUID().uuidString)
                let database = item["DatabaseName"] as? String
                return Profile(id: "import_tableplus_\(rawID)", name: name, host: host, port: port,
                               user: user, database: database, isTablePlus: true, driver: driver, ssh: nil)
            }
        }
        return loaded
    }

    private func connectionsPlistURL() -> URL? {
        let custom = connectionPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let directory = custom.isEmpty
            ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/com.tinyapp.TablePlus/Data")
            : URL(fileURLWithPath: custom, isDirectory: true)
        let candidate = directory.pathExtension == "plist" ? directory : directory.appendingPathComponent("Connections.plist")
        return FileManager.default.isReadableFile(atPath: candidate.path) ? candidate : nil
    }

    func loadProfiles() async {
        await run(L10n.text("Memuat koneksi…")) {
            profiles = try ProfileStore.load()
            status = L10n.format("%d koneksi tersedia.", profiles.count)
        }
    }

    func importTablePlusConnections() async {
        await run(L10n.text("Mengimpor koneksi TablePlus…")) {
            let imported = try tablePlusProfilesFromDisk()
            let existingKeys = Set(profiles.map(\.passwordKey))
            let additions = imported.filter { !existingKeys.contains($0.passwordKey) }
            profiles.append(contentsOf: additions)
            try ProfileStore.save(profiles)
            status = L10n.format("%d koneksi TablePlus diimpor.", additions.count)
        }
    }

    func saveProfile(_ profile: Profile) throws {
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        profiles.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        try ProfileStore.save(profiles)
    }

    func deleteProfile(id: String) throws {
        profiles.removeAll { $0.id == id }
        try ProfileStore.save(profiles)
    }

    func run(_ message: String, operation: () async throws -> Void) async {
        busy = true
        status = message
        do { try await operation() }
        catch { status = error.localizedDescription }
        busy = false
    }
}

struct EndpointPane: View {
    let title: String
    let highlighted: Bool
    let profiles: [Profile]
    @Binding var profileID: String
    @Binding var password: String
    @Binding var database: String
    let retryDatabases: () -> Void
    let databases: [String]
    let loading: Bool
    let error: String
    let hasSavedPassword: Bool
    let removeSavedPassword: () -> Void
    @State private var showPasswordEditor = false

    private var needsPassword: Bool {
        let message = error.lowercased()
        return message.contains("access denied") || message.contains("using password: no") ||
            message.contains("password") || message.contains("authentication")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(LocalizedStringKey(title)).font(SmallFont.subheadline.weight(.semibold))
            Text("Koneksi tersimpan").font(SmallFont.subheadline.weight(.medium))
            Picker("Koneksi tersimpan", selection: $profileID) {
                Text("Pilih koneksi").tag("")
                ForEach(profiles) { profile in
                    Text(verbatim: "\(profile.name) (\(profile.host):\(profile.port))").tag(profile.id)
                }
            }
            .labelsHidden()
            .modifier(FormPicker())
            .frame(maxWidth: .infinity, alignment: .leading)

            if !profileID.isEmpty && hasSavedPassword {
                HStack(spacing: 7) {
                    Label("Password tersimpan aman di Keychain", systemImage: "key.fill")
                        .font(SmallFont.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Hapus password", action: removeSavedPassword)
                        .font(SmallFont.caption)
                }
            }

            if profileID.isEmpty {
                Label("Mulai dengan memilih koneksi.", systemImage: "1.circle")
                    .font(SmallFont.caption).foregroundStyle(.secondary)
            } else if loading {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text("Menyambungkan dan memuat daftar database…")
                }
                .font(SmallFont.caption).foregroundStyle(.secondary)
            } else if needsPassword {
                Label("Password diperlukan untuk koneksi ini.", systemImage: "key.fill")
                    .font(SmallFont.subheadline.weight(.semibold)).foregroundStyle(.red)
                Text("Masukkan password, lalu sambungkan untuk memuat daftar database.")
                    .font(SmallFont.caption).foregroundStyle(.secondary)
                SecureField("Password database", text: $password)
                    .modifier(FormInput())
                    .onSubmit(retryDatabases)
                Button("Sambungkan & muat database", action: retryDatabases)
                    .buttonStyle(.borderedProminent)
                DisclosureGroup("Rincian kesalahan teknis") {
                    Text(error).font(SmallFont.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .font(SmallFont.caption)
            } else if !error.isEmpty {
                Label("Koneksi belum dapat dimuat", systemImage: "exclamationmark.triangle.fill")
                    .font(SmallFont.subheadline.weight(.semibold)).foregroundStyle(.red)
                Text(error).font(SmallFont.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Button("Coba lagi", action: retryDatabases)
                    .buttonStyle(.bordered)
            } else {
                Text("Database").font(SmallFont.subheadline.weight(.medium))
                Picker("Database", selection: $database) {
                    Text(loading ? LocalizedStringKey("Memuat database…") : LocalizedStringKey("Pilih database")).tag("")
                    ForEach(databases, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .modifier(FormPicker())
                .frame(maxWidth: .infinity, alignment: .leading)
                .disabled(profileID.isEmpty || loading || !error.isEmpty)
                if databases.isEmpty {
                    Text("Tidak ada database yang tersedia.")
                        .font(SmallFont.caption).foregroundStyle(.secondary)
                }
                DisclosureGroup("Ganti password jika diperlukan", isExpanded: $showPasswordEditor) {
                    SecureField("Password database", text: $password)
                        .modifier(FormInput())
                        .onSubmit(retryDatabases)
                }
                .font(SmallFont.caption)
            }
        }
        .modifier(FormCard(highlighted: highlighted))
    }
}

@MainActor struct ConnectionManagerView: View {
    @ObservedObject var model: SyncModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: String?
    @State private var name = ""
    @State private var host = "127.0.0.1"
    @State private var port = "3306"
    @State private var user = "root"
    @State private var password = ""
    @State private var database = ""
    @State private var driver = NativeDatabaseDriver.mysql.rawValue
    @State private var useSSH = false
    @State private var sshHost = ""
    @State private var sshPort = "22"
    @State private var sshUser = ""
    @State private var sshKeyPath = ""
    @State private var error = ""
    @State private var testResult = ""
    @State private var testSucceeded = false
    @State private var testing = false
    @State private var showURLImporter = false

    private var selected: Profile? { model.profiles.first { $0.id == selectedID } }

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedID) {
                ForEach(model.profiles) { profile in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(profile.name)
                        Text("\(profile.host):\(profile.port) · \(profile.user)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(profile.id)
                }
            }
            .navigationTitle("Koneksi")
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    Button { resetDraft() } label: { Label("Tambah koneksi", systemImage: "plus") }
                        .buttonStyle(.borderedProminent)
                        .frame(maxWidth: .infinity)
                    Menu {
                        Button("Dari URL koneksi…") { showURLImporter = true }
                        Button("Dari TablePlus…") { model.chooseConnectionFolder() }
                    } label: {
                        Label("Impor koneksi", systemImage: "square.and.arrow.down")
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding(12)
                .background(Color(nsColor: .windowBackgroundColor))
            }
            .toolbar {
                Button(role: .destructive) { deleteSelected() } label: { Label("Hapus", systemImage: "trash") }
                    .disabled(selectedID == nil)
            }
        } detail: {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(selected == nil ? "Tambah koneksi database" : "Ubah koneksi database")
                            .font(.headline)
                        Text("Isi detail database, uji koneksi, lalu simpan. Password disimpan aman di Keychain.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("1 · Detail database") {
                    TextField("Nama koneksi", text: $name)
                    Picker("Driver", selection: $driver) {
                        Text("MySQL").tag(NativeDatabaseDriver.mysql.rawValue)
                        Text("MariaDB").tag(NativeDatabaseDriver.mariaDB.rawValue)
                    }
                    TextField("Host database", text: $host)
                    TextField("Port", text: $port)
                    TextField("User database", text: $user)
                    SecureField("Password database", text: $password)
                    Text("Password disimpan aman di Keychain saat koneksi disimpan. Kosongkan untuk mempertahankan password yang sudah tersimpan.")
                        .font(.caption).foregroundStyle(.secondary)
                    TextField("Database awal (opsional)", text: $database)
                }
                Section("2 · SSH tunnel (opsional)") {
                    Toggle("Gunakan SSH tunnel", isOn: $useSSH)
                    if useSSH {
                        TextField("Host SSH", text: $sshHost)
                        TextField("Port SSH", text: $sshPort)
                        TextField("User SSH", text: $sshUser)
                        TextField("Private key (opsional, gunakan SSH agent bila kosong)", text: $sshKeyPath)
                        Text("SSH menggunakan private key atau SSH agent macOS. Passphrase private key dikelola oleh ssh-agent atau Keychain.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("3 · Uji dan simpan") {
                    Text("Uji koneksi terlebih dahulu untuk memastikan host, akun, password, dan SSH sudah benar.")
                        .font(.caption).foregroundStyle(.secondary)
                    if !error.isEmpty {
                        Text(error).foregroundStyle(.red)
                    }
                    if !testResult.isEmpty {
                        Label(testResult, systemImage: testSucceeded ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(testSucceeded ? .green : .red)
                    }
                    HStack {
                    Button("Uji koneksi", action: testConnection)
                        .disabled(testing)
                    if testing { ProgressView().controlSize(.small) }
                    Button("Simpan koneksi", action: save)
                        .buttonStyle(.borderedProminent)
                    Button("Batal") { dismiss() }
                    }
                }
            }
            .formStyle(.grouped)
            .padding()
            .navigationTitle(selected == nil ? "Koneksi baru" : "Ubah koneksi")
        }
        .frame(minWidth: 760, minHeight: 520)
        .onAppear { resetDraft() }
        .onChange(of: selectedID) { loadSelected() }
        .sheet(isPresented: $showURLImporter) {
            ConnectionURLImportView(model: model)
        }
    }

    private func resetDraft() {
        selectedID = nil
        name = ""; host = "127.0.0.1"; port = "3306"; user = "root"; password = ""; database = ""
        driver = NativeDatabaseDriver.mysql.rawValue
        useSSH = false; sshHost = ""; sshPort = "22"; sshUser = ""; sshKeyPath = ""; error = ""; testResult = ""; testSucceeded = false
    }

    private func loadSelected() {
        guard let profile = selected else { return }
        name = profile.name; host = profile.host; port = "\(profile.port)"; user = profile.user
        database = profile.database ?? ""; driver = profile.driver ?? NativeDatabaseDriver.mysql.rawValue
        password = model.savedPassword(for: profile) ?? ""
        useSSH = profile.ssh != nil
        sshHost = profile.ssh?.host ?? ""; sshPort = "\(profile.ssh?.port ?? 22)"
        sshUser = profile.ssh?.user ?? ""; sshKeyPath = profile.ssh?.privateKeyPath ?? ""; error = ""; testResult = ""; testSucceeded = false
    }

    private func draftProfile(id: String? = nil) throws -> Profile {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !user.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let databasePort = Int(port), (1...65535).contains(databasePort) else {
            throw BridgeError.message("Isi nama, host, user, dan port database yang valid.")
        }
        let ssh: SSHConfiguration?
        if useSSH {
            guard !sshHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !sshUser.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let parsedSSHPort = Int(sshPort), (1...65535).contains(parsedSSHPort) else {
                throw BridgeError.message("Isi host, user, dan port SSH yang valid.")
            }
            ssh = SSHConfiguration(host: sshHost, port: parsedSSHPort, user: sshUser,
                                   privateKeyPath: sshKeyPath.isEmpty ? nil : sshKeyPath)
        } else { ssh = nil }
        return Profile(id: id ?? selectedID ?? UUID().uuidString, name: name, host: host,
                       port: databasePort, user: user, database: database.isEmpty ? nil : database,
                       isTablePlus: false, driver: driver, ssh: ssh)
    }

    private func save() {
        do {
            let profile = try draftProfile()
            try model.saveProfile(profile)
            if !password.isEmpty { try model.savePassword(password, for: profile) }
            error = ""
            testResult = ""; testSucceeded = false
        } catch let failure {
            error = failure.localizedDescription
        }
    }

    private func testConnection() {
        do {
            let profile = try draftProfile(id: selectedID ?? "test")
            let testPassword = password.isEmpty ? (model.savedPassword(for: profile) ?? "") : password
            testing = true
            error = ""; testResult = ""; testSucceeded = false
            Task {
                do {
                    let databases = try await model.listDatabases(for: profile, password: testPassword)
                    testResult = L10n.format("Berhasil terhubung. %d database tersedia.", databases.count)
                    testSucceeded = true
                } catch {
                    testResult = L10n.format("Koneksi gagal: %@", error.localizedDescription)
                    testSucceeded = false
                }
                testing = false
            }
        } catch let failure {
            error = failure.localizedDescription
        }
    }

    private func deleteSelected() {
        guard let selectedID else { return }
        do { try model.deleteProfile(id: selectedID); resetDraft() }
        catch let failure { error = failure.localizedDescription }
    }
}

struct ConnectionURLImportView: View {
    @ObservedObject var model: SyncModel
    @Environment(\.dismiss) private var dismiss
    @State private var connectionURL = ""
    @State private var message = ""
    @State private var succeeded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Impor dari URL koneksi").font(.title3.bold())
            Text("Gunakan URL standar dari penyedia database atau aplikasi lain. Contoh: mysql://user:password@db.example.com:3306/nama_database")
                .font(.subheadline).foregroundStyle(.secondary)
            TextField("mysql://…", text: $connectionURL, axis: .vertical)
                .modifier(FormInput())
                .lineLimit(3)
            if !message.isEmpty {
                Label(message, systemImage: succeeded ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .foregroundStyle(succeeded ? .green : .red)
            }
            HStack {
                Button("Impor", action: importConnection).buttonStyle(.borderedProminent)
                Button("Batal") { dismiss() }
            }
        }
        .padding(22)
        .frame(width: 580)
    }

    private func importConnection() {
        do {
            guard let components = URLComponents(string: connectionURL),
                  let scheme = components.scheme?.lowercased(),
                  let host = components.host, !host.isEmpty,
                  let user = components.user, !user.isEmpty else {
                throw BridgeError.message("URL koneksi tidak valid. Pastikan berisi driver, user, host, dan port.")
            }
            let driver: NativeDatabaseDriver
            switch scheme {
            case "mysql": driver = .mysql
            case "mariadb": driver = .mariaDB
            default: throw BridgeError.message("Driver pada URL belum didukung. Gunakan mysql:// atau mariadb://.")
            }
            let database = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let profile = Profile(id: UUID().uuidString, name: host, host: host,
                                  port: components.port ?? 3306, user: user,
                                  database: database.isEmpty ? nil : database,
                                  isTablePlus: false, driver: driver.rawValue, ssh: nil)
            try model.saveProfile(profile)
            if let password = components.password, !password.isEmpty {
                try model.savePassword(password, for: profile)
            }
            succeeded = true
            message = "Koneksi diimpor. Anda dapat memilihnya dari daftar koneksi."
        } catch let failure {
            succeeded = false
            message = failure.localizedDescription
        }
    }
}

private struct DataChangeKind: Identifiable {
    let id: String
    let title: String
    let count: Int
}

private struct BlockerGroup: Identifiable {
    let table: String
    let issues: [String]
    var id: String { table }
}

private struct BlockerGroupDisclosure: View {
    let group: BlockerGroup
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(group.issues.enumerated()), id: \.offset) { _, issue in
                    Label {
                        Text(issue).fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "circle.fill").font(.system(size: 6))
                            .foregroundStyle(.red)
                    }
                    .font(SmallFont.subheadline)
                }
            }
            .padding(.top, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: group.table == L10n.text("Masalah umum") ? "exclamationmark.triangle" : "tablecells")
                    .foregroundStyle(.red)
                Text(group.table).font(SmallFont.subheadline.weight(.semibold))
                Spacer()
                Text(L10n.format("%d masalah", group.issues.count))
                    .font(SmallFont.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.12))
        }
    }
}

private struct ApplySummary {
    let mode: String
    let destination: String
    let structureStatements: Int?
    let affectedTables: Int?
    let inserted: Int
    let updated: Int
    let deleted: Int
}

@MainActor private struct DataTablePreview: View {
    let item: [String: Any]
    let input: [String: Any]?
    @ObservedObject var model: SyncModel
    @State private var expanded = false
    @State private var kind: String
    @State private var page = 0
    @State private var detail: [String: Any]?
    @State private var loading = false
    @State private var error = ""

    init(item: [String: Any], input: [String: Any]?, model: SyncModel) {
        self.item = item
        self.input = input
        self.model = model
        let first = ["insert", "update", "delete", "extra"].first { key in
            (item[key == "extra" ? "extraRows" : key] as? Int ?? 0) > 0 &&
                (key != "extra" || (item["delete"] as? Int ?? 0) == 0)
        } ?? "insert"
        _kind = State(initialValue: first)
    }

    private var table: String { item["table"] as? String ?? "" }
    private var inserted: Int { item["insert"] as? Int ?? 0 }
    private var updated: Int { item["update"] as? Int ?? 0 }
    private var deleted: Int { item["delete"] as? Int ?? 0 }
    private var extra: Int { item["extraRows"] as? Int ?? 0 }
    private var kinds: [DataChangeKind] {
        [DataChangeKind(id: "insert", title: L10n.text("Tambah"), count: inserted),
         DataChangeKind(id: "update", title: L10n.text("Ubah"), count: updated),
         DataChangeKind(id: "delete", title: L10n.text("Hapus"), count: deleted),
         DataChangeKind(id: "extra", title: L10n.text("Tetap di tujuan"), count: deleted == 0 ? extra : 0)]
            .filter { $0.count > 0 }
    }
    private var requestKey: String { expanded ? "\(table):\(kind):\(page)" : "" }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                if kinds.count > 1 {
                    Picker("Jenis perubahan", selection: $kind) {
                        ForEach(kinds) { option in
                            Text(verbatim: "\(option.title) (\(option.count))").tag(option.id)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 560)
                    .onChange(of: kind) { page = 0 }
                }
                if loading {
                    ProgressView("Memuat rincian baris…").controlSize(.small)
                } else if !error.isEmpty {
                    Text(error).foregroundStyle(.red)
                    Button("Coba lagi") { Task { await loadDetails() } }
                } else if let detail {
                    let rows = detail["rows"] as? [[String: Any]] ?? []
                    let total = detail["total"] as? Int ?? 0
                    let columns = detail["columns"] as? [String] ?? []
                    let keyColumns = detail["keyColumns"] as? [String] ?? []
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        detailRow(row, number: page * 20 + index + 1,
                                  columns: columns, keyColumns: keyColumns)
                    }
                    HStack {
                        Text(L10n.format("%d–%d dari %d baris", page * 20 + 1, min((page + 1) * 20, total), total))
                            .font(SmallFont.subheadline).foregroundStyle(.secondary)
                        Spacer()
                        Button("Sebelumnya") { page -= 1 }.disabled(page == 0)
                        Button("Berikutnya") { page += 1 }.disabled((page + 1) * 20 >= total)
                    }
                }
            }
            .padding(.top, 10)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "tablecells").foregroundStyle(.secondary)
                Text(table).font(.headline)
                Spacer()
                if inserted > 0 { Text(L10n.format("+%d tambah", inserted)).foregroundStyle(.green) }
                if updated > 0 { Text(L10n.format("~%d ubah", updated)).foregroundStyle(.blue) }
                if deleted > 0 { Text(L10n.format("−%d hapus", deleted)).foregroundStyle(.orange) }
                if extra > 0 && deleted == 0 {
                    Text(L10n.format("%d tetap", extra)).foregroundStyle(.secondary)
                }
            }
            .font(SmallFont.subheadline.weight(.medium))
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .task(id: requestKey) { if expanded { await loadDetails() } }
    }

    private func loadDetails() async {
        guard var body = input else { error = L10n.text("Pratinjau tidak tersedia. Bandingkan ulang."); return }
        body["table"] = table
        body["kind"] = kind
        body["offset"] = page * 20
        body["limit"] = 20
        body["tableFingerprint"] = item["tableFingerprint"] as? String ?? ""
        loading = true
        error = ""
        detail = nil
        do {
            let result = try await model.dataDetails(body)
            guard !Task.isCancelled else { return }
            detail = result
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
        if !Task.isCancelled { loading = false }
    }

    private func valueText(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "NULL" }
        if let string = value as? String { return string.isEmpty ? L10n.text("(kosong)") : string }
        if let number = value as? NSNumber { return number.stringValue }
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]),
           let string = String(data: data, encoding: .utf8) { return string }
        return String(describing: value)
    }

    private func detailRow(_ row: [String: Any], number: Int, columns: [String],
                           keyColumns: [String]) -> some View {
        let before = row["before"] as? [String: Any]
        let after = row["after"] as? [String: Any]
        let values = after ?? before ?? [:]
        let identityColumns = keyColumns.isEmpty ? Array(columns.prefix(2)) : keyColumns
        let identity = identityColumns.map { "\($0): \(valueText(values[$0]))" }.joined(separator: " · ")
        let visibleColumns = kind == "update" ? (row["changes"] as? [String] ?? []) : columns
        return VStack(alignment: .leading, spacing: 7) {
            Text(L10n.format("Baris %d · %@", number, identity))
                .font(SmallFont.subheadline.weight(.semibold))
                .textSelection(.enabled)
            ForEach(visibleColumns, id: \.self) { column in
                HStack(alignment: .top, spacing: 10) {
                    Text(column).font(SmallFont.subheadline.weight(.medium))
                        .frame(width: 160, alignment: .leading)
                    if kind == "update" {
                        Text(valueText(before?[column])).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        Text(valueText(after?[column])).frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text(valueText(values[column])).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .font(SmallFont.subheadline)
                .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }
}

@MainActor struct ContentView: View {
    @StateObject private var model = SyncModel()
    @State private var mode = "structure"
    @State private var sourceID = ""
    @State private var targetID = ""
    @State private var sourcePassword = ""
    @State private var targetPassword = ""
    @State private var sourceDatabase = ""
    @State private var targetDatabase = ""
    @State private var targetHint = ""
    @State private var targetHintDatabase = ""
    @State private var targetFromTablePlus = false
    @State private var sourceDatabases: [String] = []
    @State private var targetDatabases: [String] = []
    @State private var sourceDatabaseLoading = false
    @State private var targetDatabaseLoading = false
    @State private var sourceDatabaseError = ""
    @State private var targetDatabaseError = ""
    @State private var sourceLoadID = UUID()
    @State private var targetLoadID = UUID()
    @State private var selectedTables = ""
    @State private var destructiveSchema = false
    @State private var removeExtraForeignKeys = false
    @State private var autoHandleForeignKeys = false
    @State private var removeExtraTables = false
    @State private var removeExtraRows = false
    @State private var confirmation = ""
    @State private var acknowledgeDestructive = false
    @State private var previewInput: [String: Any]?
    @State private var showAdvanced = false
    @State private var showSetup = true
    @State private var showUnchangedData = false
    @State private var lastApply: ApplySummary?
    @State private var showConnectionManager = false

    private var source: Profile? { model.profiles.first { $0.id == sourceID } }
    private var target: Profile? { model.profiles.first { $0.id == targetID } }
    private var sourceHasSavedPassword: Bool { source.map { model.savedPassword(for: $0) != nil } ?? false }
    private var targetHasSavedPassword: Bool { target.map { model.savedPassword(for: $0) != nil } ?? false }
    private var comparisonOptionsSummary: String {
        var parts = [L10n.text(mode == "structure" ? "Struktur" : "Data")]
        let tables = selectedTables.trimmingCharacters(in: .whitespacesAndNewlines)
        parts.append(tables.isEmpty ? L10n.text("Semua tabel") : L10n.format("Tabel: %@", tables))
        if mode == "structure" {
            if destructiveSchema { parts.append(L10n.text("Hapus kolom/indeks tambahan")) }
            if removeExtraForeignKeys { parts.append(L10n.text("Hapus foreign key tambahan")) }
            if autoHandleForeignKeys { parts.append(L10n.text("Tangani foreign key otomatis")) }
            if removeExtraTables { parts.append(L10n.text("Hapus tabel tambahan")) }
        } else if removeExtraRows {
            parts.append(L10n.text("Hapus baris tambahan"))
        }
        return parts.joined(separator: " · ")
    }

    private func selectedConnection(_ label: String, profile: Profile?, database: String,
                                    highlighted: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(LocalizedStringKey(label), systemImage: highlighted ? "checkmark.circle.fill" : "circle.fill")
                .font(SmallFont.caption.weight(.bold))
                .foregroundStyle(highlighted ? Color.accentColor : Color.secondary)
            Text(profile?.name ?? L10n.text("Koneksi belum dipilih"))
                .font(.body.weight(.semibold))
                .lineLimit(1)
            Text(database)
                .font(SmallFont.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(highlighted ? Color.accentColor.opacity(0.15) : Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(highlighted ? Color.accentColor : Color.secondary.opacity(0.25),
                              lineWidth: highlighted ? 1.5 : 1)
        }
    }

    private func sourcePane() -> some View {
        EndpointPane(title: "1 · Pilih Sumber", highlighted: false,
                     profiles: model.profiles, profileID: $sourceID,
                     password: $sourcePassword, database: $sourceDatabase,
                     retryDatabases: { loadDatabases(sourceSide: true) },
                     databases: sourceDatabases, loading: sourceDatabaseLoading,
                     error: sourceDatabaseError,
                     hasSavedPassword: sourceHasSavedPassword,
                     removeSavedPassword: { removeSavedPassword(sourceSide: true) })
    }

    @ViewBuilder private func destinationPane() -> some View {
        if targetFromTablePlus {
            VStack(alignment: .leading, spacing: 9) {
                Text("2 · Tujuan di TablePlus").font(SmallFont.subheadline.weight(.semibold))
                Label(target?.name ?? L10n.text("Koneksi aktif"), systemImage: "checkmark.circle.fill")
                    .font(.headline).foregroundStyle(.green)
                if targetHasSavedPassword {
                    HStack(spacing: 7) {
                        Label("Password tersimpan aman di Keychain", systemImage: "key.fill")
                            .font(SmallFont.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Hapus password") { removeSavedPassword(sourceSide: false) }
                            .font(SmallFont.caption)
                    }
                }
                if targetDatabase.isEmpty {
                    Picker("Database tujuan", selection: $targetDatabase) {
                        Text(targetDatabaseLoading ? LocalizedStringKey("Memuat database…") : LocalizedStringKey("Pilih database")).tag("")
                        ForEach(targetDatabases, id: \.self) { Text($0).tag($0) }
                    }
                    .disabled(targetDatabaseLoading || !targetDatabaseError.isEmpty)
                    .modifier(FormPicker())
                } else {
                    Text(L10n.format("Database: %@", targetDatabase))
                }
                if targetDatabaseLoading {
                    ProgressView("Mengambil daftar database…").controlSize(.small)
                } else if !targetDatabaseError.isEmpty {
                    Text(targetDatabaseError).font(SmallFont.caption).foregroundStyle(.red)
                    Button("Coba lagi") { loadDatabases(sourceSide: false) }
                }
                Text("Perubahan hanya akan diterapkan ke tujuan ini.")
                    .font(SmallFont.caption).foregroundStyle(.secondary)
                DisclosureGroup("Password manual jika diperlukan") {
                    SecureField("Password tujuan", text: $targetPassword)
                        .modifier(FormInput())
                }
                Button("Ganti tujuan…") {
                    targetHint = ""
                    targetHintDatabase = ""
                    targetFromTablePlus = false
                    invalidate()
                }
                .font(SmallFont.caption)
            }
            .modifier(FormCard(highlighted: true))
        } else {
            VStack(alignment: .leading, spacing: 5) {
                EndpointPane(title: "2 · Tujuan yang Diubah", highlighted: true,
                             profiles: model.profiles, profileID: $targetID,
                             password: $targetPassword, database: $targetDatabase,
                             retryDatabases: { loadDatabases(sourceSide: false) },
                             databases: targetDatabases, loading: targetDatabaseLoading,
                             error: targetDatabaseError,
                             hasSavedPassword: targetHasSavedPassword,
                             removeSavedPassword: { removeSavedPassword(sourceSide: false) })
                Text("Pilih koneksi dan database yang akan menjadi tujuan sinkronisasi.")
                    .font(SmallFont.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func connectionSetupPanels(compact: Bool) -> some View {
        if compact {
            VStack(alignment: .leading, spacing: 12) {
                sourcePane()
                Label("Tujuan sinkronisasi", systemImage: "arrow.down")
                    .font(SmallFont.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                destinationPane()
            }
        } else {
            HStack(alignment: .top, spacing: 16) {
                sourcePane().frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "arrow.right").font(.title2).foregroundStyle(.secondary)
                    .padding(.top, 72)
                destinationPane().frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func endpoint(_ profile: Profile?, password: String, database: String) -> [String: Any]? {
        guard let profile, !database.isEmpty else { return nil }
        var endpoint: [String: Any] = ["id": profile.id, "name": profile.name, "host": profile.host,
                "port": profile.port, "user": profile.user, "password": password, "database": database,
                "driver": profile.driver ?? NativeDatabaseDriver.mysql.rawValue]
        if let ssh = profile.ssh {
            endpoint["ssh"] = ["host": ssh.host, "port": ssh.port, "user": ssh.user,
                               "privateKeyPath": ssh.privateKeyPath as Any]
        }
        return endpoint
    }

    private func requestInput() -> [String: Any]? {
        guard let source = endpoint(source, password: sourcePassword, database: sourceDatabase),
              let destination = endpoint(target, password: targetPassword, database: targetDatabase) else { return nil }
        var options: [String: Any] = ["destructiveSchema": destructiveSchema,
                                      "removeExtraForeignKeys": removeExtraForeignKeys,
                                      "autoHandleForeignKeys": autoHandleForeignKeys,
                                      "removeExtraTables": removeExtraTables,
                                      "removeExtraRows": removeExtraRows]
        let tables = selectedTables.split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if !tables.isEmpty { options["tables"] = tables }
        return ["mode": mode, "source": source, "destination": destination, "options": options]
    }

    private func invalidate(keepingApplySummary: Bool = false) {
        model.preview = nil
        previewInput = nil
        confirmation = ""
        acknowledgeDestructive = false
        showSetup = true
        showUnchangedData = false
        if !keepingApplySummary { lastApply = nil }
    }

    private func handleURL(_ url: URL) {
        guard url.scheme == "tableplus-dbsync", url.host == "open" else { return }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let requestedMode = components?.queryItems?.first(where: { $0.name == "mode" })?.value
        if requestedMode == "structure" || requestedMode == "data" { mode = requestedMode! }
        targetHint = components?.queryItems?.first(where: { $0.name == "target" })?.value ?? ""
        targetHintDatabase = components?.queryItems?.first(where: { $0.name == "database" })?.value ?? ""
        resolveTargetHint()
    }

    private func resolveTargetHint() {
        guard !targetHint.isEmpty else { targetFromTablePlus = false; return }
        guard let profile = model.profiles.first(where: { $0.id == targetHint || $0.name == targetHint }) else {
            targetFromTablePlus = false
            return
        }
        let database = targetHintDatabase.isEmpty ? (profile.database ?? "") : targetHintDatabase
        targetID = profile.id
        targetDatabase = database
        targetFromTablePlus = true
    }

    private func loadDatabases(sourceSide: Bool) {
        let profile = sourceSide ? source : target
        guard let profile else { return }
        let loadID = UUID()
        let selectedDatabase = sourceSide ? sourceDatabase : targetDatabase
        if sourceSide {
            sourceLoadID = loadID
            sourceDatabaseLoading = true
            sourceDatabaseError = ""
        } else {
            targetLoadID = loadID
            targetDatabaseLoading = true
            targetDatabaseError = ""
        }
        var password = sourceSide ? sourcePassword : targetPassword
        if password.isEmpty, let savedPassword = model.savedPassword(for: profile) {
            password = savedPassword
            if sourceSide { sourcePassword = savedPassword } else { targetPassword = savedPassword }
        }
        Task {
            do {
                let names = try await model.listDatabases(for: profile, password: password)
                guard (sourceSide ? sourceLoadID : targetLoadID) == loadID,
                      (sourceSide ? sourceID : targetID) == profile.id else { return }
                let preferred = names.contains(selectedDatabase) ? selectedDatabase :
                    (names.contains(profile.database ?? "") ? profile.database! : (names.count == 1 ? names[0] : ""))
                if sourceSide {
                    sourceDatabases = names
                    sourceDatabase = preferred
                    sourceDatabaseLoading = false
                } else {
                    targetDatabases = names
                    targetDatabase = preferred
                    targetDatabaseLoading = false
                }
                if !password.isEmpty { try? model.savePassword(password, for: profile) }
                invalidate()
            } catch {
                guard (sourceSide ? sourceLoadID : targetLoadID) == loadID,
                      (sourceSide ? sourceID : targetID) == profile.id else { return }
                if sourceSide {
                    sourceDatabaseLoading = false
                    sourceDatabaseError = error.localizedDescription
                } else {
                    targetDatabaseLoading = false
                    targetDatabaseError = error.localizedDescription
                }
            }
        }
    }

    private func removeSavedPassword(sourceSide: Bool) {
        let profile = sourceSide ? source : target
        guard let profile else { return }
        try? model.removeSavedPassword(for: profile)
        if sourceSide { sourcePassword = "" } else { targetPassword = "" }
    }

    private func compare() {
        guard let input = requestInput() else {
            model.status = L10n.text("Pilih koneksi dan database sumber serta target.")
            return
        }
        lastApply = nil
        Task {
            await model.run(L10n.text(mode == "structure" ? "Membandingkan struktur…" : "Membandingkan data…")) {
                let preview = try await (mode == "structure"
                                         ? model.previewStructure(input)
                                         : model.previewData(input))
                model.preview = preview
                previewInput = input
                confirmation = ""
                acknowledgeDestructive = false
                showSetup = false
                let blockers = preview["blockers"] as? [String] ?? []
                model.status = blockers.isEmpty ? L10n.text("Pratinjau siap. Periksa perubahan sebelum menerapkan.") : L10n.format("Ada %d penghalang sinkronisasi.", blockers.count)
            }
        }
    }

    private func apply() {
        guard var input = previewInput, let preview = model.preview,
              let fingerprint = preview["fingerprint"] as? String else { return }
        input["fingerprint"] = fingerprint
        input["confirmDatabase"] = confirmation
        Task {
            await model.run(L10n.format("Menerapkan perubahan ke %@…", targetDatabase)) {
                do {
                    if mode == "structure" {
                        let count = try await model.applyStructure(input, fingerprint: fingerprint, confirmation: confirmation)
                        invalidate(keepingApplySummary: true)
                        lastApply = ApplySummary(mode: mode, destination: targetDatabase,
                                                 structureStatements: count, affectedTables: nil,
                                                 inserted: 0, updated: 0, deleted: 0)
                        model.status = L10n.format("Sinkronisasi struktur selesai: %d perintah diterapkan.", count)
                        return
                    }
                    let result = try await model.applyData(input, fingerprint: fingerprint, confirmation: confirmation)
                    invalidate(keepingApplySummary: true)
                    lastApply = ApplySummary(mode: mode, destination: targetDatabase,
                                             structureStatements: nil, affectedTables: result.tables,
                                             inserted: result.inserted, updated: result.updated, deleted: result.deleted)
                    model.status = L10n.format("Sinkronisasi data selesai: +%d, ~%d, −%d baris.", result.inserted, result.updated, result.deleted)
                } catch {
                    invalidate()
                    throw BridgeError.message(L10n.format("Penerapan terhenti: %@ Jika ada perintah struktur yang sudah berjalan, perubahan tersebut tidak dibatalkan. Bandingkan ulang sebelum mencoba lagi.", error.localizedDescription))
                }
            }
        }
    }

    private var compareButton: some View {
        Button(L10n.text(mode == "structure" ? "Bandingkan Struktur" : "Bandingkan Data")) { compare() }
            .buttonStyle(.borderedProminent)
            .disabled(model.busy || sourceDatabaseLoading || targetDatabaseLoading ||
                      !sourceDatabaseError.isEmpty || !targetDatabaseError.isEmpty ||
                      sourceDatabase.isEmpty || targetDatabase.isEmpty)
    }

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 1_080
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
            if compact {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Pilih sumber dan tujuan")
                            .font(.title3.bold())
                        Text("Bandingkan sebelum menerapkan perubahan ke tujuan.")
                            .foregroundStyle(.secondary)
                    }
                    Picker("Mode", selection: $mode) {
                        Text("Structure").tag("structure")
                        Text("Data").tag("data")
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 300)
                }
            } else {
                HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Pilih sumber dan tujuan")
                        .font(.title3.bold())
                    Text("Bandingkan sebelum menerapkan perubahan ke tujuan.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Mode", selection: $mode) {
                    Text("Structure").tag("structure")
                    Text("Data").tag("data")
                }.pickerStyle(.segmented).frame(width: 230)
                }
            }
            if model.preview != nil && !showSetup {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Pilihan perbandingan").font(SmallFont.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        if compact {
                            VStack(alignment: .leading, spacing: 7) {
                                selectedConnection("SUMBER", profile: source, database: sourceDatabase,
                                                   highlighted: false)
                                Image(systemName: "arrow.down").foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity)
                                selectedConnection("TUJUAN AKTIF", profile: target, database: targetDatabase,
                                                   highlighted: true)
                            }
                        } else {
                            HStack(spacing: 8) {
                            selectedConnection("SUMBER", profile: source, database: sourceDatabase,
                                               highlighted: false)
                            Image(systemName: "arrow.right").foregroundStyle(.secondary)
                            selectedConnection("TUJUAN AKTIF", profile: target, database: targetDatabase,
                                               highlighted: true)
                            }
                        }
                        Text(comparisonOptionsSummary)
                            .font(SmallFont.caption).foregroundStyle(.secondary).lineLimit(compact ? 2 : 1)
                    }
                    Button("Ubah koneksi & opsi") { showSetup = true }
                        .fixedSize()
                }
                .padding(12)
                .frame(maxWidth: 1_100, alignment: .leading)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
            } else {
                HStack {
                    Label("Koneksi", systemImage: "externaldrive.connected.to.line.below").font(.headline)
                    Spacer()
                    Button("Kelola koneksi") { showConnectionManager = true }
                    Button("Impor koneksi…") { showConnectionManager = true }
                    if model.preview != nil {
                        Button("Tutup pengaturan") { showSetup = false }
                    }
                    Button("Muat Ulang") { Task { await model.loadProfiles() } }
                        .disabled(model.busy)
                }
                if !model.connectionPath.isEmpty {
                    Label(model.connectionPath, systemImage: "folder").font(SmallFont.caption)
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                connectionSetupPanels(compact: compact)
                DisclosureGroup("Pilihan lanjutan", isExpanded: $showAdvanced) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Tabel yang dibandingkan (opsional)")
                            .font(SmallFont.subheadline.weight(.medium))
                        TextField("Tabel tertentu, pisahkan dengan koma (kosong = semua)", text: $selectedTables)
                            .modifier(FormInput())
                        if mode == "structure" {
                            Toggle("Izinkan hapus kolom dan indeks tambahan", isOn: $destructiveSchema)
                            Toggle("Izinkan hapus foreign key tambahan di tujuan", isOn: $removeExtraForeignKeys)
                            Toggle("Tangani perubahan foreign key secara otomatis", isOn: $autoHandleForeignKeys)
                            if autoHandleForeignKeys {
                                Label("Aplikasi akan melepas foreign key pada tabel terkait, menjalankan perubahan struktur, lalu membuatnya kembali sesuai sumber.", systemImage: "arrow.triangle.2.circlepath")
                                    .font(SmallFont.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Toggle("Hapus tabel tambahan di tujuan", isOn: $removeExtraTables)
                        } else {
                            Toggle("Hapus baris tambahan di tujuan", isOn: $removeExtraRows)
                        }
                    }
                }
                .modifier(FormCard())
                if compact {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            compareButton
                            if model.busy { ProgressView().controlSize(.small) }
                        }
                        Text(model.status).font(SmallFont.subheadline).foregroundStyle(.secondary)
                    }
                } else {
                    HStack {
                        compareButton
                        if model.busy { ProgressView().controlSize(.small) }
                        Spacer()
                        Text(model.status).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
            Divider()
            if let preview = model.preview {
                previewView(preview).frame(maxHeight: .infinity)
            } else if let lastApply {
                applyCompletionView(lastApply)
            } else {
                ContentUnavailableView("Belum ada pratinjau", systemImage: "arrow.left.arrow.right",
                                       description: Text("Pilih sumber, periksa tujuan, lalu klik Bandingkan."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 18)
                .padding(.top, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)
        }
        .frame(minWidth: 640, minHeight: 520)
        .onChange(of: mode) { invalidate() }
        .onChange(of: sourceID) {
            sourceLoadID = UUID()
            sourceDatabaseLoading = false
            sourceDatabaseError = ""
            sourcePassword = ""
            sourceDatabase = ""
            sourceDatabases = []
            invalidate()
            if !sourceID.isEmpty { loadDatabases(sourceSide: true) }
        }
        .onChange(of: targetID) {
            targetLoadID = UUID()
            targetDatabaseLoading = false
            targetDatabaseError = ""
            targetPassword = ""
            if !targetFromTablePlus {
                targetDatabase = ""
                targetDatabases = []
            }
            invalidate()
            if !targetID.isEmpty { loadDatabases(sourceSide: false) }
        }
        .onChange(of: model.profiles) { resolveTargetHint() }
        .onChange(of: sourceDatabase) { invalidate() }
        .onChange(of: targetDatabase) { invalidate() }
        .onChange(of: sourcePassword) { invalidate() }
        .onChange(of: targetPassword) { invalidate() }
        .onChange(of: selectedTables) { invalidate() }
        .onChange(of: destructiveSchema) { invalidate() }
        .onChange(of: removeExtraForeignKeys) { invalidate() }
        .onChange(of: autoHandleForeignKeys) { invalidate() }
        .onChange(of: removeExtraTables) { invalidate() }
        .onChange(of: removeExtraRows) { invalidate() }
        .onOpenURL(perform: handleURL)
        .sheet(isPresented: $showConnectionManager) {
            ConnectionManagerView(model: model)
        }
        .background(WindowChromeConfigurator())
    }

    private func applyCompletionView(_ summary: ApplySummary) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Label("Sinkronisasi berhasil", systemImage: "checkmark.circle.fill")
                    .font(.title2.bold()).foregroundStyle(.green)
                Spacer()
                Text(summary.mode == "structure" ? "Struktur" : "Data")
                    .font(SmallFont.caption.weight(.semibold))
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(.green.opacity(0.12), in: Capsule())
            }
            Text(L10n.format("Database tujuan %@ sudah diperbarui.", summary.destination))
                .font(.headline)
            if let statements = summary.structureStatements {
                HStack(spacing: 10) {
                    Image(systemName: "checklist.checked").font(.title2).foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.format("%d perintah struktur diterapkan", statements))
                            .font(.title3.weight(.semibold))
                        Text("Perubahan struktur telah diterapkan ke database tujuan.")
                            .font(SmallFont.subheadline).foregroundStyle(.secondary)
                    }
                }
                .padding(14)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
            } else {
                HStack(spacing: 10) {
                    completionMetric("+\(summary.inserted)", label: "Ditambahkan", color: .green)
                    completionMetric("~\(summary.updated)", label: "Diubah", color: .blue)
                    completionMetric("−\(summary.deleted)", label: "Dihapus", color: .orange)
                    if let tables = summary.affectedTables {
                        Divider().frame(height: 42)
                        completionMetric("\(tables)", label: "Tabel diproses", color: .secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
            }
            Text("Tidak ada perubahan tambahan yang sedang menunggu. Bandingkan lagi bila ingin memastikan sumber dan tujuan sudah sesuai.")
                .font(SmallFont.subheadline).foregroundStyle(.secondary)
            HStack {
                Button(L10n.text(summary.mode == "structure" ? "Bandingkan struktur lagi" : "Bandingkan data lagi")) {
                    compare()
                }
                .buttonStyle(.borderedProminent)
                Spacer()
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.green.opacity(0.055), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14).strokeBorder(.green.opacity(0.38))
        }
    }

    private func completionMetric(_ value: String, label: LocalizedStringKey, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(.title3.bold()).foregroundStyle(color)
            Text(label).font(SmallFont.caption).foregroundStyle(.secondary)
        }
        .frame(minWidth: 94, alignment: .leading)
    }

    private func previewView(_ preview: [String: Any]) -> some View {
        let blockers = preview["blockers"] as? [String] ?? []
        let warnings = preview["warnings"] as? [String] ?? []
        let schema = preview["schema"] as? [[String: Any]] ?? []
        let data = preview["data"] as? [[String: Any]] ?? []
        let tableNames = orderedTableNames(in: schema)
        let blockerGroups = groupedBlockers(blockers)
        let destructiveCount = mode == "structure"
            ? schema.filter { isDestructive($0["statement"] as? String ?? "") }.count
            : data.reduce(0) { $0 + ($1["delete"] as? Int ?? 0) }
        let dataChangeCount = data.reduce(0) { total, item in
            total + (item["insert"] as? Int ?? 0) + (item["update"] as? Int ?? 0) + (item["delete"] as? Int ?? 0)
        }
        let changeCount = mode == "structure" ? schema.count : dataChangeCount
        let hasOptionBlocker = blockers.contains {
            $0.contains(L10n.text("Aktifkan opsi")) || $0.contains(L10n.text("Aktifkan opsi hapus"))
        }
        let hasForeignKeyBlocker = blockers.contains { $0.localizedCaseInsensitiveContains("foreign key") }
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(LocalizedStringKey(mode == "structure" ? "Hasil perbandingan struktur" : "Hasil perbandingan data"))
                    .font(.title3.bold())
                Spacer()
                Label(LocalizedStringKey(blockers.isEmpty ? "Siap ditinjau" : "Penerapan tertahan"),
                      systemImage: blockers.isEmpty ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .font(SmallFont.subheadline.weight(.semibold))
                    .foregroundStyle(blockers.isEmpty ? Color.green : Color.red)
            }
            Text(L10n.format("%@ (sumber)  →  %@ (tujuan)", sourceDatabase, targetDatabase))
                .font(SmallFont.subheadline).foregroundStyle(.secondary)
            HStack(spacing: 18) {
                Label(L10n.format(mode == "structure" ? "%d perintah perubahan" : "%d baris berubah", changeCount),
                      systemImage: "list.bullet.rectangle")
                Label(L10n.format("%d penghalang", blockers.count), systemImage: "exclamationmark.octagon")
                    .foregroundStyle(blockers.isEmpty ? Color.secondary : Color.red)
                if destructiveCount > 0 {
                    Label(L10n.format("%d penghapusan", destructiveCount), systemImage: "trash")
                        .foregroundStyle(.orange)
                }
            }
            .font(SmallFont.caption.weight(.medium))
            Text("Perbandingan ini hanya pratinjau. Database tujuan belum diubah.")
                .font(SmallFont.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 14) {
                    if !blockers.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(alignment: .firstTextBaseline) {
                                Label("Perlu diselesaikan sebelum menerapkan", systemImage: "xmark.octagon.fill")
                                    .font(.headline).foregroundStyle(.red)
                                Spacer()
                                Text(L10n.format("%d penghalang", blockers.count))
                                    .font(SmallFont.caption.weight(.semibold)).foregroundStyle(.red)
                            }
                            Text(L10n.format("%d penghalang dalam %d kelompok. Buka tabel untuk melihat rincian yang perlu ditangani.", blockers.count, blockerGroups.count))
                                .font(SmallFont.caption).foregroundStyle(.secondary)
                            if hasForeignKeyBlocker && !autoHandleForeignKeys {
                                HStack(alignment: .center, spacing: 10) {
                                    Image(systemName: "wand.and.stars").foregroundStyle(Color.accentColor)
                                    Text("Aplikasi dapat menyiapkan perubahan foreign key yang aman. Aktifkan, lalu bandingkan ulang sebelum menerapkan.")
                                        .font(SmallFont.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    Button("Siapkan penanganan otomatis") {
                                        autoHandleForeignKeys = true
                                        showSetup = true
                                        showAdvanced = true
                                    }
                                    .buttonStyle(.bordered)
                                }
                                .padding(10)
                                .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                            }
                            DisclosureGroup("Mengapa ada yang perlu manual?") {
                                Text("Aplikasi menahan perubahan indeks atau kolom pada tabel yang memiliki foreign key. Menghapus atau mengubahnya tanpa urutan yang tepat dapat membuat relasi database gagal. Periksa tiap tabel, lakukan perubahan yang diperlukan pada tujuan, lalu bandingkan lagi.")
                                    .font(SmallFont.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .font(SmallFont.subheadline.weight(.medium))
                            .padding(.vertical, 2)
                            ForEach(blockerGroups) { group in
                                BlockerGroupDisclosure(group: group)
                            }
                            Text(LocalizedStringKey(hasOptionBlocker
                                 ? "Tangani perbedaan yang perlu diperbaiki manual, atau aktifkan opsi penghapusan yang disebut di atas. Setelah itu, bandingkan lagi."
                                 : "Tangani perbedaan ini secara manual pada database tujuan, lalu bandingkan lagi."))
                                .font(SmallFont.caption).foregroundStyle(.secondary)
                            if hasOptionBlocker && (!showAdvanced || !showSetup) {
                                Button("Buka Pilihan lanjutan") {
                                    showSetup = true
                                    showAdvanced = true
                                }
                                    .font(SmallFont.caption)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(Color.red.opacity(0.38))
                        }
                    }
                    if !warnings.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Perhatian", systemImage: "exclamationmark.triangle.fill")
                                .font(.headline).foregroundStyle(.orange)
                            ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in
                                Text("• \(warning)").font(SmallFont.subheadline)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    }
                    if mode == "structure" {
                        if schema.isEmpty {
                            Text(LocalizedStringKey(blockers.isEmpty ? "Struktur sumber dan tujuan sudah sesuai. Tidak ada perubahan untuk diterapkan." :
                                    "Belum ada perintah perubahan yang dapat disiapkan. Lihat penghalang di atas."))
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Perubahan yang direncanakan").font(.headline)
                            ForEach(tableNames, id: \.self) { table in
                                let statements = schema.compactMap { item -> String? in
                                    guard item["table"] as? String == table else { return nil }
                                    return item["statement"] as? String
                                }
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Image(systemName: "tablecells").foregroundStyle(.secondary)
                                        Text(table).font(.headline)
                                        Spacer()
                                        Text(L10n.format("%d perubahan", statements.count))
                                            .font(SmallFont.caption).foregroundStyle(.secondary)
                                    }
                                    ForEach(Array(statements.enumerated()), id: \.offset) { _, statement in
                                        DisclosureGroup {
                                            ScrollView(.horizontal) {
                                                Text(statement)
                                                    .font(SmallFont.monospacedCaption)
                                                    .textSelection(.enabled)
                                                    .fixedSize(horizontal: true, vertical: false)
                                                    .padding(10)
                                            }
                                        } label: {
                                            Label(LocalizedStringKey(statementTitle(statement)),
                                                  systemImage: isDestructive(statement) ? "trash" : "plus.circle")
                                                .foregroundStyle(isDestructive(statement) ? Color.orange : Color.primary)
                                        }
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                            }
                        }
                    } else {
                        let changed = data.filter { item in
                            (item["insert"] as? Int ?? 0) + (item["update"] as? Int ?? 0) +
                                (item["delete"] as? Int ?? 0) + (item["extraRows"] as? Int ?? 0) > 0
                        }
                        let unchanged = data.filter { item in
                            (item["insert"] as? Int ?? 0) + (item["update"] as? Int ?? 0) +
                                (item["delete"] as? Int ?? 0) + (item["extraRows"] as? Int ?? 0) == 0
                        }
                        if !changed.isEmpty {
                            Text(L10n.format("Tabel dengan perbedaan (%d)", changed.count)).font(.headline)
                            Text("Buka tabel untuk memeriksa perubahan dan baris yang tetap di tujuan.")
                                .font(SmallFont.subheadline).foregroundStyle(.secondary)
                            ForEach(Array(changed.enumerated()), id: \.offset) { _, item in
                                DataTablePreview(item: item, input: previewInput, model: model)
                            }
                        } else if blockers.isEmpty {
                            Text("Data sumber dan tujuan sudah sesuai. Tidak ada perubahan untuk diterapkan.")
                                .foregroundStyle(.secondary)
                        }
                        if !unchanged.isEmpty {
                            DisclosureGroup(L10n.format("Tabel tanpa perubahan (%d)", unchanged.count), isExpanded: $showUnchangedData) {
                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(Array(unchanged.enumerated()), id: \.offset) { _, item in
                                        Label(item["table"] as? String ?? "", systemImage: "checkmark.circle")
                                            .font(SmallFont.subheadline).foregroundStyle(.secondary)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                                .padding(.top, 6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            if !blockers.isEmpty {
                Label("Penerapan belum tersedia. Selesaikan penghalang lalu klik Bandingkan lagi.",
                      systemImage: "lock.fill")
                    .font(SmallFont.subheadline).foregroundStyle(.secondary)
            } else if changeCount == 0 {
                Label("Tidak ada perubahan untuk diterapkan.", systemImage: "checkmark.circle")
                    .font(SmallFont.subheadline).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    if destructiveCount > 0 {
                        Text(L10n.format(mode == "structure"
                             ? "Rencana ini menghapus %d objek di tujuan. Perubahan struktur tidak dapat dibatalkan sebagai satu transaksi; cadangkan tujuan sebelum menerapkan."
                             : "Rencana ini menghapus %d baris di tujuan. Penghapusan baris akan dijalankan dalam transaksi dan dibatalkan jika terjadi kesalahan.", destructiveCount))
                            .font(SmallFont.caption).foregroundStyle(.orange)
                        Toggle("Saya sudah memeriksa semua penghapusan di atas", isOn: $acknowledgeDestructive)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 5) {
                            Text("Ketik nama database tujuan untuk mengonfirmasi:")
                            Text(targetDatabase).fontWeight(.semibold)
                        }
                        TextField("Nama database tujuan", text: $confirmation)
                            .modifier(FormInput())
                            .frame(maxWidth: 360)
                        Button("Terapkan ke Tujuan") { apply() }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.busy || confirmation != targetDatabase ||
                                      (destructiveCount > 0 && !acknowledgeDestructive))
                    }
                }
            }
        }
    }

    private func isDestructive(_ statement: String) -> Bool {
        let sql = statement.uppercased()
        return sql.hasPrefix("DROP TABLE") || sql.contains(" DROP COLUMN ") ||
            sql.contains(" DROP INDEX ") || sql.contains(" DROP FOREIGN KEY ")
    }

    private func orderedTableNames(in schema: [[String: Any]]) -> [String] {
        var seen = Set<String>()
        return schema.compactMap { item in
            guard let table = item["table"] as? String, seen.insert(table).inserted else { return nil }
            return table
        }
    }

    private func groupedBlockers(_ blockers: [String]) -> [BlockerGroup] {
        var orderedNames: [String] = []
        var issuesByTable: [String: [String]] = [:]
        for issue in blockers {
            let table = blockerTableName(in: issue) ?? L10n.text("Masalah umum")
            if issuesByTable[table] == nil { orderedNames.append(table) }
            issuesByTable[table, default: []].append(issue)
        }
        return orderedNames.compactMap { table in
            guard let issues = issuesByTable[table] else { return nil }
            return BlockerGroup(table: table, issues: issues)
        }
    }

    private func blockerTableName(in issue: String) -> String? {
        let dottedPattern = #"\b([A-Za-z_][A-Za-z0-9_$]*)\.(?=[A-Za-z_])"#
        if let range = issue.range(of: dottedPattern, options: .regularExpression) {
            return String(issue[range].dropLast())
        }
        let leadingPattern = #"^([A-Za-z_][A-Za-z0-9_$]*)\s*:"#
        if let range = issue.range(of: leadingPattern, options: .regularExpression) {
            return String(issue[range].dropLast()).trimmingCharacters(in: .whitespaces)
        }
        let namedPattern = #"\b(?:pada|for)\s+([A-Za-z_][A-Za-z0-9_$]*)\s*:"#
        guard let range = issue.range(of: namedPattern, options: [.regularExpression, .caseInsensitive]) else { return nil }
        let match = String(issue[range])
        guard let tableRange = match.range(of: #"[A-Za-z_][A-Za-z0-9_$]*(?=\s*:)$"#, options: .regularExpression) else { return nil }
        return String(match[tableRange])
    }

    private func statementTitle(_ statement: String) -> String {
        let sql = statement.uppercased()
        if sql.hasPrefix("CREATE TABLE") { return "Buat tabel baru" }
        if sql.hasPrefix("DROP TABLE") { return "Hapus tabel di tujuan" }
        if sql.contains(" DROP FOREIGN KEY ") { return "Hapus foreign key di tujuan" }
        if sql.contains(" ADD COLUMN ") { return "Tambah kolom" }
        if sql.contains(" MODIFY COLUMN ") { return "Ubah kolom" }
        if sql.contains(" DROP COLUMN ") { return "Hapus kolom di tujuan" }
        if sql.contains(" ADD INDEX ") || sql.contains(" ADD KEY ") { return "Tambah indeks" }
        if sql.contains(" DROP INDEX ") { return "Hapus indeks di tujuan" }
        return "Ubah struktur tabel"
    }
}

@main struct DBSyncApp: App {
    var body: some Scene {
        Window("Database Sync", id: "main") { ContentView() }
    }
}
