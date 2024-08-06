import Foundation
import RediStack
import NIOCore

public struct RESPEncoder {

	public let dateEncodingStrategy: JSONEncoder.DateEncodingStrategy
	public var nestedEncodingStrategy: NestedEncodingStrategy
	public var keyEncodingStrategy: JSONEncoder.KeyEncodingStrategy
	public var boolEncodingStrategy: BoolEncodingStrategy
    public var encodeNullIfNotPresented: Bool

	public init(
		dateEncodingStrategy: JSONEncoder.DateEncodingStrategy = .deferredToDate,
		keyEncodingStrategy: JSONEncoder.KeyEncodingStrategy = .useDefaultKeys,
		nestedEncodingStrategy: NestedEncodingStrategy = .json,
        boolEncodingStrategy: BoolEncodingStrategy = .default,
        encodeNullIfNotPresented: Bool = false
	) {
		self.dateEncodingStrategy = dateEncodingStrategy
		self.nestedEncodingStrategy = nestedEncodingStrategy
		self.keyEncodingStrategy = keyEncodingStrategy
		self.boolEncodingStrategy = boolEncodingStrategy
        self.encodeNullIfNotPresented = encodeNullIfNotPresented
	}

	public func encode<T: Encodable>(_ value: T) throws -> RESPValue {
		let encoder = _RESPEncoder(path: [], context: self)
		let query = try encoder.encode(value)
        do {
            return try respValue(for: encoder.result)
        } catch {
            throw EncodingError.invalidValue(
                value,
                EncodingError.Context(
                    codingPath: encoder.codingPath,
                    debugDescription: "Unsupported type",
                    underlyingError: error
                )
            )
        }
	}

    public func encodeHash<T: Encodable>(_ value: T) throws -> [String: RESPValue] {
        let encoder = _RESPEncoder(path: [], context: self)
        encoder.allowNestedArrays = false
        let query = try encoder.encode(value)
        guard case let .keyed(array) = query else {
            throw EncodingError.invalidValue(
                value,
                EncodingError.Context(
                    codingPath: encoder.codingPath,
                    debugDescription: "Expected a keyed value",
                    underlyingError: nil
                )
            )
        }
        return Dictionary(array) { _, p in p }.mapValues(\.single)
    }

    public func encodeCommandArguments<T: Encodable>(_ value: T) throws -> [RESPValue] {
        let encoder = _RESPEncoder(path: [], context: self)
        let query = try encoder.encode(value)
        return try commandArguments(for: encoder.result, encoder: encoder)
    }

	public struct BoolEncodingStrategy {

        private let _encode: (Bool) -> RESPValue

        public static func custom(_ encode: @escaping (_ value: Bool) -> RESPValue) -> Self {
            BoolEncodingStrategy(_encode: encode)
        }

        public static func string(_ encode: @escaping (_ value: Bool) -> String) -> Self {
            .custom { encode($0).convertedToRESPValue() }
        }
    
        /// Encode booleans as "true" and "false"
        public static var `default`: Self { string(\.description) }
        /// Encode booleans as "YES" and "NO"
        public static var yesNo: Self { string { $0 ? "YES" : "NO" } }
        /// Encode booleans as 1 and 0
        public static var number: Self { custom { .integer($0 ? 1 : 0) } }

        public func encode(_ value: Bool) -> RESPValue {
            _encode(value)
        }
	}

	public enum NestedEncodingStrategy {

		case json(JSONEncoder?)
        case custom((Encodable, [CodingKey]) throws -> Data)

		public static var json: NestedEncodingStrategy { .json(nil) }
        public static var `throw`: NestedEncodingStrategy {
            .custom { value, path in
                throw EncodingError.invalidValue(
                    value,
                    EncodingError.Context(codingPath: path, debugDescription: "Doesn't support nested values")
                )
            }
        }
	}
}

private extension RESPEncoder {

    static let allocator = ByteBufferAllocator()

    func respValue(for value: RedisCommandEncoderValue) throws -> RESPValue {
        switch value {
        case .single(let value):
            return value
        case let .keyed(array):
            throw RESPEncoderError("RESP 2.0 doesn't support maps")
        case .unkeyed(let array):
            return try .array(array.map { try respValue(for: $0) })
        }
    }

