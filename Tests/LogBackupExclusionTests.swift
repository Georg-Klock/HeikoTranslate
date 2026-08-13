import XCTest
@testable import HeikoTranslate

/// L1 coverage for #92: the diagnostic log carries both speakers' words, so
/// no copy of it may leave the phone by a route nobody chose. `Documents/`
/// rides iCloud and local backups by default; every log file must carry
/// `isExcludedFromBackup` — the primary at creation, the rotated runs after
/// the move that can shed the attribute, and the concatenated share file.
///
/// These tests write through the real `DiagnosticLog` into an injected
/// temporary directory and read the resource value back off disk.
final class LogBackupExclusionTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("log-backup-exclusion-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Read the value fresh from disk — a new URL, so no cached resource
    /// values from the write path can satisfy the assertion.
    private func isExcludedFromBackup(_ url: URL) throws -> Bool {
        let fresh = URL(fileURLWithPath: url.path)
        return try fresh.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup ?? false
    }

    /// L1.78 — the primary log file is excluded from backup from the moment
    /// it exists.
    func testL1_78_primaryLogFileIsExcludedFromBackup() throws {
        let log = DiagnosticLog(directory: directory)
        log.log("test", "a line so the file exists with content")
        log.flush()

        XCTAssertTrue(FileManager.default.fileExists(atPath: log.currentURL.path),
                      "the log file must exist before the exclusion can mean anything")
        XCTAssertTrue(try isExcludedFromBackup(log.currentURL),
                      "the primary log file must not ride device backups")
    }

    /// L1.78b — after a launch rotation (current → `.log.1`, a move that can
    /// shed the attribute), the rotated file is excluded again.
    func testL1_78b_rotatedLogFileIsExcludedFromBackup() throws {
        let firstRun = DiagnosticLog(directory: directory)
        firstRun.log("test", "a line from the first run")
        firstRun.flush()

        // A second instance over the same directory is a new launch: its init
        // performs the real rotation, moving the first run's file to `.1`.
        let secondRun = DiagnosticLog(directory: directory)
        secondRun.flush()

        let rotated = secondRun.logURL(index: 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: rotated.path),
                      "rotation must have produced the .1 file for this test to mean anything")
        XCTAssertTrue(try isExcludedFromBackup(rotated),
                      "the rotated log file must not ride device backups")
        XCTAssertTrue(try isExcludedFromBackup(secondRun.currentURL),
                      "the fresh primary after rotation must not ride device backups")
    }

    /// L1.78c — the concatenated share file produced for the manual share
    /// row is excluded from backup too.
    func testL1_78c_exportedShareFileIsExcludedFromBackup() throws {
        let log = DiagnosticLog(directory: directory)
        log.log("test", "a line so the export is non-empty")
        log.flush()

        let exported = try XCTUnwrap(log.exportedFile(),
                                     "the export must succeed for this test to mean anything")
        XCTAssertTrue(try isExcludedFromBackup(exported),
                      "the concatenated share file must not ride device backups")
    }
}
