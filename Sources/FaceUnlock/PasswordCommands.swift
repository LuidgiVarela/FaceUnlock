import AppKit
import AVFoundation
import CoreGraphics
import Darwin
import Foundation
import OpenDirectory
import Security

enum PasswordCommand {
    static let service = "com.faceunlock.login-password"

    static func run(_ arguments: ArraySlice<String>) {
        guard let command = arguments.first else {
            printPasswordUsage()
            return
        }

        do {
            switch command {
            case "enroll":
                try enroll()
            case "status":
                try status()
            case "delete":
                try delete()
            default:
                printPasswordUsage()
            }
        } catch {
            print("ERROR: \(error.localizedDescription)")
            exit(1)
        }
    }

    static func printPasswordUsage() {
        print("""
        Usage:
          faceunlock password enroll
          faceunlock password status
          faceunlock password delete
        """)
    }

    static func enroll() throws {
        print("Enter current macOS password:")
        guard var password = SecureTerminalInput.readLineNoEcho(), !password.isEmpty else {
            print("Password verification: FAIL")
            print("Password NOT saved.")
            exit(2)
        }
        defer { password.removeAll(keepingCapacity: false) }

        guard verifyCurrentUserPassword(password) else {
            print("Password verification: FAIL")
            print("Password NOT saved.")
            exit(2)
        }

        try LoginPasswordKeychain.store(password)
        print("Password verification: PASS")
        print("Password stored securely in Keychain.")
    }

    static func status() throws {
        let exists = LoginPasswordKeychain.exists()
        let accessible = LoginPasswordKeychain.passwordAvailable()
        print("Login password stored: \(Format.yesNo(exists))")
        print("Keychain item accessible: \(Format.yesNo(accessible))")
    }

    static func delete() throws {
        try LoginPasswordKeychain.delete()
        print("Login password deleted: PASS")
    }

    static func verifyCurrentUserPassword(_ password: String) -> Bool {
        do {
            let node = try ODNode(session: ODSession.default(), type: UInt32(kODNodeTypeAuthentication))
            let record = try node.record(
                withRecordType: kODRecordTypeUsers,
                name: NSUserName(),
                attributes: nil
            )
            try record.verifyPassword(password)
            return true
        } catch {
            return false
        }
    }
}

enum LoginPasswordKeychain {
    static var account: String { NSUserName() }

    static func store(_ password: String) throws {
        let data = Data(password.utf8)
        var query = baseQuery()
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let attributes: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
            ]
            let updateStatus = SecItemUpdate(baseQuery() as CFDictionary, attributes as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw PasswordCommandError.keychain(updateStatus)
            }
        } else if status != errSecSuccess {
            throw PasswordCommandError.keychain(status)
        }
    }

    static func loadPassword() throws -> String {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            throw PasswordCommandError.keychain(status)
        }
        guard let data = item as? Data,
              let password = String(data: data, encoding: .utf8),
              !password.isEmpty else {
            throw PasswordCommandError.message("Stored password is unreadable.")
        }
        return password
    }

    static func exists() -> Bool {
        var query = baseQuery()
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    static func passwordAvailable() -> Bool {
        (try? loadPassword()) != nil
    }

    static func delete() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PasswordCommandError.keychain(status)
        }
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: PasswordCommand.service,
            kSecAttrAccount as String: account
        ]
    }
}

enum SecureTerminalInput {
    static func readLineNoEcho() -> String? {
        var term = termios()
        guard tcgetattr(STDIN_FILENO, &term) == 0 else {
            return nil
        }

        var noEcho = term
        noEcho.c_lflag &= ~UInt(ECHO)
        guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &noEcho) == 0 else {
            return nil
        }
        defer {
            _ = tcsetattr(STDIN_FILENO, TCSAFLUSH, &term)
            print("")
        }
        return readLine()
    }
}

enum PermissionsCommand {
    static func run() {
        let camera = AVCaptureDevice.authorizationStatus(for: .video)
        let cameraPass = camera == .authorized
        let accessibilityPass = AXIsProcessTrusted()

        print("Camera: \(Format.passFail(cameraPass))")
        print("Accessibility: \(Format.passFail(accessibilityPass))")
        print("Input Monitoring: UNKNOWN")

        if !cameraPass {
            print("")
            print("Grant Camera permission in System Settings > Privacy & Security > Camera.")
        }
        if !accessibilityPass {
            print("")
            print("Grant Accessibility permission in System Settings > Privacy & Security > Accessibility for Terminal or the built faceunlock executable.")
        }
        print("")
        print("macOS does not provide a clean non-invasive CLI status API for Input Monitoring. If keyboard injection is blocked, grant it in System Settings > Privacy & Security > Input Monitoring.")
    }
}

final class LockScreenKeyboardInjector {
    static func eventSourceAvailable() -> Bool {
        CGEventSource(stateID: .hidSystemState) != nil
    }

    func injectPasswordAndReturn(_ password: String, sessionState: SessionState) -> Bool {
        guard sessionState == .locked else {
            print("Keyboard injection blocked: session is not locked.")
            return false
        }
        guard AXIsProcessTrusted() else {
            print("Keyboard injection blocked: Accessibility permission missing.")
            return false
        }

        autoreleasepool {
            type(password)
            pressReturn()
        }
        return true
    }

    private func type(_ text: String) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        var chars = Array(text.utf16)
        chars.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            let down = CGEvent(keyboardEventSource: source, virtualKey: 49, keyDown: true)
            down?.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
            down?.post(tap: .cghidEventTap)

            let up = CGEvent(keyboardEventSource: source, virtualKey: 49, keyDown: false)
            up?.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
            up?.post(tap: .cghidEventTap)
        }
    }

    private func pressReturn() {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: false)?.post(tap: .cghidEventTap)
    }
}

enum PasswordCommandError: LocalizedError {
    case keychain(OSStatus)
    case message(String)

    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            if let message = SecCopyErrorMessageString(status, nil) as String? {
                return "Keychain error \(status): \(message)"
            }
            return "Keychain error \(status)"
        case .message(let text):
            return text
        }
    }
}
