import XCTest
@testable import Sprocket
final class NodeTests: XCTestCase {
    func testVideoRequestsIncludeMasks() throws {
        let json = #"{"type":"group","children":[{"type":"video","src":"a","time":1.5,"mask":[{"type":"video","src":"b"}]}]}"#
        let n = try JSONDecoder().decode(Node.self, from: Data(json.utf8))
        XCTAssertEqual(n.videoRequests.map(\.src), ["a", "b"])
    }
}
