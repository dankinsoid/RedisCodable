import Foundation
import RediStack
import NIOCore

public struct RESPDecoder {
    
    public let dateDecodingStrategy: JSONDecoder.DateDecodingStrategy
    public var nestedDecodingStrategy: NestedDecodingStrategy
    public var keyDecodingStrategy: JSONDecoder.KeyDecodingStrategy
    public var boolDecodingStrategy: BoolDecodingStrategy
    
    public init(
        dateDecodingStrategy: JSONDecoder.DateDecodingStrategy = .deferredToDate,
        nestedDecodingStrategy: NestedDecodingStrategy = .json,
        keyDecodingStrategy: JSONDecoder.KeyDecodingStrategy = .useDefaultKeys,
        boolDecodingStrategy: BoolDecodingStrategy = .default
    ) {
        self.dateDecodingStrategy = dateDecodingStrategy
        self.nestedDecodingStrategy = nestedDecodingStrategy
        self.keyDecodingStrategy = keyDecodingStrategy
        self.boolDecodingStrategy = boolDecodingStrategy
    }
    
    public func decode<T: Decodable>(_ type: T.Type, from respValue: RESPValue) throws -> T {
        try _RESPDecoder(from: respValue, config: self).decode(type)
    }

    public func decodeHash<T: Decodable>(_ type: T.Type, from hash: [String: RESPValue]) throws -> T {
        try T(from: _RESPDecoder(from: .null, hash: hash, config: self))
    }

    public struct BoolDecodingStrategy {
        
        private let _decode: (RESPValue, [CodingKey]) throws -> Bool
        
        public static func custom(_ decode: @escaping (_ value: RESPValue, [CodingKey]) throws -> Bool) -> Self {
            BoolDecodingStrategy(_decode: decode)
        }
    
        public static func string(_ encode: @escaping (_ value: String, [CodingKey]) throws -> Bool) -> Self {
            .custom {
                guard let string = $0.string else {
                    throw DecodingError.typeMismatch(String.self, DecodingError.Context(codingPath: $1, debugDescription: "Expected a string"))
                }
                return try encode(string, $1)
            }
        }

        /// Encode booleans as "true" and "false"
        public static var `default`: Self {
            string {
                switch $0.lowercased() {
                case "true": return true
                case "false": return false
                default: throw DecodingError.dataCorrupted(
                    DecodingError.Context(codingPath: $1, debugDescription: "Invalid boolean string \"\($0)\"")
                )
                }
            }
        }

        /// Encode booleans as 1 and 0
        public static var number: Self {
            .custom {
                guard let number = $0.int else {
                    throw DecodingError.typeMismatch(Int.self, DecodingError.Context(codingPath: $1, debugDescription: "Expected an integer"))
                }
                switch number {
                case 0: return false
                case 1: return true
                default: throw DecodingError.dataCorrupted(
                    DecodingError.Context(codingPath: $1, debugDescription: "Invalid boolean number \"\(number)\"")
                )
                }
            }
        }

        public func decode(_ value: RESPValue, codingPath: [CodingKey]) throws -> Bool {
            try _decode(value, codingPath)
        }
    }
    
    public enum NestedDecodingStrategy {
    
        case json(JSONDecoder?)
        case custom((Data, [CodingKey]) throws -> Decodable)
    
        public static var json: NestedDecodingStrategy { .json(nil) }
        public static var `throw`: NestedDecodingStrategy {
            .custom { value, path in
                throw EncodingError.invalidValue(
                    value,
                    EncodingError.Context(codingPath: path, debugDescription: "Doesn't support nested values")
                )
            }
        }
    }
}

private final class _RESPDecoder: Decoder {
    
    let config: RESPDecoder
    var codingPath: [CodingKey]
    var userInfo: [CodingUserInfoKey : Any] = [:]
    var storage: _RESPDecodingStorage
    var hash: [String: RESPValue]?

    init(from value: RESPValue, hash: [String: RESPValue]? = nil, codingPath: [CodingKey] = [], config: RESPDecoder) {
        self.codingPath = codingPath
        self.hash = hash
        self.storage = _RESPDecodingStorage()
        self.config = config
        self.storage.push(container: value)
    }

