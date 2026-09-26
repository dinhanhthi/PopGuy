import Foundation

extension UserDefaults {
    /// Directory that per-test `UserDefaults(suiteName:)` suites live in.
    ///
    /// A suite name that is an absolute path makes CFPreferences store the plist at that
    /// path. Plain names put it in ~/Library/Preferences, where cfprefsd leaves an empty
    /// `<name>.plist` behind even after `removePersistentDomain` (it rewrites the file
    /// asynchronously, so deleting it from the test is not reliable). Every test run
    /// leaked one file per suite; the temp directory is cleaned by the system instead.
    static let testSuiteDirectory: String = {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PopGuyTests-defaults")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }()
}