    func commandArguments(for value: RedisCommandEncoderValue, encoder: _RESPEncoder) throws -> [RESPValue] {
        switch value {
        case let .single(.array(array)):
            return array
        case .single(let value):
            return [value]
        case let .keyed(array):
            guard !array.isEmpty else { return [] }
            var result: [RESPValue] = []
            result.reserveCapacity(array.count * 2)
            for (key, value) in array {
                result.append(.bulkString(Self.allocator.buffer(string: key)))
                try result.append(nestedCommandArgument(value: value, encoder: encoder))
            }
            return result
        case .unkeyed(let array):
            if array.count == 1 {
                return try commandArguments(for: array[0], encoder: encoder)
            }
            return try array.map(encoder.encodeData)
        }
    }

    func nestedCommandArgument(value: RedisCommandEncoderValue, encoder: _RESPEncoder) throws -> RESPValue {
        switch value {
        case let .single(.array(array)):
            if array.count == 1 {
                return array[0]
            }
            return try encoder.encodeData(value)
        case let .single(value):
            return value
        case let .keyed(array):
            return try encoder.encodeData(value)
        case .unkeyed(let array):
            if array.count == 1 {
                return try nestedCommandArgument(value: array[0], encoder: encoder)
            }
            return try encoder.encodeData(value)
        }
    }
}

final class _RESPEncoder: Encoder {

	var codingPath: [CodingKey]
	let context: RESPEncoder
	var userInfo: [CodingUserInfoKey: Any]
    var allowNestedArrays = true
	@Ref var result: RedisCommandEncoderValue

	convenience init(path: [CodingKey] = [], context: RESPEncoder) {
		var value: RedisCommandEncoderValue = .keyed([])
		let ref: Ref<RedisCommandEncoderValue> = Ref {
			value
		} set: {
			value = $0
		}
		self.init(path: path, context: context, result: ref)
	}

	init(path: [CodingKey] = [], context: RESPEncoder, result: Ref<RedisCommandEncoderValue>) {
		codingPath = path
		self.context = context
		userInfo = [:]
		_result = result
	}

	func container<Key>(keyedBy _: Key.Type) -> KeyedEncodingContainer<Key> where Key: CodingKey {
		let container = RedisCommandKeyedEncodingContainer<Key>(
			codingPath: codingPath,
			encoder: self,
			result: Ref(self, \.result.keyed)
		)
		return KeyedEncodingContainer(container)
	}

	func unkeyedContainer() -> UnkeyedEncodingContainer {
		RedisCommandSingleValueEncodingContainer(
			isSingle: false,
			codingPath: codingPath,
			encoder: self,
			result: Ref(self, \.result)
		)
	}

	func singleValueContainer() -> SingleValueEncodingContainer {
		RedisCommandSingleValueEncodingContainer(
			isSingle: true,
			codingPath: codingPath,
			encoder: self,
			result: Ref(self, \.result)
		)
	}

	@discardableResult
	func encode(_ value: Encodable) throws -> RedisCommandEncoderValue {
        if let convertable = value as? RESPValueConvertible {
            result = .single(convertable.convertedToRESPValue())
            return result
        }
		let isArrayEncoder = IsArrayEncoder(codingPath: codingPath)
		try? value.encode(to: isArrayEncoder)
		let isArray = isArrayEncoder.isArray ?? false
		let isSingle = isArrayEncoder.isSingle ?? false
		if !isSingle, !codingPath.isEmpty, isArray != allowNestedArrays {
            result = try .single(encodeData(value))
		} else if let date = value as? Date {
			try context.dateEncodingStrategy.encode(date, encoder: self)
		} else if let decimal = value as? Decimal {
            result = .single(decimal.description.convertedToRESPValue())
		} else if let url = value as? URL {
            result = .single(url.absoluteString.convertedToRESPValue())
		} else {
			try value.encode(to: self)
		}
		return result
	}
    
    func encodeData<T: Encodable>(_ value: T) throws -> RESPValue {
        switch context.nestedEncodingStrategy {
        case let .json(jsonEncoder):
            let jsonEncoder = jsonEncoder ?? {
                let encoder = JSONEncoder()
                encoder.outputFormatting = .sortedKeys
                encoder.dateEncodingStrategy = context.dateEncodingStrategy
                encoder.keyEncodingStrategy = context.keyEncodingStrategy
                return encoder
            }()
            return try jsonEncoder.encode(value).convertedToRESPValue()
        case let .custom(encode):
            return try encode(value, codingPath).convertedToRESPValue()
        }
    }
}

private struct RedisCommandSingleValueEncodingContainer: SingleValueEncodingContainer, UnkeyedEncodingContainer {

