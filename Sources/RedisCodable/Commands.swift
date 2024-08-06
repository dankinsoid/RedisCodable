//import Foundation
//import RediStack
//
//public extension RedisCommandSignature {
//
//    func map<T>(_ transform: @escaping (Value) throws -> T) -> some RedisCommandSignature<T> {
//        AnyRedisCommandSignature(commands: commands) { value in
//            try transform(makeResponse(from: value))
//        }
//    }
//
//    func any() -> some RedisCommandSignature<RESPValue> {
//        AnyRedisCommandSignature(commands: commands) { value in value }
//    }
//
//    func erase() -> some RedisCommandSignature<Void> {
//        AnyRedisCommandSignature(commands: commands) { _ in }
//    }
//
//    func asResult() -> some RedisCommandSignature<Result<Value, Error>> {
//        AnyRedisCommandSignature(commands: commands) { value in
//            do {
//                return try .success(makeResponse(from: value))
//            } catch {
//                return .failure(error)
//            }
//        }
//    }
//}
//
//public struct MULTI: RedisCommandSignature, Equatable {
//
//    public typealias Value = Void
//
//    public var commands: [(command: String, arguments: [RESPValue])] {
//        [("MULTI", [])]
//    }
//
//    public init() {}
//}
//
//public struct SETEX: RedisCommandSignature, Equatable {
//
//    public typealias Value = Void
//
//    public var commands: [(command: String, arguments: [RESPValue])] {
//        [(
//            "SETEX",
//            [RESPValue(from: key), RESPValue(from: max(1, expirationInSeconds)), value]
//        )]
//    }
//
//    public var key: RedisKey
//    public var value: RESPValue
//    public var expirationInSeconds: Int
//
//    public init<T: RESPValueConvertible>(_ key: RedisKey, to value: T, expirationInSeconds: Int) {
//        self.key = key
//        self.value = value.convertedToRESPValue()
//        self.expirationInSeconds = expirationInSeconds
//    }
//
//    public init<T: Encodable>(_ key: RedisKey, toJSON value: T, encoder: JSONEncoder = JSONEncoder(), expirationInSeconds: Int) throws {
//        try self.init(key, to: RESPValue(json: value, encoder: encoder), expirationInSeconds: expirationInSeconds)
//    }
//}
//
//@resultBuilder
//public struct RedisCommandBuilder {
//
//    public static func buildPartialBlock<R: RedisCommandSignature>(first: R) -> R {
//        first
//    }
//
//    public static func buildPartialBlock<A: RedisCommandSignature, B: RedisCommandSignature>(
//        accumulated: A,
//        next: B
//    ) -> some RedisCommandSignature<(A.Value, B.Value)> {
//        let accomulatedCommands = accumulated.commands
//        let nextCommands = next.commands
//        let commands = accomulatedCommands + nextCommands
//        return AnyRedisCommandSignature(commands: commands) { value in
//            let array = value.array ?? [value]
//            return try (accumulated.makeResponse(from: value), next.makeResponse(from: value))
//        }
//    }
//
//    public static func buildArray<R: RedisCommandSignature>(_ components: [R]) -> some RedisCommandSignature<[R.Value]> {
//        AnyRedisCommandSignature(commands: components.flatMap(\.commands)) { value in
//            let array = value.array ?? [value]
//            return try zip(array, components).map {
//                try $1.makeResponse(from: $0)
//            }
//        }
//    }
//
//    public static func buildOptional<R: RedisCommandSignature>(_ component: R?) -> some RedisCommandSignature<R.Value?> {
//        if let component {
//            return AnyRedisCommandSignature(commands: component.commands) {
//                try component.makeResponse(from: $0) as R.Value?
//            }
//        } else {
//            return AnyRedisCommandSignature(commands: []) { _ in nil }
//        }
//    }
//
//    public static func buildLimitedAvailability<R: RedisCommandSignature>(_ component: R) -> R {
//        component
//    }
//
//    public static func buildEither<R: RedisCommandSignature>(first component: R) -> some RedisCommandSignature<R.Value> {
//        AnyRedisCommandSignature(commands: component.commands, makeResponse: component.makeResponse)
//    }
//
//    public static func buildEither<R: RedisCommandSignature>(second component: R) -> some RedisCommandSignature<R.Value> {
//        AnyRedisCommandSignature(commands: component.commands, makeResponse: component.makeResponse)
//    }
//
//    public static func buildExpression<R: RedisCommandSignature>(_ expression: R) -> R {
//        expression
//    }
//
//    public static func buildExpression<T>(_ expression: any RedisCommandSignature<T>) -> some RedisCommandSignature<T> {
//        AnyRedisCommandSignature(
//            commands: expression.commands,
//            makeResponse: expression.makeResponse
//        )
//    }
//}
//
//private struct AnyRedisCommandSignature<Value>: RedisCommandSignature {
//
//    let commands: [(command: String, arguments: [RESPValue])]
//    let makeResponse: (RESPValue) throws -> Value
//
//    func makeResponse(from response: RESPValue) throws -> Value {
//        try makeResponse(response)
//    }
//}
