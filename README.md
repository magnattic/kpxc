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
ln -s ~/.local/share/kpxc/bin/kpxc ~/.local/bin/kpxc

export KPXC_DB=~/Passwords.kdbx
kpxc unlock                       # type master password once
kpxc get "Email/personal"         # password, no prompt
kpxc get "Email/personal" -a User # any keepassxc-cli show option
kpxc ls /Email                    # any keepassxc-cli subcommand
kpxc lock                         # clear the cache
```

## Why

`keepassxc-cli` is fast (it's the official C++ binary using native
Argon2/AES via Botan), but it prompts for the master password on every
invocation. That's unworkable when an MTA polls IMAP every 60 seconds or
when scripts make many lookups.

Existing solutions don't fit headless setups well:

- **kpsh / passhole** - pure-Python pykeepass-based daemons. With modern
  KeePassXC default KDF settings, the initial unlock can take *minutes* in
  pure Python (vs. seconds with the official binary).
- **git-credential-keepassxc** - needs the KeePassXC GUI running and
  unlocked, with the browser-extension protocol. Doesn't work headless.

`kpxc` is ~200 lines of bash that:

1. Prompts for the master password once (`kpxc unlock`).
2. Stores it in `/dev/shm/<uid>-kpxc` with mode `0600`.
3. Each subsequent `kpxc <subcommand>` reads from the cache and shells out
   to `keepassxc-cli`. Fast because it's the official binary.

The master password lives in RAM only (tmpfs is in-memory). It's gone
after reboot or `kpxc lock`.

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
ln -s ~/.local/share/kpxc/bin/kpxc ~/.local/bin/kpxc
```

Make sure `~/.local/bin` is in your `$PATH`.

## Configure

Set the database path either as an env var or in
`~/.config/kpxc/config`:

```sh
mkdir -p ~/.config/kpxc
cat > ~/.config/kpxc/config <<'EOF'
KPXC_DB="/path/to/your.kdbx"
# KPXC_KEYFILE="/path/to/keyfile"   # if your DB uses one
# KPXC_TTL=28800                    # optional: expire cache after 8h
EOF
chmod 600 ~/.config/kpxc/config   # required - kpxc refuses world/group-writable configs
```

## Use

```sh
kpxc unlock                              # prompts for master password, caches it
kpxc get "Email/personal"                # prints the password (hot path for scripts)
kpxc get "Email/personal" -a Username    # prints the username
kpxc get "Servers/prod" -a URL           # any keepassxc-cli show -a value
kpxc get "Email/personal" -s             # show all attributes
kpxc lock                                # clears the cache (manual lock)
```

For everything beyond `get`, kpxc forwards any `keepassxc-cli` subcommand
with the cached password injected:

```sh
kpxc ls /Email                        # list entries in a group
kpxc search github                    # full-text search
kpxc db-info                          # database metadata
kpxc add -g -L 24 -u alice Email/foo  # add entry with a generated password
kpxc rm Email/old                     # remove an entry
kpxc mv Email/foo Archive/foo         # move an entry
kpxc generate -L 32                   # standalone password generator (no DB needed)
```

A few subcommands are blocked because wrapping them would corrupt data:

- `kpxc db-create / import / open / close / merge` - non-standard argument
  shape; injecting the database would target the wrong file.
- `kpxc add -p / edit -p / db-edit -p / db-edit --set-password` - these
  prompt for an additional password on stdin, but the cache holds only
  the master password. Use `-g` for a generated entry password, or invoke
  `keepassxc-cli` directly.

## Integrate with other tools

### himalaya (CLI mail client)

```toml
# ~/.config/himalaya/config.toml, tested with himalaya v1.2+
backend.auth.cmd = "kpxc get Email/personal"
```

### mbsync / isync

```
# ~/.mbsyncrc
PassCmd "+kpxc get 'Email/personal'"
```

The `+` prefix tells mbsync to suppress logging the command.

### mutt

```
set imap_pass = "`kpxc get Email/personal`"
```

### restic

```sh
export RESTIC_PASSWORD_COMMAND="kpxc get Backup/restic-repo"
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
  removed if `kpxc unlock` is interrupted mid-write.
- Config files are not sourced unless owned by the current user and not
  group/world-writable. Prevents code injection via a writable config.
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

- [passhole](https://github.com/Evidlo/passhole): pure-Python CLI password
  manager, pass-style. Has a richer interactive interface (add, type,
  generate as first-class commands, dmenu integration) and built-in TOTP.
  Best fit for default-KDF databases and interactive desktop use; the
  pure-Python KDF makes it slow on high-rounds databases.
- [kpsh](https://git.goral.net.pl/keepass-shell.git): pure-Python daemon,
  same KDF caveat as passhole.
- [git-credential-keepassxc](https://github.com/Frederick888/git-credential-keepassxc):
  talks to a running KeePassXC GUI via the browser-extension protocol.
  Best if you have a GUI session anyway.
- [pass](https://www.passwordstore.org/): drop KeePass, use GPG-encrypted
  files with `gpg-agent` for caching. Larger migration.

## License

MIT, see [LICENSE](LICENSE).
