import Foundation

/// A website sign-in that the user can name and pin to the menu bar.
/// The identifier also names the account's isolated WebKit cookie store.
struct Account: Identifiable, Codable, Equatable {
    let id: UUID
    let provider: Provider
    var label: String
    var pinned: Bool
    /// How this account looks in the menu bar. Optional so accounts saved by
    /// earlier builds still load; nil means the default.
    var menuValue: MenuBarValue? = nil
    var menuLabel: MenuBarLabel? = nil

    var isLegacy: Bool { id == AccountRegistry.legacyID(for: provider) }
    var value: MenuBarValue { menuValue ?? .percentAndTime }
    var labelStyle: MenuBarLabel { menuLabel ?? .logoAndName }
}

/// What a pinned account shows after its logo or name.
enum MenuBarValue: String, Codable, CaseIterable, Sendable {
    /// "38% in 2h 21m": the headline limit and when it resets.
    case percentAndTime
    /// "38%": the headline limit only.
    case percent
    /// "2h 21m": time until the headline limit resets.
    case timeLeft
    /// "38% · 63%": every limit the account reports, shortest window first, so
    /// a 5-hour + weekly account shows two and a weekly-only account shows one.
    case allLimits

    var title: String {
        switch self {
        case .percentAndTime: return "% and time left"
        case .percent: return "% only"
        case .timeLeft: return "Time left only"
        case .allLimits: return "All limits (%)"
        }
    }
}

/// What identifies a pinned account in the menu bar.
enum MenuBarLabel: String, Codable, CaseIterable, Sendable {
    case logoAndName, logo, name, none

    var title: String {
        switch self {
        case .logoAndName: return "Logo and name"
        case .logo: return "Logo only"
        case .name: return "Name only"
        case .none: return "Numbers only"
        }
    }

    var showsLogo: Bool { self == .logoAndName || self == .logo }
    var showsName: Bool { self == .logoAndName || self == .name }
}

/// Persists the list of accounts, without storing cookies or credentials.
/// WebKit owns each account's browser data; see `WebSession`.
@MainActor
final class AccountRegistry {
    static let shared = AccountRegistry()

    nonisolated static let legacyClaudeID = UUID(uuidString: "a7b0ec20-b590-4c2f-a2b6-4157c8e20901")!
    nonisolated static let legacyCodexID = UUID(uuidString: "a7b0ec20-b590-4c2f-a2b6-4157c8e20902")!

    nonisolated static func legacyID(for provider: Provider) -> UUID {
        provider == .claude ? legacyClaudeID : legacyCodexID
    }

    static func isLegacy(_ account: Account) -> Bool { account.isLegacy }

    static var defaultAccounts: [Account] {
        [Account(id: legacyClaudeID, provider: .claude, label: "Claude", pinned: true),
         Account(id: legacyCodexID, provider: .codex, label: "Codex", pinned: true)]
    }

    static var fileURL: URL {
        Database.defaultURL.deletingLastPathComponent().appendingPathComponent("accounts.json")
    }

    private(set) var accounts: [Account]
    private(set) var persistenceError: String?

    init(fileURL: URL? = nil) {
        let url = fileURL ?? Self.fileURL
        self.fileURL = url
        if let data = try? Data(contentsOf: url),
           let loaded = try? JSONDecoder().decode([Account].self, from: data) {
            // Ignore duplicate IDs in a damaged file. Never merge distinct accounts.
            var seen = Set<UUID>()
            accounts = loaded.filter { seen.insert($0.id).inserted }
            let removed = Self.removedLegacyIDs
            for legacy in Self.defaultAccounts where !seen.contains(legacy.id) && !removed.contains(legacy.id) {
                accounts.insert(legacy, at: 0)
            }
        } else {
            // On first launch, these fixed IDs retain the app's existing default
            // browser data and reading files. A deleted/corrupt registry does not
            // erase that data.
            accounts = Self.defaultAccounts
        }
    }

    private let fileURL: URL

    @discardableResult
    func add(provider: Provider, label: String? = nil, pinned: Bool = false) -> Account {
        let count = accounts.filter { $0.provider == provider }.count + 1
        let name = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        let account = Account(id: UUID(), provider: provider,
                              label: (name?.isEmpty == false ? name! : "\(provider.displayName) \(count)"),
                              pinned: pinned)
        accounts.append(account)
        save()
        return account
    }

    func update(_ account: Account) {
        guard let index = accounts.firstIndex(where: { $0.id == account.id }),
              accounts[index].provider == account.provider else { return }
        accounts[index] = account
        save()
    }

    /// Reorders from the accounts list (SwiftUI `onMove`). `destination` is an
    /// index in the list *before* the move, as the list reports it, so dropping
    /// below the last row is `accounts.count`. The list order is the order of
    /// the usage cards and of the pinned items in the menu bar.
    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.filter { accounts.indices.contains($0) }.map { accounts[$0] }
        guard !moving.isEmpty else { return }
        let before = source.filter { $0 < destination }.count
        accounts.removeAll { account in moving.contains { $0.id == account.id } }
        let insertAt = min(max(destination - before, 0), accounts.count)
        accounts.insert(contentsOf: moving, at: insertAt)
        save()
    }

    /// Removing an account removes its list entry. Call `WebSession.removeAccountData`
    /// as well to erase its browser sign-in.
    func remove(id: UUID) {
        accounts.removeAll { $0.id == id }
        // The original two are otherwise put back at every launch.
        if id == Self.legacyClaudeID || id == Self.legacyCodexID {
            Self.removedLegacyIDs.insert(id)
        }
        save()
    }

    /// The original accounts the user removed, so they stay removed.
    private static let removedLegacyKey = "removedLegacyAccounts"
    static var removedLegacyIDs: Set<UUID> {
        get {
            Set((UserDefaults.standard.stringArray(forKey: removedLegacyKey) ?? []).compactMap(UUID.init))
        }
        set { UserDefaults.standard.set(newValue.map(\.uuidString).sorted(), forKey: removedLegacyKey) }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(accounts)
            try data.write(to: fileURL, options: [.atomic])
            persistenceError = nil
        } catch {
            persistenceError = "Could not save accounts: \(error.localizedDescription)"
        }
    }
}
