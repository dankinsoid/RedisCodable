import RediStack
import Foundation
import NIOCore

enum RedisCommandEncoderValue {
    
	case single(RESPValue)
	case keyed([(String, RedisCommandEncoderValue)])
	case unkeyed([RedisCommandEncoderValue])

	var unkeyed: [RedisCommandEncoderValue] {
		get {
			if case let .unkeyed(result) = self {
				return result
			}
			return []
		}
		set {
			self = .unkeyed(newValue)
		}
	}

	var keyed: [(String, RedisCommandEncoderValue)] {
		get {
			if case let .keyed(result) = self {
				return result
			}
			return []
		}
		set {
			self = .keyed(newValue)
		}
	}

	var single: RESPValue {
		get {
			if case let .single(result) = self {
				return result
			}
            return .null
		}
		set {
			self = .single(newValue)
		}
	}
}

extension RedisCommandEncoderValue: Encodable {

    func encode(to encoder: Encoder) throws {
        switch self {
        case let .single(value):
            try EncodableRESP(value).encode(to: encoder)
        case let .keyed(array):
            var container = encoder.container(keyedBy: PlainCodingKey.self)
            for (key, value) in array {
                try container.encode(value, forKey: PlainCodingKey(key))
            }
        case let .unkeyed(array):
            var container = encoder.unkeyedContainer()
            for value in array {
                try container.encode(value)
            }
        }
    }
}

private struct EncodableRESP: Encodable {
    
    let resp: RESPValue
    
    init(_ resp: RESPValue) {
        self.resp = resp
    }
    
    func encode(to encoder: any Encoder) throws {
        switch resp {
        case .null, .bulkString(nil):
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        case let .simpleString(buffer):
            let string = String(buffer: buffer)
            var container = encoder.singleValueContainer()
            try container.encode(string)
        case let .bulkString(.some(buffer)):
            let data = Data(buffer.readableBytesView)
            var container = encoder.singleValueContainer()
            try container.encode(data)
        case let .error(redisError):
            var container = encoder.singleValueContainer()
            try container.encode(redisError.message)
        case let .integer(int):
            var container = encoder.singleValueContainer()
            try container.encode(int)
        case let .array(array):
            var container = encoder.unkeyedContainer()
            for value in array {
                try container.encode(EncodableRESP(value))
            }
        }
    }
}

struct RESPEncoderError: LocalizedError, CustomStringConvertible {
    
    var description: String
    var errorDescription: String? { description }
    
    init(_ description: String) {
        self.description = description
    }
}
