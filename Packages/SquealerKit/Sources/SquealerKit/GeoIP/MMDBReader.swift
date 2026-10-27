import Foundation

/// A reader for the MaxMind DB format (used by DB-IP Lite and GeoLite2), written from the public spec at
/// https://maxmind.github.io/MaxMind-DB/.
public final class MMDBReader: Sendable {
    public enum Value: Sendable, Hashable {
        case string(String)
        case double(Double)
        case bytes(Data)
        case uint(UInt64)
        case int(Int32)
        case map([String: Value])
        case array([Value])
        case bool(Bool)
        case float(Float)

        public subscript(key: String) -> Value? {
            if case .map(let map) = self { return map[key] }
            return nil
        }

        public subscript(path keys: String...) -> Value? {
            keys.reduce(Optional(self)) { $0?[$1] }
        }

        public var string: String? {
            if case .string(let value) = self { return value }
            return nil
        }

        public var number: Double? {
            switch self {
            case .double(let value): value
            case .float(let value): Double(value)
            case .uint(let value): Double(value)
            case .int(let value): Double(value)
            default: nil
            }
        }
    }

    public struct Metadata: Sendable {
        public var nodeCount: Int
        public var recordSize: Int
        public var ipVersion: Int
        public var databaseType: String
        public var buildEpoch: Date?
    }

    public enum ReadError: Error, Equatable {
        case missingMetadata
        case invalidMetadata
        case corruptData
        case unsupportedRecordSize(Int)
    }

    private static let metadataMarker = Data([0xAB, 0xCD, 0xEF] + Array("MaxMind.com".utf8))

    public let metadata: Metadata
    private let data: Data
    private let treeSize: Int
    private let dataSectionStart: Int
    private let ipv4StartNode: Int

