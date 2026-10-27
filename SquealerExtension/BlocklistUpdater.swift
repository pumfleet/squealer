import Foundation
import SquealerKit

/// Downloads blocklists and caches the raw source next to the store, so they're available offline after a
/// restart without re-downloading.
final class BlocklistUpdater: Sendable {
    enum UpdateError: LocalizedError {
        case http(Int)
        case empty

        var errorDescription: String? {
            switch self {
            case .http(let status): "The server responded with HTTP \(status)."
            case .empty: "The list didn't contain any usable entries."
            }
        }
    }

    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        configuration.httpAdditionalHeaders = ["User-Agent": "Squealer"]
        return URLSession(configuration: configuration)
    }()

    func download(_ subscription: BlocklistSubscription, to directory: URL) async throws -> BlocklistParser.Result {
        let (data, response) = try await session.data(from: subscription.url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw UpdateError.http(http.statusCode)
        }
        let result = try BlocklistParser.parse(data, format: subscription.format)
        guard !result.entries.isEmpty else { throw UpdateError.empty }
        try data.write(to: cacheURL(id: subscription.id, in: directory), options: .atomic)
        return result
    }

    func loadCached(_ subscription: BlocklistSubscription, from directory: URL) -> BlocklistEntries? {
        guard let data = try? Data(contentsOf: cacheURL(id: subscription.id, in: directory)) else { return nil }
        return try? BlocklistParser.parse(data, format: subscription.format).entries
    }

    func removeCache(id: UUID, in directory: URL) {
        try? FileManager.default.removeItem(at: cacheURL(id: id, in: directory))
    }

    private func cacheURL(id: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent("\(id.uuidString).list")
    }
}
