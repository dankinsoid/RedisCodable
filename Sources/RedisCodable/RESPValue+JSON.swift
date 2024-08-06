import RediStack
import Foundation

extension RESPValue {
    
    public init<T: Encodable>(json: T, encoder: JSONEncoder = JSONEncoder()) throws {
        try self.init(from: encoder.encode(json))
    }
    
    public func json<T: Decodable>(as type: T.Type = T.self, decoder: JSONDecoder = JSONDecoder()) throws -> T {
        guard let data else { throw InvalidRESPValue() }
        return try decoder.decode(T.self, from: data)
    }
}

struct InvalidRESPValue: Error {}
