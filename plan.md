# SSHot — Implementation Plan

## What It Is

A macOS menu bar app that monitors the clipboard for images and automatically uploads them to a remote server via SSH, replacing the clipboard with the remote file path.

**Target user**: Developers who SSH/mosh into remote machines and want to share screenshots with tools like Claude Code running on the remote.

## User Story

1. Take screenshot with CleanShot X → Cmd+C (image now in clipboard)
2. SSHot (running in menu bar, toggled ON) detects image in clipboard
3. Uploads to remote: `~/.paste/2026-03-17T103045.png` via `scp`
4. Replaces local clipboard with the remote path string
5. Switch to tmux → Cmd+V → path is ready to paste into Claude Code

**Key distinction from existing tools**: clipboard-first (not folder-watcher-based). Works with any screenshot tool that copies to clipboard (CleanShot X, Cmd+Ctrl+Shift+4, etc.).

## Tech Stack

- **Language**: Swift
- **UI**: AppKit — `NSStatusItem` for menu bar
- **Clipboard monitoring**: Poll `NSPasteboard.changeCount` every 0.5s, check for image types
- **Upload**: `scp` via Foundation's `Process`
- **Config persistence**: `UserDefaults`
- **Distribution**: GitHub Releases as `.app` bundle inside `.dmg`

## Features

### MVP
- [ ] Clipboard image detection (poll `NSPasteboard` for `public.png` / `public.tiff` / `NSImage`)
- [ ] Extract image from clipboard as PNG
- [ ] SCP upload to configured remote host
- [ ] Timestamped remote filename: `~/.paste/YYYY-MM-DDTHHMMSS.png`
- [ ] Replace local clipboard with remote path string after upload
- [ ] macOS notification on success/failure

### Menu Bar UI
- [ ] Status icon (camera, dimmed/greyed when disabled)
- [ ] Toggle: Enabled / Disabled
- [ ] Settings submenu:
  - SSH Host (default: `home`)
  - Remote path (default: `~/.paste/`)
- [ ] Last upload: timestamp + path (read-only)
- [ ] Quit

### Post-MVP
- [ ] Upload history list in menu (last N uploads)
- [ ] Multiple SSH host profiles
- [ ] Retry logic on upload failure
- [ ] Homebrew cask distribution
- [ ] Support CleanShot X's "All-in-One" mode (saves file + clipboard)

## Architecture

```
SSHot/
├── SSHotApp.swift              # @main entry point, NSApplication setup
├── AppDelegate.swift           # App lifecycle
├── StatusBarController.swift   # NSStatusItem, NSMenu, user actions
├── ClipboardWatcher.swift      # Timer-based NSPasteboard poller
├── Uploader.swift              # scp via Process, async with callback
├── Settings.swift              # UserDefaults-backed config (host, path)
└── Assets.xcassets/            # App icon, menu bar icon
```

### Key design notes
- `ClipboardWatcher` tracks `changeCount` to avoid re-triggering on same clipboard contents
- After upload, SSHot writes the path string to clipboard — this resets `changeCount`, but the new content is text not image, so it won't re-trigger
- `Uploader` runs `scp` as a subprocess; stdout/stderr captured for error reporting
- Settings are stored in `UserDefaults` under `com.cogell.sshot`

## Distribution

- GitHub Actions: build `.app` → package `.dmg` → attach to GitHub Release on tag push
- README install instructions: download `.dmg` from releases, drag to Applications, allow in System Settings > Privacy & Security
- Homebrew cask (stretch goal)
- MIT License

## Prior Art

- [claude-screenshot-uploader](https://github.com/mdrzn/claude-screenshot-uploader) — folder-watcher approach, xbar UI, bash script
- [claudecode-remote-server-copypaste-image](https://github.com/ooiyeefei/claudecode-remote-server-copypaste-image) — similar, uses rsync + launchd
- Ghostty [discussion #10517](https://github.com/ghostty-org/ghostty/discussions/10517) — proposed native terminal-level SSH image paste (not merged)

SSHot differentiates by being clipboard-first, native Swift, and having a proper toggle-able menu bar UI.