    func container<Key>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> where Key : CodingKey {
        guard let hash else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: codingPath, debugDescription: "Cannot decode keyed container")
            )
        }

        let keyedContainer = RESPKeyedDecodingContainer<Key>(referencing: self, wrapping: hash)
        return KeyedDecodingContainer(keyedContainer)
    }

    func unkeyedContainer() throws -> UnkeyedDecodingContainer {
        guard case let .array(array) = try storage.topContainer else {
            throw DecodingError.typeMismatch([RESPValue].self, DecodingError.Context(codingPath: codingPath, debugDescription: "Expected an array"))
        }

        return RESPUnkeyedDecodingContainer(referencing: self, wrapping: array)
    }
    
    func singleValueContainer() throws -> SingleValueDecodingContainer {
        return RESPSingleValueDecodingContainer(referencing: self)
    }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        guard hash == nil else {
            return try T(from: self)
        }
        let respValue = try storage.topContainer
        if let convertible = T.self as? RESPValueConvertible.Type {
            guard let value = convertible.init(fromRESP: respValue) as? T else {
                throw DecodingError.typeMismatch(T.self, DecodingError.Context(codingPath: [], debugDescription: "Expected \(T.self)"))
            }
            return value
        }
    
        let isKeyedDecoder = IsKeyedDecoder()
        _ = try? T(from: isKeyedDecoder)
        if isKeyedDecoder.isKeyed == true {
            guard let data = respValue.data else {
                throw DecodingError.typeMismatch(Data.self, DecodingError.Context(codingPath: [], debugDescription: "Expected a data"))
            }
            switch config.nestedDecodingStrategy {
            case let .json(decoder):
                let decoder = decoder ?? {
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = config.dateDecodingStrategy
                    decoder.keyDecodingStrategy = config.keyDecodingStrategy
                    return decoder
                }()
                return try decoder.decode(T.self, from: data)
            case let .custom(decode):
                let value = try decode(data, [])
                guard let result = value as? T else {
                    throw DecodingError.typeMismatch(T.self, DecodingError.Context(codingPath: [], debugDescription: "Expected \(T.self)"))
                }
                return result
            }
        } else {
            return try T(from: self)
        }
    }
}

private struct _RESPDecodingStorage {

    private var containers: [RESPValue] = []
    
    mutating func push(container: RESPValue) {
        containers.append(container)
    }

    mutating func popContainer() -> RESPValue {
        return containers.removeLast()
    }

    var topContainer: RESPValue {
        get throws {
            guard let container = containers.last else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(codingPath: [], debugDescription: "Empty container stack.")
                )
            }
            return container
        }
    }
}

private struct RESPKeyedDecodingContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {

    private let decoder: _RESPDecoder
    private let container: [String: RESPValue]
    
    init(referencing decoder: _RESPDecoder, wrapping container: [String: RESPValue]) {
        self.decoder = decoder
        self.container = container
    }
    
    var codingPath: [CodingKey] { decoder.codingPath }

    var allKeys: [Key] {
        container.keys.compactMap { Key(stringValue: $0) }
    }
    
    func contains(_ key: Key) -> Bool {
        container[key.stringValue] != nil
    }
    
    func decodeNil(forKey key: Key) throws -> Bool {
        return container[key.stringValue]?.isNull == true
    }
    
    func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool {
        return try decoder.config.boolDecodingStrategy.decode(
            container[key.stringValue] ?? .null,
            codingPath: codingPath + [key]
        )
    }

    func decode(_ type: String.Type, forKey key: Key) throws -> String {
        return try decodeValue(forKey: key, as: String.self)
    }
    
    func decode(_ type: Double.Type, forKey key: Key) throws -> Double {
        return try decodeValue(forKey: key, as: Double.self)
    }
    
    func decode(_ type: Float.Type, forKey key: Key) throws -> Float {
        return try decodeValue(forKey: key, as: Float.self)
    }
    
    func decode(_ type: Int.Type, forKey key: Key) throws -> Int {
        return try decodeValue(forKey: key, as: Int.self)
    }
    
    func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 {
        return try decodeValue(forKey: key, as: Int8.self)
    }
    
    func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 {
        return try decodeValue(forKey: key, as: Int16.self)
    }
    
