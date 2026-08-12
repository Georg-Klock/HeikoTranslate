import XCTest

/// The #14 acceptance no unit test can reach, verified against the REAL
/// accessibility tree: each language column surfaces as ONE element whose
/// label is the column descriptor and whose value is the selected
/// language. Local-only (Tools/uitest-accessibility.sh) — the CI-spend
/// decision on UI tests stands; this target is not in the main scheme.
///
/// The adjustable ACTION has no XCUITest trigger for custom elements, so
/// its behaviour remains pinned by the pure lap tests plus the fact that
/// it writes the same binding touch writes (L1.29 family).
final class AccessibilityWheelUITests: XCTestCase {

    func testEachWheelIsOneLabelledValuedElement() throws {
        let app = XCUIApplication()
        app.launch()

        // The mic alert may appear on a fresh container; dismiss whichever
        // localization shows up.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for title in ["Allow", "OK", "Erlauben"] {
            let b = springboard.buttons[title]
            if b.waitForExistence(timeout: 2) { b.tap(); break }
        }

        // Open the settings sheet via the language pill. Located by its
        // settings label in EITHER of the two languages a fresh container
        // has been observed to boot into (see the issue on fresh-install
        // home language) — this test's claims are structural, not
        // linguistic.
        let pill = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label IN %@", ["Einstellungen", "Settings"])).firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 8),
                      "the language pill must be reachable by its settings label")
        pill.tap()

        // The two columns, by descriptor in either language set. Each must
        // be exactly ONE element carrying a non-empty value — the #14
        // acceptance no unit test can reach.
        let descriptorSets = [["Andere sprechen", "Others speak"],
                              ["Ich spreche", "I speak"]]
        for labels in descriptorSets {
            let pred = NSPredicate(format: "label IN %@", labels)
            // Exactly one REAL element per column. XCUITest also synthesizes
            // a staticText child carrying the element's own label — that is
            // the element's text-of-self, not a second control, so the
            // count that matters is the non-text one.
            let elements = app.otherElements.matching(pred)
            XCTAssertTrue(elements.firstMatch.waitForExistence(timeout: 8),
                          "\(labels[0]): the column must surface to accessibility")
            XCTAssertEqual(elements.count, 1,
                           "\(labels[0]): ONE element — not the rotary's rows")
            let value = elements.firstMatch.value as? String ?? ""
            XCTAssertFalse(value.isEmpty,
                           "\(labels[0]): the value must announce the selection")
        }

        // The rotary's OTHER languages must not surface as elements at all —
        // this is the 500-duplicate failure #14 was filed about. Endonyms
        // appear on the home wheel's rows in every language, so any of them
        // reaching the tree means children are leaking.
        for rowLabel in ["Español", "Français", "한국어", "中文"] {
            XCTAssertEqual(app.staticTexts.matching(
                NSPredicate(format: "label == %@", rowLabel)).count, 0,
                "\(rowLabel): rotary rows must not leak into the tree")
        }
    }
}
