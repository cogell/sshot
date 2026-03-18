# ADR-001: Clipboard-First Architecture

## Status

Accepted

## Context

Developers working on remote machines via SSH/mosh need a way to share screenshots with tools like Claude Code running on the remote. Existing solutions (claude-screenshot-uploader, claudecode-remote-server-copypaste-image) use a folder-watcher approach: they monitor a directory for new files and upload changes via rsync or scp.

The folder-watcher approach requires a specific screenshot tool configuration (save to a watched folder) and doesn't work with clipboard-only screenshot flows (Cmd+Ctrl+Shift+4, CleanShot X copy-to-clipboard).

## Decision

SSHot monitors the macOS clipboard (`NSPasteboard.general`) for image data rather than watching a filesystem directory. When an image appears on the clipboard, SSHot uploads it and replaces the clipboard with the remote file path.

This approach works with any screenshot tool that copies to the clipboard, requiring no tool-specific configuration.

## Consequences

- Works with any screenshot tool out of the box (CleanShot X, native macOS screenshots, any app's copy-image action)
- No filesystem watcher complexity (no FSEvents, no debouncing file writes)
- Requires polling `NSPasteboard.general.changeCount` since there is no notification API for clipboard changes on macOS
- Must handle self-loop prevention (SSHot writes a path back to the clipboard, which it must not re-process)
- Must handle lazy/promised pasteboard data from tools like CleanShot X (grace delay pattern)
- Cannot process images that are saved to disk but never copied to clipboard
