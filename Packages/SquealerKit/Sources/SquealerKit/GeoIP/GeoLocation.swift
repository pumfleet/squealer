import Foundation

public struct GeoLocation: Hashable, Sendable, Codable {
    public var countryCode: String?
    public var countryName: String?
    public var city: String?
    public var latitude: Double?
    public var longitude: Double?
    public var organization: String?

    public init(countryCode: String? = nil, countryName: String? = nil, city: String? = nil, latitude: Double? = nil, longitude: Double? = nil, organization: String? = nil) {
        self.countryCode = countryCode
        self.countryName = countryName
        self.city = city
        self.latitude = latitude
        self.longitude = longitude
        self.organization = organization
    }

    public var flag: String? {
        guard let code = countryCode?.uppercased(), code.count == 2 else { return nil }
        let scalars = code.unicodeScalars.compactMap { Unicode.Scalar(127_397 + $0.value) }
        return String(String.UnicodeScalarView(scalars))
    }

    public var placeName: String? {
        switch (city, countryName) {
        case let (city?, country?): "\(city), \(country)"
        case let (nil, country?): country
        case let (city?, nil): city
        default: nil
        }
    }
}

/// Combines a city database and an optional ASN database (both MaxMind DB format) into one lookup.
public final class GeoIPDatabase: Sendable {
    private let city: MMDBReader?
    private let asn: MMDBReader?

    public init(city: MMDBReader?, asn: MMDBReader?) {
        self.city = city
        self.asn = asn
    }

    public func location(for address: IPAddress) -> GeoLocation? {
        guard !address.isLocal else { return nil }
        var location = GeoLocation()
        if let record = try? city?.lookup(address) {
            location.countryCode = record[path: "country", "iso_code"]?.string
            location.countryName = record[path: "country", "names", "en"]?.string
            location.city = record[path: "city", "names", "en"]?.string
            location.latitude = record[path: "location", "latitude"]?.number
            location.longitude = record[path: "location", "longitude"]?.number
        }
        if let record = try? asn?.lookup(address) {
            location.organization = record["autonomous_system_organization"]?.string
        }
        return location == GeoLocation() ? nil : location
    }
}
