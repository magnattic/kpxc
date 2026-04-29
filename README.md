# kpxc

Cached wrapper around `keepassxc-cli`: unlock once per session, then run any
KeePassXC subcommand without reprompting for the master password.

For headless / WSL / server setups where you want to use KeePassXC entries
from CLI tools (himalaya, mbsync, mutt, isync, restic) without typing the
master password each time and without running a long-lived daemon.

> Unofficial third-party wrapper. Not affiliated with the KeePassXC project.

## Quickstart

```sh
git clone https://github.com/magnattic/kpxc ~/.local/share/kpxc
ln -s ~/.local/share/kpxc/bin/kp{unlock,get,lock,xc} ~/.local/bin/

export KP_DB=~/Passwords.kdbx
kpunlock                       # type master password once
kpget "Email/personal"         # password, no prompt
kpget "Email/personal" -a User # any keepassxc-cli show option
kpxc ls /Email                 # any keepassxc-cli subcommand
kplock                         # clear the cache
```

## Why

`keepassxc-cli` is fast (it's the official C++ binary using native
Argon2/AES via Botan), but it prompts for the master password on every
invocation. That's unworkable when an MTA polls IMAP every 60 seconds or
when scripts make many lookups.

Existing solutions don't fit headless setups well:

- **kpsh** - Python daemon, but uses pure-Python Argon2/AES. With modern
  KeePassXC default KDF settings, the initial unlock can take *minutes*
  in pure Python (vs. seconds with the official binary).
- **git-credential-keepassxc** - needs the KeePassXC GUI running and
  unlocked, with the browser-extension protocol. Doesn't work headless.
- **keepasxcli-wrapper** - unmaintained since 2021.

`kpxc` is ~120 lines of bash that:

1. Prompts for the master password once (`kpunlock`).
2. Stores it in `/dev/shm/<uid>-kpxc` with mode `0600`.
3. Each subsequent `kpget` / `kpxc` reads from the cache and shells out
   to `keepassxc-cli`. Fast because it's the official binary.

The master password lives in RAM only (tmpfs is in-memory). It's gone
after reboot or `kplock`.

## Install

### Dependencies

You need `keepassxc-cli` in `$PATH`.

```sh
# Debian/Ubuntu (newer releases also have keepassxc-minimal, no GUI deps)
sudo apt install keepassxc

# Arch
sudo pacman -S keepassxc

# Fedora
sudo dnf install keepassxc

# macOS: brew installs the CLI inside the .app bundle, symlink it into PATH:
brew install --cask keepassxc
sudo ln -s /Applications/KeePassXC.app/Contents/MacOS/keepassxc-cli \
           /usr/local/bin/keepassxc-cli
```

### kpxc itself

```sh
git clone https://github.com/magnattic/kpxc ~/.local/share/kpxc
ln -s ~/.local/share/kpxc/bin/kp{unlock,get,lock,xc} ~/.local/bin/
```

Make sure `~/.local/bin` is in your `$PATH`.

## Configure

Set the database path either as an env var or in
`~/.config/kpxc/config`:

```sh
mkdir -p ~/.config/kpxc
cat > ~/.config/kpxc/config <<'EOF'
KP_DB="/path/to/your.kdbx"
# KP_KEYFILE="/path/to/keyfile"   # if your DB uses one
# KP_TTL=28800                    # optional: expire cache after 8h
EOF
chmod 600 ~/.config/kpxc/config   # required - kpxc refuses world/group-writable configs
```

## Use

Two commands cover almost everything:

```sh
kpunlock                              # prompts for master password, caches it
kpget "Email/personal"                # prints the password (hot path for scripts)
kpget "Email/personal" -a Username    # prints the username
kpget "Servers/prod" -a URL           # any keepassxc-cli show -a value
kpget "Email/personal" -s             # show all attributes
kplock                                # clears the cache (manual lock)
```

For everything beyond `show`, use the generic wrapper:

```sh
kpxc ls /Email                        # list entries in a group
kpxc search github                    # full-text search
kpxc db-info                          # database metadata
kpxc show -a Password Servers/prod    # equivalent to kpget Servers/prod
```

`kpxc` forwards any `keepassxc-cli` subcommand and injects the cached
password automatically. `kpget` is just a shortcut for the most common
case (printing one attribute) and stays terse in config files.

## Integrate with other tools

### himalaya (CLI mail client)

```toml
# ~/.config/himalaya/config.toml, tested with himalaya v1.2+
backend.auth.cmd = "kpget Email/personal"
```

### mbsync / isync

```
# ~/.mbsyncrc
PassCmd "+kpget 'Email/personal'"
```

The `+` prefix tells mbsync to suppress logging the command.

### mutt

```
set imap_pass = "`kpget Email/personal`"
```

### restic

```sh
export RESTIC_PASSWORD_COMMAND="kpget Backup/restic-repo"
restic snapshots
```

See [`examples/`](examples/) for full configs.

## Security model

**What kpxc protects against:**

- The master password is never passed as a command-line argument, so it
  doesn't appear in `ps aux` or shell history.
- The cache file is created atomically with `install -m 600 /dev/null`,
  so there's no readable window even before `chmod`.
- `set -euo pipefail` plus an `ERR/INT/TERM` trap ensure the cache is
  removed if `kpunlock` is interrupted mid-write.
- Entry paths are passed to `keepassxc-cli show` after `--`, so an entry
  name starting with `-` cannot be misinterpreted as an option.

**What kpxc does *not* protect against:**

- **Root.** A root user can read any process memory or any file on the
  system. Not a goal here.
- **Memory forensics.** The decrypted master password sits in tmpfs RAM.
  An attacker with kernel access (or a coredump) can read it.
- **A compromised user account.** Any other process running as your user
  can read `/dev/shm/<uid>-kpxc`. The model assumes your local user is
  trusted.
- **Hardware tokens (YubiKey challenge-response).** Not currently
  supported. PRs welcome.

If your threat model requires per-process secret isolation, hardware
tokens, or memory hardening, use a kernel-keyring solution or the
KeePassXC Secret Service integration with a running GUI session.

## Why not just lower the KDF rounds?

You could lower the Argon2 (or AES-KDF) parameters in the database
settings to make pykeepass-based daemons (kpsh, passhole) usable. But
that weakens the KDF's brute-force resistance against an attacker who
has stolen the `.kdbx` file. Sticking with the official KeePassXC binary
(which has native C Argon2 via Botan) means you keep the strong KDF and
still get fast lookups.

## Alternatives

- [kpsh](https://git.goral.net.pl/keepass-shell.git): daemon, pure-Python
  pykeepass. Good if your DB uses moderate KDF rounds.
- [git-credential-keepassxc](https://github.com/Frederick888/git-credential-keepassxc):
  talks to a running KeePassXC GUI via the browser-extension protocol.
  Best if you have a GUI session anyway.
- [pass](https://www.passwordstore.org/): drop KeePass, use GPG-encrypted
  files with `gpg-agent` for caching. Larger migration.

## License

MIT, see [LICENSE](LICENSE).
