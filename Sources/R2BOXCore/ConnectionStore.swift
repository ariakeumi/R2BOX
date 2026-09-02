import Foundation

/// 连接配置持久化（JSON）+ Secret 转存 Keychain。
public struct ConnectionStore: Sendable {
    public static let shared = ConnectionStore()

    private let fileURL: URL
    private let keychain = KeychainStore()

    public init(directory: URL? = nil) {
        let dir = directory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("R2BOX", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("connections.json")
    }

    public func load() -> [Connection] {
        guard let data = try? Data(contentsOf: fileURL),
              let list = try? JSONDecoder().decode([Connection].self, from: data)
        else { return [] }
        return list
    }

    public func save(_ list: [Connection]) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: - Keychain

    private func account(for id: UUID) -> String { "conn.\(id.uuidString)" }

    public func setSecret(_ secret: String, for id: UUID) throws {
        try keychain.setSecret(secret, account: account(for: id))
    }

    public func secret(for id: UUID) -> String? {
        keychain.getSecret(account: account(for: id))
    }

    public func deleteSecret(for id: UUID) {
        keychain.deleteSecret(account: account(for: id))
    }

    public func hasSecret(for id: UUID) -> Bool {
        secret(for: id) != nil
    }
}