	var count: Int { 1 }
	let isSingle: Bool
	var codingPath: [CodingKey]
	var encoder: _RESPEncoder
	@Ref var result: RedisCommandEncoderValue

	mutating func encodeNil() throws {
        append(.single(.null))
	}

	mutating func encode(_ value: Bool) throws {
		append(encoder.context.boolEncodingStrategy.encode(value))
	}

	mutating func encode(_ value: String) throws { append(value) }
	mutating func encode(_ value: Double) throws { append(value) }
	mutating func encode(_ value: Float) throws { append(value) }
	mutating func encode(_ value: Int) throws { append(value) }
	mutating func encode(_ value: Int8) throws { append(value) }
    mutating func encode(_ value: Int16) throws { append(value) }
    mutating func encode(_ value: Int32) throws { append(value) }
    mutating func encode(_ value: Int64) throws { append(value) }
    mutating func encode(_ value: UInt) throws { append(value) }
    mutating func encode(_ value: UInt8) throws { append(value) }
    mutating func encode(_ value: UInt16) throws { append(value) }
    mutating func encode(_ value: UInt32) throws { append(value) }
    mutating func encode(_ value: UInt64) throws { append(value) }

	mutating func encode<T>(_ value: T) throws where T: Encodable {
		let new = try _RESPEncoder(
			path: nestedPath(),
			context: encoder.context
		)
		.encode(value)
		append(new)
	}

	mutating func nestedContainer<NestedKey>(keyedBy _: NestedKey.Type) -> KeyedEncodingContainer<NestedKey> where NestedKey: CodingKey {
		let new: RedisCommandEncoderValue = .keyed([])
		append(new)
		let lastIndex = result.unkeyed.count - 1
		let container = RedisCommandKeyedEncodingContainer<NestedKey>(
			codingPath: nestedPath(),
			encoder: encoder,
			result: Ref { [$result] in
				$result.wrappedValue.unkeyed[lastIndex].keyed
			} set: { [$result] newValue in
				$result.wrappedValue.unkeyed[lastIndex].keyed = newValue
			}
		)
		return KeyedEncodingContainer(container)
	}

	mutating func nestedUnkeyedContainer() -> UnkeyedEncodingContainer {
		let new = RedisCommandEncoderValue.unkeyed([])
		append(new)
		let lastIndex = result.unkeyed.count - 1
		return RedisCommandSingleValueEncodingContainer(
			isSingle: false,
			codingPath: nestedPath(),
			encoder: encoder,
			result: Ref { [$result] in
				$result.wrappedValue.unkeyed[lastIndex]
			} set: { [$result] newValue in
				$result.wrappedValue.unkeyed[lastIndex] = newValue
			}
		)
	}

	mutating func superEncoder() -> Encoder {
		if isSingle {
			return _RESPEncoder(path: codingPath, context: encoder.context, result: $result)
		} else {
			let new = RedisCommandEncoderValue.unkeyed([])
			append(new)
			let lastIndex = result.unkeyed.count - 1
			return _RESPEncoder(
				path: nestedPath(),
				context: encoder.context,
				result: Ref { [$result] in
					$result.wrappedValue.unkeyed[lastIndex]
				} set: { [$result] newValue in
					$result.wrappedValue.unkeyed[lastIndex] = newValue
				}
			)
		}
	}

	private func nestedPath() -> [CodingKey] {
		isSingle ? codingPath : codingPath + [PlainCodingKey(intValue: count)]
	}

    func append<T: RESPValueConvertible>(_ value: T) {
        append(.single(value.convertedToRESPValue()))
	}

	func append(_ value: RedisCommandEncoderValue) {
		if isSingle {
			result = value
		} else {
			result.unkeyed.append(value)
		}
	}
}

private struct RedisCommandKeyedEncodingContainer<Key: CodingKey>: KeyedEncodingContainerProtocol {

	var codingPath: [CodingKey]
	var encoder: _RESPEncoder

	@Ref var result: [(String, RedisCommandEncoderValue)]

	@inline(__always)
	private func str(_ key: Key) -> String {
		encoder.context.keyEncodingStrategy.encode(key, path: codingPath)
	}

	mutating func encodeNil(forKey key: Key) throws {
        append(.single(.null), forKey: key)
	}

	mutating func encode(_ value: Bool, forKey key: Key) throws {
		append(encoder.context.boolEncodingStrategy.encode(value), forKey: key)
	}

    mutating func encodeIfPresent(_ value: Bool?, forKey key: Key) throws {
        append(value.map(encoder.context.boolEncodingStrategy.encode), forKey: key)
    }
    
