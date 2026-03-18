# SSH Setup for SSHot

SSHot uses your existing SSH configuration to upload screenshots. This guide covers setting up passwordless SSH access.

## 1. Create or Locate Your SSH Key

If you already have an SSH key, skip to step 2. Otherwise:

```bash
ssh-keygen -t ed25519 -C "your-email@example.com"
```

This creates `~/.ssh/id_ed25519` (private) and `~/.ssh/id_ed25519.pub` (public).

## 2. Copy Your Public Key to the Remote Server

```bash
ssh-copy-id your-host
```

Or manually append `~/.ssh/id_ed25519.pub` to `~/.ssh/authorized_keys` on the remote.

## 3. Configure an SSH Host Alias (Recommended)

Add an entry to `~/.ssh/config`:

```
Host home
    HostName 192.168.1.100
    User youruser
    IdentityFile ~/.ssh/id_ed25519
```

Then use `home` as the SSH Host in SSHot settings.

## 4. Set Up ssh-agent (If Your Key Has a Passphrase)

SSHot uses `BatchMode=yes`, which means it cannot prompt for a passphrase. Your key must either be unencrypted or loaded into ssh-agent.

```bash
# Start the agent (macOS Keychain integration)
ssh-add --apple-use-keychain ~/.ssh/id_ed25519
```

On macOS, add this to `~/.ssh/config` to persist across reboots:

```
Host *
    AddKeysToAgent yes
    UseKeychain yes
```

## 5. Configure SSHot

1. Open SSHot settings from the menu bar
2. Set **SSH Host** to your host alias (e.g., `home`) or `user@hostname`
3. Set **Remote Path** to the upload directory (default: `~/.paste/`)
4. Optionally set **Identity File** if not using ssh-agent or `~/.ssh/config`
5. Click **Test Connection** to verify

## Troubleshooting

**"SSH key requires passphrase"**: Your key is passphrase-protected but not loaded into ssh-agent. Run `ssh-add` to load it.

**"Host key verification failed"**: The remote server's host key has changed (or you're connecting for the first time after a reinstall). Run:

```bash
ssh-keygen -R your-host
```

Then reconnect manually once (`ssh your-host`) to accept the new key, or let SSHot accept it automatically (`StrictHostKeyChecking=accept-new`).

**"Connection refused"**: Verify the SSH daemon is running on the remote server and the host/port are correct.

**"Connection timed out"**: Check network connectivity. SSHot uses a 10-second connection timeout and a 30-second overall upload timeout.
