import XCTest
@testable import ShareBar

final class MountErrorTests: XCTestCase {
    func testCancelIsNeitherShownNorRetried() {
        for code in [Int32(-128), ECANCELED] {
            XCTAssertTrue(MountError(code: code).isCancel)
            XCTAssertFalse(MountError(code: code).isRetryable)
        }
    }

    /// Réessayer un mot de passe refusé ne sert à rien (et peut verrouiller le compte).
    func testAuthErrorsAreNotRetried() {
        for code in [EAUTH, EACCES, EPERM] {
            XCTAssertFalse(MountError(code: code).isRetryable)
            XCTAssertTrue(MountError(code: code).errorDescription!.contains("clique sur le partage"))
        }
    }

    func testNetworkErrorsAreRetried() {
        for code in [ETIMEDOUT, EHOSTUNREACH, EHOSTDOWN, ENETUNREACH] {
            XCTAssertTrue(MountError(code: code).isRetryable)
            XCTAssertEqual(MountError(code: code).errorDescription, "Serveur injoignable")
        }
    }

    func testUnknownCodes() {
        XCTAssertEqual(MountError(code: -6600).errorDescription, "Erreur -6600")
        XCTAssertEqual(MountError(code: ENOENT).errorDescription, "Partage introuvable")
    }
}