	mutating func encode(_ value: String, forKey key: Key) throws { append(value, forKey: key) }
    mutating func encodeIfPresent(_ value: String?, forKey key: Key) throws { append(value, forKey: key) }
    mutating func encode(_ value: Double, forKey key: Key) throws { append(value, forKey: key) }
    mutating func encodeIfPresent(_ value: Double?, forKey key: Key) throws { append(value, forKey: key) }
    mutating func encode(_ value: Float, forKey key: Key) throws { append(value, forKey: key) }
    mutating func encodeIfPresent(_ value: Float?, forKey key: Key) throws { append(value, forKey: key) }
    mutating func encode(_ value: Int, forKey key: Key) throws { append(value, forKey: key) }
    mutating func encodeIfPresent(_ value: Int?, forKey key: Key) throws { append(value, forKey: key) }
    mutating func encode(_ value: Int8, forKey key: Key) throws { append(value, forKey: key) }
    mutating func encodeIfPresent(_ value: Int8?, forKey key: Key) throws { append(value, forKey: key) }
    mutating func encode(_ value: Int16, forKey key: Key) throws { append(value, forKey: key) }
    mutating func encodeIfPresent(_ value: Int16?, forKey key: Key) throws { append(value, forKey: key) }
    mutating func encode(_ value: Int32, forKey key: Key) throws { append(value, forKey: key) }
    mutating func encodeIfPresent(_ value: Int32?, forKey key: Key) throws { append(value, forKey: key) }
    mutating func encode(_ value: Int64, forKey key: Key) throws { append(value, forKey: key) }
    mutating func encodeIfPresent(_ value: Int64?, forKey key: Key) throws { append(value, forKey: key) }
    mutating func encode(_ value: UInt, forKey key: Key) throws { append(value, forKey: key) }
    mutating func encodeIfPresent(_ value: UInt?, forKey key: Key) throws { append(value, forKey: key) }
    mutating func encode(_ value: UInt8, forKey key: Key) throws { append(value, forKey: key) }
    mutating func encodeIfPresent(_ value: UInt8?, forKey key: Key) throws { append(value, forKey: key) }
    mutating func encode(_ value: UInt16, forKey key: Key) throws { append(value, forKey: key) }
    mutating func encodeIfPresent(_ value: UInt16?, forKey key: Key) throws { append(value, forKey: key) }
    mutating func encode(_ value: UInt32, forKey key: Key) throws { append(value, forKey: key) }
    mutating func encodeIfPresent(_ value: UInt32?, forKey key: Key) throws { append(value, forKey: key) }
    mutating func encode(_ value: UInt64, forKey key: Key) throws { append(value, forKey: key) }
    mutating func encodeIfPresent(_ value: UInt64?, forKey key: Key) throws { append(value, forKey: key) }

	mutating func encodeIfPresent(_ value: (some Encodable)?, forKey key: Key) throws {
		guard let value else {
            if encoder.context.encodeNullIfNotPresented {
                append(.single(.null), forKey: key)
            }
			return
		}
		try encode(value, forKey: key)
	}

	mutating func encode<T>(_ value: T, forKey key: Key) throws where T: Encodable {
		let encoder = _RESPEncoder(
			path: nestedPath(for: key),
			context: encoder.context
		)
		try append(encoder.encode(value), forKey: key)
	}

	mutating func nestedContainer<NestedKey: CodingKey>(keyedBy _: NestedKey.Type, forKey key: Key) -> KeyedEncodingContainer<NestedKey> {
		let new: RedisCommandEncoderValue = .keyed([])
		let index = result.count
		append(new, forKey: key)
		let container = RedisCommandKeyedEncodingContainer<NestedKey>(
			codingPath: nestedPath(for: key),
			encoder: encoder,
			result: Ref { [$result] in
				$result.wrappedValue[index].1.keyed
			} set: { [$result] in
				$result.wrappedValue[index].1.keyed = $0
			}
		)
		return KeyedEncodingContainer(container)
	}

	mutating func nestedUnkeyedContainer(forKey key: Key) -> UnkeyedEncodingContainer {
		let new: RedisCommandEncoderValue = .unkeyed([])
		let index = result.count
		append(new, forKey: key)
		let container = RedisCommandSingleValueEncodingContainer(
			isSingle: false,
			codingPath: nestedPath(for: key),
			encoder: encoder,
			result: Ref { [$result] in
				$result.wrappedValue[index].1
			} set: { [$result] in
				$result.wrappedValue[index].1 = $0
			}
		)
		return container
	}

