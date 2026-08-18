import XCTest
@testable import HeikoTranslate

/// The pill is how "which build is on your phone?" gets answered from a
/// screenshot, so the experiment tag has to be visible when it applies and
/// invisible when it does not.
final class AppVersionTests: XCTestCase {
    // L1.74 — an experiment build names itself on the pill.
    func testL1_74_experimentTagIsAppended() {
        XCTAssertEqual(
            AppVersion.experimentLabel(version: "2.4.75", tag: "EC"),
            "2.4.75 EC"
        )
    }

    // L1.74b — a normal build reads exactly as it always has. Missing, empty
    // and whitespace-only all mean "not an experiment": shipping must not
    // depend on remembering to delete a key.
    func testL1_74b_normalBuildsAreUnmarked() {
        for tag in [nil, "", "   "] as [String?] {
            XCTAssertEqual(
                AppVersion.experimentLabel(version: "2.4.75", tag: tag),
                "2.4.75",
                "tag \(String(describing: tag)) should leave the number alone"
            )
        }
    }

    // L1.74c — the tag is read off a phone screen and typed into a message,
    // so its case is normalised rather than trusted to the person editing
    // project.yml.
    func testL1_74c_tagIsNormalised() {
        XCTAssertEqual(
            AppVersion.experimentLabel(version: "2.4.75", tag: " ec "),
            "2.4.75 EC"
        )
    }
}