    func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 {
        return try decodeValue(forKey: key, as: Int32.self)
    }
    
    func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 {
        return try decodeValue(forKey: key, as: Int64.self)
    }
    
    func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt {
        return try decodeValue(forKey: key, as: UInt.self)
    }
    
    func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 {
        return try decodeValue(forKey: key, as: UInt8.self)
    }
    
    func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 {
        return try decodeValue(forKey: key, as: UInt16.self)
    }
    
    func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 {
        return try decodeValue(forKey: key, as: UInt32.self)
    }
    
    func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 {
        return try decodeValue(forKey: key, as: UInt64.self)
    }
    
    func decode<T>(_ type: T.Type, forKey key: Key) throws -> T where T : Decodable {
        let value = try require(key: key)
        let decoder = _RESPDecoder(from: value, codingPath: codingPath + [key], config: decoder.config)
        return try decoder.decode(type)
    }
    
    private func decodeValue<T: RESPValueConvertible>(forKey key: Key, as type: T.Type) throws -> T {
        let value = try require(key: key)
        guard let result = T(fromRESP: value) else {
            throw DecodingError.typeMismatch(T.self, DecodingError.Context(codingPath: codingPath + [key], debugDescription: "Expected value of type \(T.self)"))
        }
        return result
    }

    func nestedContainer<NestedKey>(keyedBy type: NestedKey.Type, forKey key: Key) throws -> KeyedDecodingContainer<NestedKey> where NestedKey: CodingKey {
        throw DecodingError.dataCorrupted(
            DecodingError.Context(codingPath: codingPath + [key], debugDescription: "Cannot decode nested keyed container")
        )
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> any UnkeyedDecodingContainer {
        let value = try require(key: key)
        guard case let .array(nestedArray) = value else {
            throw DecodingError.typeMismatch([RESPValue].self, DecodingError.Context(codingPath: codingPath + [key], debugDescription: "Expected a nested array"))
        }
        return RESPUnkeyedDecodingContainer(referencing: decoder, wrapping: nestedArray)
    }
    
    func superDecoder() throws -> any Decoder {
        return decoder
    }
    
    func superDecoder(forKey key: Key) throws -> any Decoder {
        let value = try require(key: key)
        return _RESPDecoder(from: value, codingPath: codingPath + [key], config: decoder.config)
    }

    private func require(key: Key) throws -> RESPValue {
        guard let value = container[key.stringValue] else {
            throw DecodingError.keyNotFound(key, DecodingError.Context(codingPath: codingPath, debugDescription: "No value associated with key \(key)"))
        }
        return value
    }
}

private struct RESPUnkeyedDecodingContainer: UnkeyedDecodingContainer {

    private let decoder: _RESPDecoder
    private let container: [RESPValue]
    var currentIndex: Int
    
    init(referencing decoder: _RESPDecoder, wrapping container: [RESPValue]) {
        self.decoder = decoder
        self.container = container
        self.currentIndex = 0
    }
    
    var codingPath: [CodingKey] { decoder.codingPath }
    var count: Int? { container.count }
    var isAtEnd: Bool { currentIndex >= count! }
    private var nestedPath: [CodingKey] { codingPath + [PlainCodingKey(intValue: currentIndex)] }
    
    mutating func decodeNil() throws -> Bool {
        guard !isAtEnd else { throw DecodingError.valueNotFound(Any?.self, DecodingError.Context(codingPath: nestedPath, debugDescription: "Unkeyed container is at end.")) }
        if container[currentIndex].isNull {
            currentIndex += 1
            return true
        } else {
            return false
        }
    }
    
    mutating func decode(_ type: Bool.Type) throws -> Bool {
        guard !isAtEnd else { throw DecodingError.valueNotFound(Any?.self, DecodingError.Context(codingPath: nestedPath, debugDescription: "Unkeyed container is at end.")) }
        return try decoder.config.boolDecodingStrategy.decode(
            container[currentIndex],
            codingPath: nestedPath
        )
    }

    mutating func decode(_ type: String.Type) throws -> String {
        return try decodeValue(as: String.self)
    }
    
    mutating func decode(_ type: Double.Type) throws -> Double {
        return try decodeValue(as: Double.self)
    }
    
