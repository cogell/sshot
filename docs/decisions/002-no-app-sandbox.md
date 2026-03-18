# ADR-002: No App Sandbox / No Mac App Store

## Status

Accepted

## Context

macOS apps distributed through the Mac App Store must enable the App Sandbox entitlement. SSHot's core functionality depends on launching `/usr/bin/scp` and `/usr/bin/ssh` as subprocesses via `Foundation.Process.run()`.

`Process.run()` is not permitted inside the App Sandbox. There is no sandbox exception or entitlement that allows launching arbitrary executables.

## Decision

SSHot is distributed exclusively via GitHub Releases (.dmg) and Homebrew cask. The App Sandbox entitlement is omitted entirely from the entitlements file (not set to `false`, which can cause notarization rejection). Hardened Runtime is enabled for notarization with Developer ID signing.

## Consequences

- SSHot can launch `/usr/bin/scp` and `/usr/bin/ssh` freely
- Cannot distribute through the Mac App Store
- Requires Developer ID certificate for code signing and notarization
- Users must allow the app through Gatekeeper on first launch
- Hardened Runtime provides security guarantees (code signing enforcement, library validation) without the filesystem restrictions of App Sandbox
- `disable-library-validation` entitlement needed in Debug builds for Sparkle's XPC service; omitted in Release builds
