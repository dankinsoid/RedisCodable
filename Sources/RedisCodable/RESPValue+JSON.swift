import RediStack
import Foundation

extension RESPValue {

    public init<T: Encodable>(json: T, encoder: JSONEncoder = .redis) throws {
        try self.init(from: encoder.encode(json))
    }

    public func json<T: Decodable>(as type: T.Type = T.self, decoder: JSONDecoder = JSONDecoder()) throws -> T {
        guard let data else { throw InvalidRESPValue() }
        return try decoder.decode(T.self, from: data)
    }
}

extension JSONEncoder {

    public static var redis: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }
}

struct InvalidRESPValue: Error {}
