import Foundation

/// Persists the account list to `accounts.json` under Application Support.
///
/// The store owns nothing but the metadata: the actual browser session for an
/// account lives in a `WKWebsiteDataStore` keyed by the account's `id`
/// (see `AccountSession`). Sidebar order is creation order; v1 has no
/// reordering.
final class AccountStore {
    private static let folderName = "MailSpace"
    private static let fileName = "accounts.json"

    private let directory: URL
    private let fileURL: URL

    private(set) var accounts: [Account] = []

    static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(folderName, isDirectory: true)
    }

    init(directory: URL = AccountStore.defaultDirectory) {
        self.directory = directory
        self.fileURL = directory.appendingPathComponent(Self.fileName)
        load()
    }

    // MARK: - Queries

    func account(id: UUID) -> Account? {
        accounts.first { $0.id == id }
    }

    // MARK: - Mutations

    @discardableResult
    func add(name: String) -> Account {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let account = Account(name: trimmed.isEmpty ? "Account \(accounts.count + 1)" : trimmed)
        accounts.append(account)
        save()
        return account
    }

    func remove(id: UUID) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts.remove(at: index)
        save()
    }

    func rename(id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[index].name = trimmed
        save()
    }

    func setLastView(_ view: AccountView, for id: UUID) {
        guard let index = accounts.firstIndex(where: { $0.id == id }), accounts[index].lastView != view else { return }
        accounts[index].lastView = view
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else {
            accounts = []
            return
        }
        do {
            accounts = try JSONDecoder().decode([Account].self, from: data)
        } catch {
            // A corrupt or hand-edited file must never block launch: start
            // empty and let the next save rewrite it.
            FileHandle.standardError.write(Data("MailSpace: could not read \(fileURL.path): \(error)\n".utf8))
            accounts = []
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(accounts).write(to: fileURL, options: .atomic)
        } catch {
            FileHandle.standardError.write(Data("MailSpace: could not write \(fileURL.path): \(error)\n".utf8))
        }
    }
}