    public convenience init(contentsOf url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: .alwaysMapped))
    }

    public init(data: Data) throws {
        let data = data.startIndex == 0 ? data : Data(data)
        self.data = data
        guard let markerRange = data.range(of: Self.metadataMarker, options: .backwards) else {
            throw ReadError.missingMetadata
        }
        var decoder = Decoder(data: data, base: markerRange.upperBound, offset: markerRange.upperBound)
        guard case .map(let map) = try decoder.decode(),
              let nodeCount = map["node_count"]?.number,
              let recordSize = map["record_size"]?.number,
              let ipVersion = map["ip_version"]?.number
        else {
            throw ReadError.invalidMetadata
        }
        guard [24, 28, 32].contains(Int(recordSize)) else { throw ReadError.unsupportedRecordSize(Int(recordSize)) }
        metadata = Metadata(
            nodeCount: Int(nodeCount),
            recordSize: Int(recordSize),
            ipVersion: Int(ipVersion),
            databaseType: map["database_type"]?.string ?? "",
            buildEpoch: map["build_epoch"]?.number.map { Date(timeIntervalSince1970: $0) }
        )
        treeSize = Int(recordSize) * 2 / 8 * Int(nodeCount)
        dataSectionStart = treeSize + 16
        guard dataSectionStart <= data.count else { throw ReadError.corruptData }

        var node = 0
        if Int(ipVersion) == 6 {
            for _ in 0..<96 where node < Int(nodeCount) {
                node = try Self.record(in: data, node: node, bit: 0, recordSize: Int(recordSize))
            }
        }
        ipv4StartNode = node
    }

    public func lookup(_ address: IPAddress) throws -> Value? {
        let bits: [UInt8]
        var node: Int
        switch address {
        case .v4:
            bits = address.bytes
            node = ipv4StartNode
        case .v6:
            guard metadata.ipVersion == 6 else { return nil }
            bits = address.bytes
            node = 0
        }

        for index in 0..<bits.count * 8 {
            guard node < metadata.nodeCount else { break }
            let bit = Int(bits[index / 8] >> (7 - UInt8(index % 8)) & 1)
            node = try Self.record(in: data, node: node, bit: bit, recordSize: metadata.recordSize)
        }

        if node == metadata.nodeCount { return nil }
        guard node > metadata.nodeCount else { throw ReadError.corruptData }
        let offset = node - metadata.nodeCount - 16
        var decoder = Decoder(data: data, base: dataSectionStart, offset: dataSectionStart + offset)
        return try decoder.decode()
    }

    private static func record(in data: Data, node: Int, bit: Int, recordSize: Int) throws -> Int {
        let nodeBytes = recordSize * 2 / 8
        let start = data.startIndex + node * nodeBytes
        guard start + nodeBytes <= data.endIndex else { throw ReadError.corruptData }
        func bytes(_ range: Range<Int>) -> Int {
            range.reduce(0) { $0 << 8 | Int(data[start + $1]) }
        }
        switch recordSize {
        case 24:
            return bit == 0 ? bytes(0..<3) : bytes(3..<6)
        case 28:
            let middle = Int(data[start + 3])
            return bit == 0 ? (middle & 0xF0) << 20 | bytes(0..<3) : (middle & 0x0F) << 24 | bytes(4..<7)
        default:
            return bit == 0 ? bytes(0..<4) : bytes(4..<8)
        }
    }

    private struct Decoder {
        let data: Data
        /// Pointers are relative to this position (the data section, or the metadata start).
        let base: Int
        var offset: Int
        var depth = 0

        mutating func byte() throws -> Int {
            guard offset < data.count else { throw ReadError.corruptData }
            defer { offset += 1 }
            return Int(data[data.startIndex + offset])
        }

        mutating func integer(_ size: Int) throws -> UInt64 {
            guard size <= 8 else { throw ReadError.corruptData }
            var value: UInt64 = 0
            for _ in 0..<size { value = value << 8 | UInt64(try byte()) }
            return value
        }

        mutating func slice(_ size: Int) throws -> Data {
            guard offset + size <= data.count else { throw ReadError.corruptData }
            defer { offset += size }
            let start = data.startIndex + offset
            return data[start..<start + size]
        }

        mutating func decode() throws -> Value {
            depth += 1
            defer { depth -= 1 }
            guard depth < 64 else { throw ReadError.corruptData }

            let control = try byte()
            var type = control >> 5
            if type == 1 {
                let pointerSize = (control >> 3) & 0x3
                let high = control & 0x7
                let target: Int = switch pointerSize {
                case 0: high << 8 | Int(try integer(1))
                case 1: (high << 16 | Int(try integer(2))) + 2_048
                case 2: (high << 24 | Int(try integer(3))) + 526_336
                default: Int(try integer(4))
                }
                var pointed = Decoder(data: data, base: base, offset: base + target, depth: depth)
                return try pointed.decode()
            }
            if type == 0 {
                type = 7 + (try byte())
            }
            var size = control & 0x1F
            switch size {
            case 29: size = 29 + Int(try integer(1))
            case 30: size = 285 + Int(try integer(2))
            case 31: size = 65_821 + Int(try integer(3))
            default: break
            }

            switch type {
            case 2:
                return .string(String(decoding: try slice(size), as: UTF8.self))
            case 3:
                guard size == 8 else { throw ReadError.corruptData }
                return .double(Double(bitPattern: try integer(8)))
            case 4:
                return .bytes(Data(try slice(size)))
            case 5, 6, 9:
                return .uint(try integer(size))
            case 7:
                var map: [String: Value] = [:]
                for _ in 0..<size {
                    guard case .string(let key) = try decode() else { throw ReadError.corruptData }
                    map[key] = try decode()
                }
                return .map(map)
            case 8:
                return .int(Int32(truncatingIfNeeded: try integer(size)))
            case 10:
                return .bytes(Data(try slice(size)))
            case 11:
                var array: [Value] = []
                for _ in 0..<size { array.append(try decode()) }
                return .array(array)
            case 14:
                return .bool(size != 0)
            case 15:
                guard size == 4 else { throw ReadError.corruptData }
                return .float(Float(bitPattern: UInt32(try integer(4))))
            default:
                throw ReadError.corruptData
            }
        }
    }
}
