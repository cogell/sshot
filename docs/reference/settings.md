# Settings Reference

All settings are stored in `UserDefaults` under the suite `com.cogell.sshot`.

## Fields

| Setting | Default | Description |
|---------|---------|-------------|
| SSH Host | `home` | Remote server hostname or SSH config alias |
| Remote Path | `~/.paste/` | Directory on the remote server for uploaded images |
| Identity File | *(none)* | Path to SSH private key (optional if using ssh-agent) |
| Enabled | `true` | Whether clipboard monitoring is active |
| Launch at Login | `false` | Start SSHot automatically at login via `SMAppService` |

## Validation Rules

### SSH Host

- Must not be empty
- Must not contain whitespace
- Must not contain shell metacharacters: `;`, `` ` ``, `$`, `(`, `)`, `|`, `&`, `>`, `<`

### Remote Path

- Must not be empty
- Must not contain spaces
- Must not contain shell metacharacters (same set as SSH Host)
- Tilde (`~`) is allowed (expanded by the remote shell)

### Identity File

- Must point to an existing file on disk
- Must not be a directory
- Must not end in `.pub` (that's the public key)
- When set, SSHot adds `-i <path> -o IdentitiesOnly=yes` to SSH/SCP commands

## SSH Options

SSHot passes these options to both `ssh` and `scp`:

| Option | Value | Purpose |
|--------|-------|---------|
| `BatchMode` | `yes` | Fail immediately if interactive auth is required |
| `StrictHostKeyChecking` | `accept-new` | Auto-accept new host keys, reject changed keys |
| `ConnectTimeout` | `10` | Fail fast on unreachable hosts (seconds) |
| `IdentitiesOnly` | `yes` | Only use the specified identity file (when set) |

## Limits

| Limit | Value | Configurable |
|-------|-------|-------------|
| Max image size | 20 MB | Not yet (post-MVP) |
| Upload timeout | 30 seconds | No |
| Retry delay | 2 seconds | No |
| Max retries | 1 | No |
| Poll interval | 150 ms | No |
| Grace delay | 80 ms (up to 4x) | No |