    mutating func decode(_ type: Float.Type) throws -> Float {
        return try decodeValue(as: Float.self)
    }
    
    mutating func decode(_ type: Int.Type) throws -> Int {
        return try decodeValue(as: Int.self)
    }
    
    mutating func decode(_ type: Int8.Type) throws -> Int8 {
        return try decodeValue(as: Int8.self)
    }
    
    mutating func decode(_ type: Int16.Type) throws -> Int16 {
        return try decodeValue(as: Int16.self)
    }
    
    mutating func decode(_ type: Int32.Type) throws -> Int32 {
        return try decodeValue(as: Int32.self)
    }
    
    mutating func decode(_ type: Int64.Type) throws -> Int64 {
        return try decodeValue(as: Int64.self)
    }
    
    mutating func decode(_ type: UInt.Type) throws -> UInt {
        return try decodeValue(as: UInt.self)
    }
    
    mutating func decode(_ type: UInt8.Type) throws -> UInt8 {
        return try decodeValue(as: UInt8.self)
    }
    
    mutating func decode(_ type: UInt16.Type) throws -> UInt16 {
        return try decodeValue(as: UInt16.self)
    }
    
    mutating func decode(_ type: UInt32.Type) throws -> UInt32 {
        return try decodeValue(as: UInt32.self)
    }
    
    mutating func decode(_ type: UInt64.Type) throws -> UInt64 {
        return try decodeValue(as: UInt64.self)
    }
    
    mutating func decode<T>(_ type: T.Type) throws -> T where T : Decodable {
        guard !isAtEnd else { throw DecodingError.valueNotFound(T.self, DecodingError.Context(codingPath: nestedPath, debugDescription: "Unkeyed container is at end.")) }
        let value = container[currentIndex]
        let decoder = _RESPDecoder(from: value, codingPath: nestedPath, config: decoder.config)
        currentIndex += 1
        return try decoder.decode(type)
    }

    mutating func nestedContainer<NestedKey>(keyedBy type: NestedKey.Type) throws -> KeyedDecodingContainer<NestedKey> where NestedKey: CodingKey {
        throw DecodingError.dataCorrupted(
            DecodingError.Context(codingPath: nestedPath, debugDescription: "Cannot decode nested keyed container")
        )
    }

    mutating func nestedUnkeyedContainer() throws -> any UnkeyedDecodingContainer {
        guard !isAtEnd else { throw DecodingError.valueNotFound([Any].self, DecodingError.Context(codingPath: nestedPath, debugDescription: "Unkeyed container is at end.")) }
        let value = container[currentIndex]
        guard case let .array(nestedArray) = value else {
            throw DecodingError.typeMismatch([RESPValue].self, DecodingError.Context(codingPath: nestedPath, debugDescription: "Expected a nested array"))
        }
        return RESPUnkeyedDecodingContainer(referencing: decoder, wrapping: nestedArray)
    }
    
    mutating func superDecoder() throws -> any Decoder {
        return _RESPDecoder(from: container[currentIndex], codingPath: codingPath, config: decoder.config)
    }

    private mutating func decodeValue<T: RESPValueConvertible>(as type: T.Type) throws -> T {
        guard !isAtEnd else { throw DecodingError.valueNotFound(T.self, DecodingError.Context(codingPath: nestedPath, debugDescription: "Unkeyed container is at end.")) }
        let value = container[currentIndex]
        defer { currentIndex += 1 }
        guard let result = T(fromRESP: value) else {
            throw DecodingError.typeMismatch(T.self, DecodingError.Context(codingPath: nestedPath, debugDescription: "Expected value of type \(T.self)"))
        }
        return result
    }
}

private struct RESPSingleValueDecodingContainer: SingleValueDecodingContainer {
    
    private let decoder: _RESPDecoder
    
    init(referencing decoder: _RESPDecoder) {
        self.decoder = decoder
    }
    
    var codingPath: [CodingKey] { decoder.codingPath }
    
    func decodeNil() -> Bool {
        return (try? decoder.storage.topContainer.isNull) ?? false
    }

    func decode(_ type: Bool.Type) throws -> Bool {
        return try decoder.config.boolDecodingStrategy.decode(
            try decoder.storage.topContainer,
            codingPath: codingPath
        )
    }

