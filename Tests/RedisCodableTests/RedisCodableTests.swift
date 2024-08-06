import XCTest
@testable import RedisCodable

final class RedisCodableTests: XCTestCase {
    
    func testEncodeHash() throws {
        let encoder = RESPEncoder()
        let hash = try encoder.encodeHash(TestStruct())
        print(hash)
    }
}

struct TestStruct: Codable {
    
    var int = 0
    var string = "String"
    var intArray = [0, 1, 2]
    var intDict: [Int: String] = [0: "0", 1: "1", 2: "2"]
}