	mutating func superEncoder() -> Encoder {
		encoder
	}

	mutating func superEncoder(forKey key: Key) -> Encoder {
		let new: RedisCommandEncoderValue = .unkeyed([])
		let index = result.count
		append(new, forKey: key)
		return _RESPEncoder(
			path: nestedPath(for: key),
			context: encoder.context,
			result: Ref { [$result] in
				$result.wrappedValue[index].1
			} set: { [$result] in
				$result.wrappedValue[index].1 = $0
			}
		)
	}

	private func nestedPath(for key: Key) -> [CodingKey] {
		codingPath + [key]
	}

	@inline(__always)
    private mutating func append<T: RESPValueConvertible>(_ value: T?, forKey key: Key) {
        if let value {
            append(.single(value.convertedToRESPValue()), forKey: key)
        } else if encoder.context.encodeNullIfNotPresented {
            append(.single(.null), forKey: key)
        }
	}

	@inline(__always)
	private mutating func append(_ value: RedisCommandEncoderValue, forKey key: Key) {
		result.append((str(key), value))
	}
}

extension JSONEncoder.KeyEncodingStrategy {

	func encode(_ key: CodingKey, path: [CodingKey]) -> String {
		switch self {
		case .useDefaultKeys:
			return key.stringValue
		case .convertToSnakeCase:
			return key.stringValue.convertToSnakeCase()
		case let .custom(closure):
			return closure(path + [key]).stringValue
		@unknown default:
			return key.stringValue
		}
	}
}

extension JSONEncoder.DateEncodingStrategy {

	func encode(_ date: Date, encoder: Encoder) throws {
		switch self {
		case .deferredToDate:
			try date.encode(to: encoder)
		case .secondsSince1970:
			try date.timeIntervalSince1970.encode(to: encoder)
		case .millisecondsSince1970:
			try (date.timeIntervalSince1970 * 1000).encode(to: encoder)
		case .iso8601:
			try _iso8601Formatter.string(from: date).encode(to: encoder)
		case let .formatted(formatter):
			try formatter.string(from: date).encode(to: encoder)
		case let .custom(closure):
			try closure(date, encoder)
		@unknown default:
			try date.timeIntervalSince1970.encode(to: encoder)
		}
	}
}

extension String {

	func convertToSnakeCase() -> String {
		var result = ""
		for (i, char) in enumerated() {
			if char.isUppercase {
				if i != 0 {
					result.append("_")
				}
				result.append(char.lowercased())
			} else {
				result.append(char)
			}
		}
		return result
	}
}

@available(macOS 10.12, iOS 10.0, watchOS 3.0, tvOS 10.0, *)
private let _iso8601Formatter: ISO8601DateFormatter = {
	let formatter = ISO8601DateFormatter()
	formatter.formatOptions = .withInternetDateTime
	return formatter
}()

private final class IsArrayEncoder: Encoder {

	var isArray: Bool?
	var isSingle: Bool?
	var codingPath: [CodingKey] = []
	var userInfo: [CodingUserInfoKey: Any] = [:]

	init(codingPath: [CodingKey] = []) {
		self.codingPath = codingPath
	}

	func container<Key>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> where Key: CodingKey {
		if isArray == nil {
			isArray = false
		}
		if isSingle == nil {
			isSingle = false
		}
		return KeyedEncodingContainer(MockKeyed())
	}

	func unkeyedContainer() -> UnkeyedEncodingContainer {
		if isArray == nil {
			isArray = true
		}
		if isSingle == nil {
			isSingle = false
		}
		return MockUnkeyed()
	}

	func singleValueContainer() -> SingleValueEncodingContainer {
		MockSingle(encoder: self, codingPath: codingPath)
	}

