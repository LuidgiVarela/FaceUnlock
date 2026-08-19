# Security Notes

FaceUnlock is an experimental local macOS utility.

It unlocks the native macOS Lock Screen by typing the user's stored macOS password with CGEvent after local face and liveness checks pass. The password is stored in macOS Keychain and is never written to this repository.

Do not commit:

- `~/.faceunlock/template.json`
- `~/.faceunlock/faceunlock.log`
- `.env.local`
- `.build/`
- personal signing identities or private keys

The app does not modify AuthorizationDB, PAM, SIP, FileVault, or `loginwindow`.
