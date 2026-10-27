import Foundation
import os
import SquealerKit
import Synchronization

/// Country and network-owner lookups from the bundled DB-IP Lite databases, with an optional city-level
/// database downloaded on request for precise map positions.
final class GeoService: Sendable {
    static let shared = GeoService()

    private struct State {
        var database: GeoIPDatabase?
        var cache: [IPAddress: GeoLocation?] = [:]
    }

    private let state = Mutex(State())
    private let centroids: [String: [Double]]
    private let logger = Logger(subsystem: XPCConstants.logSubsystem, category: "geo")

    static var cityDatabaseURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Squealer/GeoIP/dbip-city-lite.mmdb")
    }

    private init() {
        centroids = Bundle.main.url(forResource: "country-centroids", withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode([String: [Double]].self, from: $0) } ?? [:]
        reload()
    }

    func reload() {
        func open(_ url: URL?) -> MMDBReader? {
            guard let url, FileManager.default.fileExists(atPath: url.path) else { return nil }
            do {
                return try MMDBReader(contentsOf: url)
            } catch {
                logger.error("Couldn't open \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
        let city = open(Self.cityDatabaseURL) ?? open(Bundle.main.url(forResource: "dbip-country-lite", withExtension: "mmdb"))
        let asn = open(Bundle.main.url(forResource: "dbip-asn-lite", withExtension: "mmdb"))
        let database = city == nil && asn == nil ? nil : GeoIPDatabase(city: city, asn: asn)
        state.withLock { state in
            state.database = database
            state.cache.removeAll()
        }
    }

    var hasCityDatabase: Bool {
        FileManager.default.fileExists(atPath: Self.cityDatabaseURL.path)
    }

    func location(for address: IPAddress?) -> GeoLocation? {
        guard let address else { return nil }
        if let cached = state.withLock({ $0.cache[address] }) {
            return cached
        }
        let database = state.withLock { $0.database }
        var location = database?.location(for: address)
        if location != nil, location?.latitude == nil, let code = location?.countryCode, let centroid = centroids[code], centroid.count == 2 {
            location?.latitude = centroid[0]
            location?.longitude = centroid[1]
        }
        state.withLock { state in
            if state.cache.count > 20_000 { state.cache.removeAll() }
            state.cache[address] = location
        }
        return location
    }

    /// Downloads DB-IP City Lite (~130 MB) for city-level map positions.
    func downloadCityDatabase() async throws {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        var lastError: Error = URLError(.fileDoesNotExist)
        for monthOffset in [0, -1] {
            let month = formatter.string(from: Calendar.current.date(byAdding: .month, value: monthOffset, to: .now)!)
            let url = URL(string: "https://download.db-ip.com/free/dbip-city-lite-\(month).mmdb.gz")!
            do {
                let (compressed, response) = try await URLSession.shared.download(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { continue }
                let destination = Self.cityDatabaseURL
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Self.gunzip(compressed, to: destination)
                _ = try MMDBReader(contentsOf: destination)
                reload()
                return
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    func removeCityDatabase() {
        try? FileManager.default.removeItem(at: Self.cityDatabaseURL)
        reload()
    }

    private static func gunzip(_ source: URL, to destination: URL) throws {
        let temporary = destination.appendingPathExtension("download")
        FileManager.default.createFile(atPath: temporary.path, contents: nil)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
        process.arguments = ["-c", source.path]
        process.standardOutput = try FileHandle(forWritingTo: temporary)
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileReadCorruptFile) }
        _ = try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
    }
}