	private struct MockKeyed<Key: CodingKey>: KeyedEncodingContainerProtocol {
		var codingPath: [CodingKey] = []
		mutating func encodeNil(forKey key: Key) throws { throw MockError() }
		mutating func encode(_ value: Bool, forKey key: Key) throws { throw MockError() }
		mutating func encode(_ value: String, forKey key: Key) throws { throw MockError() }
		mutating func encode(_ value: Double, forKey key: Key) throws { throw MockError() }
		mutating func encode(_ value: Float, forKey key: Key) throws { throw MockError() }
		mutating func encode(_ value: Int, forKey key: Key) throws { throw MockError() }
		mutating func encode(_ value: Int8, forKey key: Key) throws { throw MockError() }
		mutating func encode(_ value: Int16, forKey key: Key) throws { throw MockError() }
		mutating func encode(_ value: Int32, forKey key: Key) throws { throw MockError() }
		mutating func encode(_ value: Int64, forKey key: Key) throws { throw MockError() }
		mutating func encode(_ value: UInt, forKey key: Key) throws { throw MockError() }
		mutating func encode(_ value: UInt8, forKey key: Key) throws { throw MockError() }
		mutating func encode(_ value: UInt16, forKey key: Key) throws { throw MockError() }
		mutating func encode(_ value: UInt32, forKey key: Key) throws { throw MockError() }
		mutating func encode(_ value: UInt64, forKey key: Key) throws { throw MockError() }
		mutating func encode<T>(_ value: T, forKey key: Key) throws where T: Encodable { throw MockError() }
		mutating func nestedContainer<NestedKey: CodingKey>(keyedBy keyType: NestedKey.Type, forKey key: Key) -> KeyedEncodingContainer<NestedKey> { KeyedEncodingContainer(MockKeyed<NestedKey>()) }
		mutating func nestedUnkeyedContainer(forKey key: Key) -> any UnkeyedEncodingContainer { MockUnkeyed() }
		mutating func superEncoder() -> Encoder { IsArrayEncoder() }
		mutating func superEncoder(forKey key: Key) -> Encoder { IsArrayEncoder() }
	}

	private struct MockUnkeyed: UnkeyedEncodingContainer {

		var codingPath: [CodingKey] = []
		var count = 0

		mutating func encodeNil() throws { throw MockError() }
		mutating func encode(_ value: Bool) throws { throw MockError() }
		mutating func encode(_ value: String) throws { throw MockError() }
		mutating func encode(_ value: Double) throws { throw MockError() }
		mutating func encode(_ value: Float) throws { throw MockError() }
		mutating func encode(_ value: Int) throws { throw MockError() }
		mutating func encode(_ value: Int8) throws { throw MockError() }
		mutating func encode(_ value: Int16) throws { throw MockError() }
		mutating func encode(_ value: Int32) throws { throw MockError() }
		mutating func encode(_ value: Int64) throws { throw MockError() }
		mutating func encode(_ value: UInt) throws { throw MockError() }
		mutating func encode(_ value: UInt8) throws { throw MockError() }
		mutating func encode(_ value: UInt16) throws { throw MockError() }
		mutating func encode(_ value: UInt32) throws { throw MockError() }
		mutating func encode(_ value: UInt64) throws { throw MockError() }
		mutating func encode<T>(_ value: T) throws where T: Encodable { throw MockError() }
		mutating func nestedContainer<NestedKey: CodingKey>(keyedBy keyType: NestedKey.Type) -> KeyedEncodingContainer<NestedKey> { KeyedEncodingContainer(MockKeyed<NestedKey>()) }
		mutating func nestedUnkeyedContainer() -> any UnkeyedEncodingContainer { MockUnkeyed() }
		mutating func superEncoder() -> Encoder { IsArrayEncoder() }
	}

	private struct MockSingle: SingleValueEncodingContainer {

		let encoder: IsArrayEncoder
		var codingPath: [CodingKey] = []

		mutating func encodeNil() throws { try throwError() }
		mutating func encode(_ value: Bool) throws { try throwError() }
		mutating func encode(_ value: String) throws { try throwError() }
		mutating func encode(_ value: Double) throws { try throwError() }
		mutating func encode(_ value: Float) throws { try throwError() }
		mutating func encode(_ value: Int) throws { try throwError() }
		mutating func encode(_ value: Int8) throws { try throwError() }
		mutating func encode(_ value: Int16) throws { try throwError() }
		mutating func encode(_ value: Int32) throws { try throwError() }
		mutating func encode(_ value: Int64) throws { try throwError() }
		mutating func encode(_ value: UInt) throws { try throwError() }
		mutating func encode(_ value: UInt8) throws { try throwError() }
		mutating func encode(_ value: UInt16) throws { try throwError() }
		mutating func encode(_ value: UInt32) throws { try throwError() }
		mutating func encode(_ value: UInt64) throws { try throwError() }
		mutating func encode<T>(_ value: T) throws where T: Encodable { try value.encode(to: encoder) }
		private func throwError() throws {
			if encoder.isArray == nil {
				encoder.isArray = false
			}
			if encoder.isSingle == nil {
				encoder.isSingle = true
			}
			throw MockError()
		}
	}
}

private struct MockError: Error {}