    func decode(_ type: String.Type) throws -> String {
        return try decodeValue(as: String.self)
    }
    
    func decode(_ type: Double.Type) throws -> Double {
        return try decodeValue(as: Double.self)
    }
    
    func decode(_ type: Float.Type) throws -> Float {
        return try decodeValue(as: Float.self)
    }
    
    func decode(_ type: Int.Type) throws -> Int {
        return try decodeValue(as: Int.self)
    }
    
    func decode(_ type: Int8.Type) throws -> Int8 {
        return try decodeValue(as: Int8.self)
    }
    
    func decode(_ type: Int16.Type) throws -> Int16 {
        return try decodeValue(as: Int16.self)
    }
    
    func decode(_ type: Int32.Type) throws -> Int32 {
        return try decodeValue(as: Int32.self)
    }
    
    func decode(_ type: Int64.Type) throws -> Int64 {
        return try decodeValue(as: Int64.self)
    }
    
    func decode(_ type: UInt.Type) throws -> UInt {
        return try decodeValue(as: UInt.self)
    }
    
    func decode(_ type: UInt8.Type) throws -> UInt8 {
        return try decodeValue(as: UInt8.self)
    }
    
    func decode(_ type: UInt16.Type) throws -> UInt16 {
        return try decodeValue(as: UInt16.self)
    }
    
    func decode(_ type: UInt32.Type) throws -> UInt32 {
        return try decodeValue(as: UInt32.self)
    }
    
    func decode(_ type: UInt64.Type) throws -> UInt64 {
        return try decodeValue(as: UInt64.self)
    }
    
    func decode<T>(_ type: T.Type) throws -> T where T : Decodable {
        try decoder.decode(type)
    }

    private func decodeValue<T: RESPValueConvertible>(as type: T.Type) throws -> T {
        guard let result = try T(fromRESP: decoder.storage.topContainer) else {
            throw DecodingError.typeMismatch(T.self, DecodingError.Context(codingPath: codingPath, debugDescription: "Expected value of type \(T.self)"))
        }
        return result
    }
}

private final class IsKeyedDecoder: Decoder {
    
    var isKeyed: Bool?
    var isSingle: Bool?
    var codingPath: [CodingKey] = []
    var userInfo: [CodingUserInfoKey: Any] = [:]
    
    init(codingPath: [CodingKey] = []) {
        self.codingPath = codingPath
    }
    
    func container<Key>(keyedBy type: Key.Type) -> KeyedDecodingContainer<Key> where Key: CodingKey {
        if isKeyed == nil {
            isKeyed = true
        }
        if isSingle == nil {
            isSingle = false
        }
        return KeyedDecodingContainer(MockKeyed())
    }
    
    func unkeyedContainer() -> UnkeyedDecodingContainer {
        if isKeyed == nil {
            isKeyed = false
        }
        if isSingle == nil {
            isSingle = false
        }
        return MockUnkeyed()
    }
    
    func singleValueContainer() -> SingleValueDecodingContainer {
        return MockSingle(decoder: self, codingPath: codingPath)
    }
    
    private struct MockKeyed<Key: CodingKey>: KeyedDecodingContainerProtocol {
        var codingPath: [CodingKey] = []
        var allKeys: [Key] { return [] }
        
        func contains(_ key: Key) -> Bool { return false }
        func decodeNil(forKey key: Key) throws -> Bool { throw MockError() }
        func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool { throw MockError() }
        func decode(_ type: String.Type, forKey key: Key) throws -> String { throw MockError() }
        func decode(_ type: Double.Type, forKey key: Key) throws -> Double { throw MockError() }
        func decode(_ type: Float.Type, forKey key: Key) throws -> Float { throw MockError() }
        func decode(_ type: Int.Type, forKey key: Key) throws -> Int { throw MockError() }
        func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 { throw MockError() }
        func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 { throw MockError() }
        func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 { throw MockError() }
        func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 { throw MockError() }
        func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt { throw MockError() }
        func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 { throw MockError() }
        func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 { throw MockError() }
        func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 { throw MockError() }
        func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 { throw MockError() }
        func decode<T>(_ type: T.Type, forKey key: Key) throws -> T where T : Decodable { throw MockError() }
        func nestedContainer<NestedKey>(keyedBy type: NestedKey.Type, forKey key: Key) throws -> KeyedDecodingContainer<NestedKey> { throw MockError() }
        func nestedUnkeyedContainer(forKey key: Key) throws -> UnkeyedDecodingContainer { throw MockError() }
        func superDecoder() throws -> Decoder { throw MockError() }
        func superDecoder(forKey key: Key) throws -> Decoder { throw MockError() }
    }
    
