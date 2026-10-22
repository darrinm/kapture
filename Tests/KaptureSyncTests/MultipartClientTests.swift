// The client side of R2 multipart (F54, F87), against a stub that answers as the Worker does.
//
// The protocol changed on both ends at once — the Worker moved from staging parts as objects to
// R2's own multipart API — so this checks the requests the client sends match what the Worker's
// routes (and their tests in worker/test/libraryQuota.test.ts) expect.

import XCTest
@testable import KaptureSync

/// Answers multipart requests the way `handleBlob` does, and records what it was sent.
final class MultipartStub: URLProtocol {
    struct Seen { var method: String; var query: [String: String]; var body: Data }
    nonisolated(unsafe) static var seen: [Seen] = []
    nonisolated(unsafe) static var objectExists = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }

    override func startLoading() {
        let url = request.url!
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let query = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        Self.seen.append(Seen(method: request.httpMethod ?? "GET", query: query,
                              body: Self.body(of: request)))

        let reply: [String: Any]
        if query["uploads"] != nil {
            reply = Self.objectExists ? ["exists": true] : ["uploadId": "UP1"]
        } else if let part = query["part"] {
            reply = ["partNumber": Int(part) ?? 0, "etag": "etag-\(part)"]
        } else {
            reply = ["bytes": 0]
        }
        let data = try! JSONSerialization.data(withJSONObject: reply)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class MultipartClientTests: XCTestCase {
    var transport: HTTPTransport!
    let locator = BlobLocatorRef(purpose: .blob, revision: 1,
                                 writer: "01JBAAAAAAAAAAAAAAAAAAAAAA", capture: "CAPTURE")

    override func setUp() {
        MultipartStub.seen = []
        MultipartStub.objectExists = false
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MultipartStub.self]
        transport = HTTPTransport(endpoint: URL(string: "https://library.test")!,
                                  deviceToken: "darrin.secret",
                                  session: URLSession(configuration: configuration))
    }

    func testAnUploadStartsSendsEveryPartAndCompletesWithTheirEtags() async throws {
        let data = Data(repeating: 7, count: HTTPTransport.partSize + 10)

        try await transport.putMultipart(data, at: locator)

        let seen = MultipartStub.seen
        XCTAssertEqual(seen.count, 4, "start, two parts, complete")
        XCTAssertEqual(seen[0].method, "POST")
        XCTAssertNotNil(seen[0].query["uploads"])

        XCTAssertEqual(seen[1].method, "PUT")
        XCTAssertEqual(seen[1].query["uploadId"], "UP1")
        XCTAssertEqual(seen[1].query["part"], "1")
        XCTAssertEqual(seen[1].body.count, HTTPTransport.partSize)
        XCTAssertEqual(seen[2].query["part"], "2")
        XCTAssertEqual(seen[2].body.count, 10)

        XCTAssertEqual(seen[3].method, "POST")
        XCTAssertEqual(seen[3].query["uploadId"], "UP1")
        XCTAssertNotNil(seen[3].query["complete"])
        let sent = try JSONSerialization.jsonObject(with: seen[3].body) as? [String: Any]
        let parts = sent?["parts"] as? [[String: Any]]
        XCTAssertEqual(parts?.map { $0["etag"] as? String }, ["etag-1", "etag-2"],
                       "R2 assembles the object from exactly these")
    }

    func testAnObjectThatAlreadyExistsIsNotUploadedAgain() async throws {
        // The retry after a lost response (F99): the server reports the object and the client
        // stops, rather than sending every part again.
        MultipartStub.objectExists = true

        try await transport.putMultipart(Data(repeating: 1, count: 64), at: locator)

        XCTAssertEqual(MultipartStub.seen.count, 1)
    }
}
