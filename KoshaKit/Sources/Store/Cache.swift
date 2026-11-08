import Foundation
import Model

/// What this phone saved: the last answer for each read, as JSON files in the app group's container (so the widget can
/// read them too). Written atomically; cleared on sign-out.
public final class Cache: @unchecked Sendable {
    let dir: URL

    public init(directory: URL? = nil) {
        let base = directory ?? Cache.container.appendingPathComponent("cache", isDirectory: true)
        dir = base
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    /// The app group's container, shared with the widget; Application Support when there is none (tests, previews).
    public static var container: URL {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.app.getkosha")
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Kosha", isDirectory: true)
    }

    private func file(_ key: String) -> URL {
        let safe = key.map { $0.isLetter || $0.isNumber || "._-".contains($0) ? $0 : "_" }
        return dir.appendingPathComponent(String(safe) + ".json")
    }

    public func read<T: Decodable>(_ key: String, as type: T.Type = T.self) -> T? {
        guard let data = try? Data(contentsOf: file(key)) else { return nil }
        return try? KoshaJSON.decode(T.self, data)
    }

    public func write<T: Encodable>(_ key: String, _ value: T) {
        guard let data = try? KoshaJSON.encode(value) else { return }
        try? data.write(to: file(key), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    public func clear() {
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
}
