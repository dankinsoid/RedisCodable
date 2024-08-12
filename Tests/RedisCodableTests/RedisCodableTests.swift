import XCTest
@testable import RedisCodable

final class RedisCodableTests: XCTestCase {

    func testEncodeHash() throws {
        let encoder = RESPEncoder()
        let hash = try encoder.encodeHash(TestStruct())
        print(hash)
    }

    func testDecoderHash() throws {
        let decoder = RESPDecoder()
        let hash = try decoder.decodeHash(TestStruct.self, from: [
            "int": .integer(0),
            "string": "String".convertedToRESPValue(),
            "intArray": .array([.integer(0), .integer(1), .integer(2)]),
            "intDict": "{\"0\": \"0\", \"1\": \"1\", \"2\": \"2\"}".convertedToRESPValue()
        ])
        print(hash)
    }
}

struct TestStruct: Codable {
    
    var int = 0
    var string = "String"
    var intArray = [0, 1, 2]
    var intDict: [Int: String] = [0: "0", 1: "1", 2: "2"]
}
