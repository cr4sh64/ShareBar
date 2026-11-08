import XCTest
@testable import ShareBar

final class ShareTests: XCTestCase {
    private func decode(_ json: String) throws -> Share {
        try JSONDecoder().decode(Share.self, from: Data(json.utf8))
    }

    func testOptionalFieldsGetDefaults() throws {
        let s = try decode(#"{"name":"NAS","host":"nas.local","path":"Docs"}"#)
        XCTAssertEqual(s.type, .smb)
        XCTAssertNil(s.user)
        XCTAssertFalse(s.autoMount)
        XCTAssertFalse(s.openOnMount)
        XCTAssertEqual(s.mountAttempts, 1)
    }

    func testMountAttemptsIsAtLeastOne() throws {
        XCTAssertEqual(try decode(#"{"name":"a","host":"h","path":"p","mountAttempts":0}"#).mountAttempts, 1)
        XCTAssertEqual(try decode(#"{"name":"a","host":"h","path":"p","mountAttempts":-3}"#).mountAttempts, 1)
        XCTAssertEqual(try decode(#"{"name":"a","host":"h","path":"p","mountAttempts":3}"#).mountAttempts, 3)
    }

    func testMissingRequiredFieldFails() {
        XCTAssertThrowsError(try decode(#"{"name":"a","path":"p"}"#))
    }

    func testUnknownTypeFails() {
        XCTAssertThrowsError(try decode(#"{"name":"a","host":"h","path":"p","type":"ftp"}"#))
    }

    func testURL() throws {
        XCTAssertEqual(try decode(#"{"name":"a","host":"192.168.1.2","path":"/Home/"}"#).url?.absoluteString,
                       "smb://192.168.1.2/Home")
        XCTAssertEqual(try decode(#"{"name":"a","host":"nas","path":"Mes Vidéos"}"#).url?.absoluteString,
                       "smb://nas/Mes%20Vid%C3%A9os")
        XCTAssertEqual(try decode(#"{"name":"a","host":"dav.example.com","path":"files","type":"webdavs"}"#)
                        .url?.absoluteString, "https://dav.example.com/files")
    }

    func testIdMatchesVolumeKey() throws {
        let s = try decode(#"{"name":"a","host":"NAS.local","path":"/Docs"}"#)
        XCTAssertEqual(s.id, Volumes.key(scheme: "smb", host: "nas.local", path: "docs"))
    }

    func testSchemesAndPorts() {
        let expected: [(ShareProtocol, String, UInt16)] = [
            (.smb, "smb", 445), (.afp, "afp", 548), (.nfs, "nfs", 2049),
            (.webdav, "http", 80), (.webdavs, "https", 443),
        ]
        for (p, scheme, port) in expected {
            XCTAssertEqual(p.scheme, scheme)
            XCTAssertEqual(p.port, port)
        }
    }

    /// L'exemple écrit au premier lancement et celui du README doivent rester valides.
    func testExampleConfigDecodes() throws {
        struct Config: Decodable { let shares: [Share] }
        let shares = try JSONDecoder().decode(Config.self, from: Data(ConfigStore.example.utf8)).shares
        XCTAssertEqual(shares.count, 1)
        XCTAssertTrue(shares[0].autoMount)
    }
}
