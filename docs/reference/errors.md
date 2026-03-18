# Error Reference

SSHot surfaces errors through macOS notifications and the menu bar status text.

## Error Types

### timeout

SCP exceeded the 30-second upload timeout.

**Cause**: Slow network, large image, or unresponsive remote server.

**Resolution**: Check network connectivity. If uploading large images on a slow connection, the 30-second timeout plus one retry gives up to 62 seconds total.

### scpFailed

SCP exited with a non-zero exit code. Subcategorized by stderr content:

#### Host Key Mismatch

**Notification**: "Host key verification failed" with guidance to run `ssh-keygen -R <host>`.

**Cause**: The remote server's host key has changed since it was last accepted (server reinstalled, IP reassigned, or MITM).

**Resolution**: Run `ssh-keygen -R <host>` to remove the old key, then reconnect manually or let SSHot accept the new key.

#### Auth Failure

**Notification**: "SSH key requires passphrase — ensure ssh-agent is running."

**Cause**: The SSH key is passphrase-protected and not loaded into ssh-agent. `BatchMode=yes` prevents interactive passphrase prompts.

**Resolution**: Run `ssh-add ~/.ssh/id_ed25519` (or your key path) to load the key into the agent.

#### Connection Refused

**Cause**: SSH daemon not running on the remote server, or wrong host/port.

**Resolution**: Verify the SSH service is running and the host configuration is correct.

### processLaunchFailed

The SCP or SSH binary could not be launched.

**Cause**: `/usr/bin/scp` or `/usr/bin/ssh` is missing or not executable. This could happen on a non-standard macOS installation or if Command Line Tools are not installed.

**Resolution**: Install Xcode Command Line Tools: `xcode-select --install`.

### imageTooLarge

The clipboard image exceeds the 20 MB size limit.

**Notification**: Explains that the image was skipped due to size.

**Resolution**: Use a smaller image or reduce the screenshot resolution.

### mkdirFailed

The remote directory preflight (`ssh mkdir -p <path>`) failed.

**Cause**: Permission denied on the remote server, or the path is invalid.

**Resolution**: Verify the remote path is valid and you have write permissions. Check SSH access manually: `ssh <host> 'mkdir -p <path>'`.

### invalidSettings

Settings validation failed before attempting upload. This is a defense-in-depth check — the settings UI also validates in real time.

**Cause**: SSH host or remote path contains invalid characters (whitespace, shell metacharacters), or identity file doesn't exist.

**Resolution**: Open SSHot settings and correct the highlighted fields.

## Retry Behavior

SSHot retries once on transient SCP failures (non-zero exit code that isn't a timeout). The retry happens after a 2-second delay. Errors are only surfaced to the user after the retry also fails.

Timeouts are not retried — a 30-second timeout strongly suggests a persistent connectivity issue.
