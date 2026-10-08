import XCTest
@testable import DockPlus

/// Which unreadable iCloud file is a newer DockPlus's, and so must be left alone, and which is
/// corrupt, and so is replaced. Mistaking the first for the second lost the newer Mac's settings.
final class SettingsSyncDecodeTests: XCTestCase {
    private func decodingError(_ json: String) -> (any Error)? {
        do {
            _ = try PortableSettings.decoded(from: Data(json.utf8))
            return nil
        } catch {
            return error
        }
    }

    /// A setting whose type changed in a newer schema fails on that setting, with its path.
    func testNewerSchemaIsATypeMismatchAtASetting() throws {
        let error = try XCTUnwrap(decodingError(#"{"iconSize":"x"}"#))
        guard let decoding = error as? DecodingError, case .typeMismatch(_, let context) = decoding else {
            return XCTFail("expected a type mismatch, got \(error)")
        }
        XCTAssertFalse(context.codingPath.isEmpty)
        XCTAssertTrue(PortableSettings.isFromNewerDockPlus(error))
    }

    /// Valid JSON that is not an object is corrupt in every schema, so it is replaced rather than
    /// waited out — though it too fails as a type mismatch, at the top.
    func testNonObjectIsCorruptNotNewer() throws {
        let error = try XCTUnwrap(decodingError("[]"))
        XCTAssertFalse(PortableSettings.isFromNewerDockPlus(error))
    }

    func testNonJSONIsCorruptNotNewer() throws {
        let error = try XCTUnwrap(decodingError("not json"))
        XCTAssertFalse(PortableSettings.isFromNewerDockPlus(error))
    }

    /// A value this build cannot hold would be dropped or clamped by `apply`, then written back over
    /// the newer Mac's, so the file is held like a type change.
    func testValuesBeyondThisBuildAreHeld() throws {
        let unknownEdge = try PortableSettings.decoded(from: Data(#"{"edge":"top"}"#.utf8))
        XCTAssertTrue(unknownEdge.isBeyondThisBuild)
        let wide = try PortableSettings.decoded(from: Data(#"{"iconSize":1e9}"#.utf8))
        XCTAssertTrue(wide.isBeyondThisBuild)
        let fine = try PortableSettings.decoded(from: Data(#"{"edge":"left","iconSize":48}"#.utf8))
        XCTAssertFalse(fine.isBeyondThisBuild)
    }

    /// Every field is optional, so any JSON object decodes; import tells a settings file from some
    /// other object by whether it carried a single known setting.
    func testImportOfUnrelatedObjectIsEmpty() throws {
        let other = try PortableSettings.decoded(from: Data(#"{"name":"x","items":[1]}"#.utf8))
        XCTAssertTrue(other.isEmpty)
        let none = try PortableSettings.decoded(from: Data("{}".utf8))
        XCTAssertTrue(none.isEmpty)
        let one = try PortableSettings.decoded(from: Data(#"{"clock24Hour":true}"#.utf8))
        XCTAssertFalse(one.isEmpty)
    }
}
