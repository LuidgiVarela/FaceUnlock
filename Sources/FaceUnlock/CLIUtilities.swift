import Foundation

enum Format {
    static func yesNo(_ value: Bool) -> String {
        value ? "YES" : "NO"
    }

    static func passFail(_ value: Bool) -> String {
        value ? "PASS" : "FAIL"
    }
}
