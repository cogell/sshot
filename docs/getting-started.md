# Getting Started

SSHot is a macOS menu bar app that watches your clipboard for images and uploads them to a remote server via SCP, replacing the clipboard with the remote file path.

## Prerequisites

- macOS 14.0+
- An SSH key configured for passwordless access to your remote server (ssh-agent or unencrypted key)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (for building from source)
- Xcode 16+

## Build from Source

```bash
# Clone the repo
git clone https://github.com/cogell/sshot.git
cd sshot

# Generate the Xcode project
xcodegen generate

# Open in Xcode
open SSHot.xcodeproj
```

Build and run with Cmd+R. The app appears as a camera icon in the menu bar (no Dock icon).

## Configure

1. Click the camera icon in the menu bar
2. Select **Open Settings...**
3. Fill in:
   - **SSH Host**: the hostname or alias from your `~/.ssh/config` (e.g., `home`)
   - **Remote Path**: directory on the remote server (default: `~/.paste/` — created automatically)
   - **Identity File** (optional): path to your SSH private key if not using ssh-agent
4. Click **Test Connection** in the menu to verify SSH access

## Use

1. Toggle SSHot to **Enabled** in the menu bar
2. Take a screenshot (CleanShot X, Cmd+Ctrl+Shift+4, or any tool that copies to clipboard)
3. SSHot detects the image, uploads it, and replaces your clipboard with the remote path
4. Paste the path wherever you need it (e.g., into Claude Code on a remote machine via tmux)

The menu bar icon animates during upload. You'll get a macOS notification on success or failure.

## Launch at Login

Enable **Launch at Login** in Settings > General to start SSHot automatically when you log in.
