# ADR-003: Swift 6 Strict Concurrency Patterns

## Status

Accepted

## Context

SSHot has two hard constraints that pull in opposite directions:

1. `NSPasteboard` must be read on the main thread
2. SCP uploads must not block the main thread

Swift 6 strict concurrency (`SWIFT_STRICT_CONCURRENCY: complete`) enforces isolation boundaries at compile time, making concurrency bugs visible as errors rather than runtime races.

## Decision

Use Swift 6 strict concurrency with the following patterns:

- **`@MainActor` for UI components**: ClipboardWatcher, StatusBarController, NotificationManager, and AppDelegate are all `@MainActor`, ensuring pasteboard access and UI updates happen on the main thread.
- **`Task.detached` for uploads**: Uploads are dispatched via `Task.detached` (not `Task {}`), because `Task {}` inherits `@MainActor` isolation from ClipboardWatcher (SE-0420), causing code before the first `await` to run on main.
- **`Sendable` Settings struct**: Settings are captured as a value-type snapshot before crossing isolation boundaries, avoiding shared mutable state.
- **`OSAllocatedUnfairLock<Bool>` for double-resume guard**: The SCP timeout race can cause both the timeout and the process termination handler to fire. `OSAllocatedUnfairLock` is `Sendable` (unlike a plain `Bool` captured in a closure), satisfying the strict concurrency checker while ensuring the continuation is resumed exactly once.
- **Continuation bridge for Process**: `Foundation.Process` predates Swift concurrency. A `withCheckedThrowingContinuation` bridge wraps the `terminationHandler` callback, with explicit handling for `run()` throwing (terminationHandler never fires in that case).

## Consequences

- All concurrency bugs are caught at compile time rather than manifesting as runtime races
- The `@MainActor` / `Task.detached` split is explicit and auditable
- `os.Logger` is not `Sendable` as of Xcode 16.x — requires `nonisolated(unsafe)` annotation or separate Logger instances per isolation domain
- The continuation + double-resume guard pattern is verbose but necessary — `Process` has no async API
- New contributors must understand Swift concurrency isolation to modify the upload pipeline
