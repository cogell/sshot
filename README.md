# SSHot

A macOS menu bar app that monitors your clipboard for images and automatically uploads them to a remote server via SSH, replacing the clipboard with the remote file path.

**Target user**: Developers who SSH/mosh into remote machines and want to share screenshots with tools like Claude Code running on the remote.

## How It Works

1. Take a screenshot (CleanShot X, Cmd+Ctrl+Shift+4, or any tool that copies to clipboard)
2. SSHot detects the image, uploads it via SCP to your remote server
3. Your clipboard is replaced with the remote file path
4. Paste the path into your remote terminal session

## Quick Start

```bash
xcodegen generate
open SSHot.xcodeproj
# Build and run (Cmd+R)
```

Configure your SSH host and remote path in Settings, then toggle Enabled in the menu bar.

See [Getting Started](docs/getting-started.md) for full setup instructions.

## Documentation

| Doc | Description |
|-----|-------------|
| [Getting Started](docs/getting-started.md) | Build, install, and configure SSHot |
| [Architecture](docs/architecture.md) | Components, concurrency model, data flow |
| [SSH Setup Guide](docs/guides/ssh-setup.md) | Configure SSH keys for passwordless access |
| [Settings Reference](docs/reference/settings.md) | All settings, defaults, and validation rules |
| [Error Reference](docs/reference/errors.md) | Error types and troubleshooting |

### Decisions

| ADR | Decision |
|-----|----------|
| [001](docs/decisions/001-clipboard-first.md) | Clipboard-first architecture (not folder-watcher) |
| [002](docs/decisions/002-no-app-sandbox.md) | No App Sandbox / No Mac App Store |
| [003](docs/decisions/003-swift6-concurrency.md) | Swift 6 strict concurrency patterns |

## Tech Stack

- Swift 6 (strict concurrency) / macOS 14+
- AppKit (menu bar) + SwiftUI (settings panel)
- SCP via `Foundation.Process`
- Sparkle for auto-updates
- XcodeGen for project generation

## Distribution

GitHub Releases (.dmg) and Homebrew cask. Not on the Mac App Store (incompatible with App Sandbox — see [ADR-002](docs/decisions/002-no-app-sandbox.md)).

## License

MIT
