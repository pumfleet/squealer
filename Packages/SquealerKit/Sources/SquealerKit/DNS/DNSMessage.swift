import Foundation

public struct DNSMessage: Sendable, Hashable {
    public struct Question: Sendable, Hashable {
        public var name: String
        public var type: UInt16
    }

    public enum RecordData: Sendable, Hashable {
        case address(IPAddress)
        case cname(String)
        case ptr(String)
        case other
    }

    public struct Record: Sendable, Hashable {
        public var name: String
        public var type: UInt16
        public var ttl: UInt32
        public var data: RecordData
    }

    public struct Resolution: Sendable, Hashable {
        public var address: IPAddress
        /// The name that was originally asked for, before following CNAMEs.
        public var hostname: String
        public var ttl: UInt32
    }

    public enum ParseError: Error, Equatable {
        case truncated
        case badPointer
        case nameTooLong
    }

    public var id: UInt16
    public var isResponse: Bool
    public var responseCode: UInt8
    public var questions: [Question]
    public var answers: [Record]

    public static let typeA: UInt16 = 1
    public static let typeCNAME: UInt16 = 5
    public static let typePTR: UInt16 = 12
    public static let typeAAAA: UInt16 = 28

    public init(_ bytes: some Collection<UInt8>) throws {
        var reader = Reader(bytes: Array(bytes))
        id = try reader.u16()
        let flags = try reader.u16()
        isResponse = flags & 0x8000 != 0
        responseCode = UInt8(flags & 0x000F)
        let questionCount = try reader.u16()
        let answerCount = try reader.u16()
        _ = try reader.u16()
        _ = try reader.u16()

        var questions: [Question] = []
        for _ in 0..<questionCount {
            let name = try reader.name()
            let type = try reader.u16()
            _ = try reader.u16()
            questions.append(Question(name: name, type: type))
        }
        self.questions = questions

        var answers: [Record] = []
        for _ in 0..<answerCount {
            let name = try reader.name()
            let type = try reader.u16()
            _ = try reader.u16()
            let ttl = try reader.u32()
            let length = Int(try reader.u16())
            let end = reader.offset + length
            guard end <= reader.bytes.count else { throw ParseError.truncated }
            let data: RecordData
            switch type {
            case Self.typeA where length == 4, Self.typeAAAA where length == 16:
                data = IPAddress(bytes: reader.bytes[reader.offset..<end]).map(RecordData.address) ?? .other
            case Self.typeCNAME:
                data = .cname(try reader.name())
            case Self.typePTR:
                data = .ptr(try reader.name())
            default:
                data = .other
            }
            reader.offset = end
            answers.append(Record(name: name, type: type, ttl: ttl, data: data))
        }
        self.answers = answers
    }

    /// Address → original hostname pairs, following CNAME chains back to the question.
    public var resolutions: [Resolution] {
        guard isResponse, responseCode == 0 else { return [] }
        var results: [Resolution] = []
        for question in questions where question.type == Self.typeA || question.type == Self.typeAAAA {
            var chain: Set<String> = [question.name]
            var changed = true
            while changed {
                changed = false
                for record in answers {
                    if case .cname(let target) = record.data, chain.contains(record.name), chain.insert(target).inserted {
                        changed = true
                    }
                }
            }
            for record in answers where chain.contains(record.name) {
                if case .address(let address) = record.data {
                    results.append(Resolution(address: address, hostname: question.name, ttl: record.ttl))
                }
            }
        }
        return results
    }

    private struct Reader {
        let bytes: [UInt8]
        var offset = 0

        mutating func u8() throws -> UInt8 {
            guard offset < bytes.count else { throw ParseError.truncated }
            defer { offset += 1 }
            return bytes[offset]
        }

        mutating func u16() throws -> UInt16 {
            UInt16(try u8()) << 8 | UInt16(try u8())
        }

        mutating func u32() throws -> UInt32 {
            UInt32(try u16()) << 16 | UInt32(try u16())
        }

        mutating func name() throws -> String {
            var labels: [String] = []
            var position = offset
            var jumped = false
            var jumps = 0
            var length = 0
            while true {
                guard position < bytes.count else { throw ParseError.truncated }
                let byte = bytes[position]
                if byte & 0xC0 == 0xC0 {
                    guard position + 1 < bytes.count else { throw ParseError.truncated }
                    let pointer = Int(byte & 0x3F) << 8 | Int(bytes[position + 1])
                    guard pointer < bytes.count, jumps < 64 else { throw ParseError.badPointer }
                    if !jumped { offset = position + 2 }
                    jumped = true
                    jumps += 1
                    position = pointer
                } else if byte == 0 {
                    if !jumped { offset = position + 1 }
                    break
                } else {
                    let labelLength = Int(byte)
                    let start = position + 1
                    guard start + labelLength <= bytes.count else { throw ParseError.truncated }
                    length += labelLength + 1
                    guard length <= 255 else { throw ParseError.nameTooLong }
                    labels.append(String(decoding: bytes[start..<start + labelLength], as: UTF8.self).lowercased())
                    position = start + labelLength
                }
            }
            return labels.joined(separator: ".")
        }
    }
}

/// Splits a DNS-over-TCP byte stream (two-byte length prefixed) into messages, buffering partial reads.
public struct DNSStreamBuffer: Sendable {
    private var buffer: [UInt8] = []
    public static let maximumBuffered = 128 * 1024

    public init() {}

    public mutating func append(_ bytes: some Collection<UInt8>) -> [DNSMessage] {
        buffer.append(contentsOf: bytes)
        var messages: [DNSMessage] = []
        while buffer.count >= 2 {
            let length = Int(buffer[0]) << 8 | Int(buffer[1])
            guard buffer.count >= 2 + length else { break }
            if let message = try? DNSMessage(buffer[2..<2 + length]) {
                messages.append(message)
            }
            buffer.removeFirst(2 + length)
        }
        if buffer.count > Self.maximumBuffered {
            buffer.removeAll()
        }
        return messages
    }
}
