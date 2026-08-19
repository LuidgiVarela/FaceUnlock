# FaceUnlock

Experimental macOS Face Unlock app for Apple Silicon Macs.

FaceUnlock runs as a quiet menu bar app. It keeps the camera off while the user session is unlocked and only starts the camera after macOS reports that the Lock Screen is active.

## How FaceUnlock Works

1. Detects macOS Lock Screen.
2. Activates camera.
3. Performs face + liveness recognition.
4. Retrieves the macOS password from Keychain.
5. Types it into the native Lock Screen using CGEvent.
6. Stops the camera after unlock.

The app uses the normal macOS Lock Screen password flow. It does not use Authorization Plugin, PAM, FileVault changes, SIP changes, `loginwindow` replacement, or AuthorizationDB changes.

## Privacy And Battery

In normal unlocked use:

```text
Session: UNLOCKED
Camera: OFF
Face recognition: OFF
Liveness: OFF
```

On lock:

```text
Session: LOCKED
Camera: ON
Face recognition: ON
Liveness: ON
```

The camera is stopped after authentication succeeds, fails, or the session unlocks.

## Stored Data

Face enrollment is stored locally at:

```text
~/.faceunlock/template.json
```

The macOS login password is stored only in macOS Keychain:

```text
service: com.faceunlock.login-password
account: <current macOS username>
```

The password is validated with OpenDirectory before it is saved. FaceUnlock does not store the password in UserDefaults, JSON, plist, SQLite, logs, command arguments, or the clipboard.

## Permissions

FaceUnlock.app requires:

- Camera: used only during face enrollment, face test, or while the Lock Screen is active.
- Accessibility: required to type the password into the native Lock Screen with CGEvent.

If keyboard injection is blocked, macOS may also require Input Monitoring permission for the app.

## Build

Build the CLI:

```sh
swift build
```

Build and sign the menu bar app:

```sh
scripts/build_app.sh
```

The app is generated at:

```text
~/Applications/FaceUnlock.app
```

By default, the public build script uses a placeholder bundle identifier:

```text
com.example.FaceUnlock
```

For local use, keep a stable bundle identifier and signing identity so macOS Camera and Accessibility permissions stay attached across rebuilds. Copy the example file and edit it:

```sh
cp .env.local.example .env.local
```

Example:

```text
export FACEUNLOCK_BUNDLE_ID="com.yourname.FaceUnlock"
export FACEUNLOCK_SIGNING_IDENTITY="Apple Development: Your Name (TEAMID)"
```

If `FACEUNLOCK_SIGNING_IDENTITY` is not set, the script tries to use the first available `Apple Development` code signing identity. If none exists, it falls back to ad-hoc signing.

Do not commit `.env.local`.

## CLI Diagnostics

Enroll face samples:

```sh
swift run faceunlock enroll 8
```

Store or update the macOS password in Keychain:

```sh
swift run faceunlock password enroll
```

Check password status:

```sh
swift run faceunlock password status
```

Delete the stored password:

```sh
swift run faceunlock password delete
```

Check permissions:

```sh
swift run faceunlock permissions
```

Observe lock/unlock session events without camera or unlock:

```sh
swift run faceunlock session-test
```

Run the unlock engine from CLI:

```sh
swift run faceunlock monitor --enable-unlock
```

Dry-run face recognition without typing the password:

```sh
swift run faceunlock unlock-test --dry-run
```

## Logs

Runtime logs are written to:

```text
~/.faceunlock/faceunlock.log
```

Logs include session state, camera start/stop, face detection, liveness, identity match/no match, Keychain availability, Accessibility status, and unlock attempt status. Logs do not include passwords, face frames, images, or full embeddings.

## Before Publishing

This repository should not contain local runtime data. Do not commit:

- `.build/`
- `.env.local`
- `~/.faceunlock/template.json`
- `~/.faceunlock/faceunlock.log`
- private signing identities, certificates, or keys