    private struct MockUnkeyed: UnkeyedDecodingContainer {
        
        var codingPath: [CodingKey] = []
        var count: Int? = 0
        var isAtEnd: Bool { return true }
        var currentIndex: Int = 0
        
        mutating func decodeNil() throws -> Bool { throw MockError() }
        mutating func decode(_ type: Bool.Type) throws -> Bool { throw MockError() }
        mutating func decode(_ type: String.Type) throws -> String { throw MockError() }
        mutating func decode(_ type: Double.Type) throws -> Double { throw MockError() }
        mutating func decode(_ type: Float.Type) throws -> Float { throw MockError() }
        mutating func decode(_ type: Int.Type) throws -> Int { throw MockError() }
        mutating func decode(_ type: Int8.Type) throws -> Int8 { throw MockError() }
        mutating func decode(_ type: Int16.Type) throws -> Int16 { throw MockError() }
        mutating func decode(_ type: Int32.Type) throws -> Int32 { throw MockError() }
        mutating func decode(_ type: Int64.Type) throws -> Int64 { throw MockError() }
        mutating func decode(_ type: UInt.Type) throws -> UInt { throw MockError() }
        mutating func decode(_ type: UInt8.Type) throws -> UInt8 { throw MockError() }
        mutating func decode(_ type: UInt16.Type) throws -> UInt16 { throw MockError() }
        mutating func decode(_ type: UInt32.Type) throws -> UInt32 { throw MockError() }
        mutating func decode(_ type: UInt64.Type) throws -> UInt64 { throw MockError() }
        mutating func decode<T>(_ type: T.Type) throws -> T where T : Decodable { throw MockError() }
        mutating func nestedContainer<NestedKey>(keyedBy type: NestedKey.Type) throws -> KeyedDecodingContainer<NestedKey> { throw MockError() }
        mutating func nestedUnkeyedContainer() throws -> UnkeyedDecodingContainer { throw MockError() }
        mutating func superDecoder() throws -> Decoder { throw MockError() }
    }
    
    private struct MockSingle: SingleValueDecodingContainer {
        
        let decoder: IsKeyedDecoder
        var codingPath: [CodingKey] = []
    
        func decodeNil() -> Bool { return false }
        func decode(_ type: Bool.Type) throws -> Bool { try throwError() }
        func decode(_ type: String.Type) throws -> String { try throwError() }
        func decode(_ type: Double.Type) throws -> Double { try throwError() }
        func decode(_ type: Float.Type) throws -> Float { try throwError() }
        func decode(_ type: Int.Type) throws -> Int { try throwError() }
        func decode(_ type: Int8.Type) throws -> Int8 { try throwError() }
        func decode(_ type: Int16.Type) throws -> Int16 { try throwError() }
        func decode(_ type: Int32.Type) throws -> Int32 { try throwError() }
        func decode(_ type: Int64.Type) throws -> Int64 { try throwError() }
        func decode(_ type: UInt.Type) throws -> UInt { try throwError() }
        func decode(_ type: UInt8.Type) throws -> UInt8 { try throwError() }
        func decode(_ type: UInt16.Type) throws -> UInt16 { try throwError() }
        func decode(_ type: UInt32.Type) throws -> UInt32 { try throwError() }
        func decode(_ type: UInt64.Type) throws -> UInt64 { try throwError() }
        func decode<T>(_ type: T.Type) throws -> T where T : Decodable { try throwError() }
    
        private func throwError<T>() throws -> T {
            if decoder.isKeyed == nil {
                decoder.isKeyed = false
            }
            if decoder.isSingle == nil {
                decoder.isSingle = true
            }
            throw MockError()
        }
    }
}

private struct MockError: Error {}
