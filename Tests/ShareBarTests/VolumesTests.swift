import XCTest
@testable import ShareBar

final class VolumesTests: XCTestCase {
    func testKeyIgnoresCaseAndSlashes() {
        XCTAssertEqual(Volumes.key(scheme: "SMB", host: "NAS.Local", path: "/Docs/"),
                       Volumes.key(scheme: "smb", host: "nas.local", path: "docs"))
    }

    func testKeyIgnoresTrailingDotInHost() {
        XCTAssertEqual(Volumes.key(scheme: "smb", host: "nas.local.", path: "a"),
                       Volumes.key(scheme: "smb", host: "nas.local", path: "a"))
    }

    /// macOS renvoie les chemins montés en NFD (« e » + accent), la config est en NFC (« é »).
    func testKeyIgnoresUnicodeNormalization() {
        let nfc = "Vid\u{00E9}os", nfd = "Vide\u{0301}os"
        XCTAssertNotEqual(Array(nfc.unicodeScalars), Array(nfd.unicodeScalars)) // vraiment deux encodages
        XCTAssertEqual(Volumes.key(scheme: "smb", host: "nas", path: nfc),
                       Volumes.key(scheme: "smb", host: "nas", path: nfd))
    }

    func testKeyDistinguishesHostsAndShares() {
        XCTAssertNotEqual(Volumes.key(scheme: "smb", host: "nas", path: "a"),
                          Volumes.key(scheme: "smb", host: "nas", path: "b"))
        XCTAssertNotEqual(Volumes.key(scheme: "smb", host: "nas", path: "a"),
                          Volumes.key(scheme: "afp", host: "nas", path: "a"))
    }
}
