# kpxc

Cached wrapper around `keepassxc-cli` for headless setups. Two modes:

- **Scope mode** (recommended): cache only specific entries' fields. The
  master password is used briefly during unlock and then discarded. An
  attacker reading the cache only gets the scoped credentials, not the
  master password — so the rest of the database stays safe even if your
  user account is compromised.
- **Master mode**: cache the master password. Allows any `keepassxc-cli`
  subcommand (browsing, search, edit). Convenient for interactive
  sessions; weaker against a compromised user account.

For headless / WSL / server setups using KeePassXC entries from CLI tools
(himalaya, mbsync, mutt, isync, restic) without a long-lived daemon.

> Unofficial third-party wrapper. Not affiliated with the KeePassXC project.

## Quickstart

```sh
git clone https://github.com/magnattic/kpxc ~/.local/share/kpxc
ln -s ~/.local/share/kpxc/bin/kpxc ~/.local/bin/kpxc

cat > ~/.config/kpxc/config <<'EOF'
KPXC_DB="/path/to/Passwords.kdbx"
KPXC_DEFAULT_SCOPE="Email/personal Backup/restic"
EOF
chmod 600 ~/.config/kpxc/config

kpxc unlock                       # type master once -> caches scoped credentials only
kpxc get "Email/personal"         # password
kpxc get "Email/personal" -a User # any keepassxc-cli show option
kpxc lock                         # clear cache
```

## Why scope mode is the better default

`kpxc` runs as your user. After `kpxc unlock`, anything else running as
your user (npm postinstall script, malicious VS Code extension,
compromised dev tool) can read the cache. That's the same threat that
applies to `pass`, `passhole`, `gpg-agent`, `ssh-agent` — by design.

Scope mode mitigates the blast radius:

- **Master mode**: the cache contains the master password. Steal it, and
  you can decrypt the entire `.kdbx` forever.
- **Scope mode**: the cache contains only the entries you opted into.
  Steal it, and you only get those entries. Your banking password,
  recovery phrases, GPG keys — anything outside the scope — stays safe.

The master password lives in process memory only during the few seconds
of `kpxc unlock`, then gets unset. After that, no file or process holds
it.

## Use

### Scope mode (default if KPXC_DEFAULT_SCOPE is set)

Set the scope in your config:

```sh
KPXC_DB="/path/to/db.kdbx"
KPXC_DEFAULT_SCOPE="Email/personal Email/work:Password,Username Backup/restic"
```

Or pass it on the command line:

```sh
kpxc unlock Email/personal Backup/restic       # ad-hoc scope
kpxc unlock Email/work:Password,Username       # specific fields
```

Format: space-separated entries. `path` alone caches the Password field.
`path:Field` caches one specific field. `path:Field1,Field2` caches
multiple fields on one entry.

After unlock, the cache holds only those credentials. `kpxc get` reads
from the cache directly; `keepassxc-cli` is not invoked again until
`kpxc unlock`.

```sh
kpxc unlock                              # cache scoped credentials
kpxc get Email/personal                  # works
kpxc get Email/personal -a Username      # works (Username was scoped)
kpxc get Banking/savings                 # ERROR: not in scope
kpxc scope                               # show what's cached (no values)
kpxc lock                                # clear
```

`kpxc ls`, `kpxc search`, `kpxc db-info` and other generic subcommands
**don't work in scope mode** (the master password is gone). For those
you need master mode.

### Master mode (full keepassxc-cli access)

```sh
kpxc unlock --master                     # explicit master mode
kpxc get Email/personal                  # works
kpxc ls /Email                           # works
kpxc search github                       # works
kpxc add -g -L 24 -u alice Email/foo     # works
kpxc lock
```

Activated by `--master`, or by `kpxc unlock` with no arguments and no
`KPXC_DEFAULT_SCOPE` set.

### Inspect the cache

```sh
kpxc scope
# Mode: scoped
# Entries:
#   Email/personal:Password
#   Email/personal:Username
#   Backup/restic:Password
```

Lists entries and fields. Never prints values.

## Why

`keepassxc-cli` is fast (it's the official C++ binary using native
Argon2/AES via Botan), but it prompts for the master password on every
invocation. That's unworkable when an MTA polls IMAP every 60 seconds or
when scripts make many lookups.

Existing solutions don't fit headless setups well:

- **kpsh / passhole** - pure-Python pykeepass-based daemons. With modern
  KeePassXC default KDF settings, the initial unlock can take *minutes*
  in pure Python (vs. seconds with the official binary).
- **git-credential-keepassxc** - needs the KeePassXC GUI running and
  unlocked, with the browser-extension protocol. Doesn't work headless.

`kpxc` is ~300 lines of bash that:

1. Prompts for the master password once (`kpxc unlock`).
2. In scope mode: extracts the requested fields, base64-encodes them,
   stores them at `/dev/shm/<uid>-kpxc.d/scoped` mode 0600, discards the
   master password.
3. In master mode: stores the master password at
   `/dev/shm/<uid>-kpxc.d/master` mode 0600.
4. `kpxc get` reads from the cache; in scope mode, no further KDF work
   is done.

The cache lives in RAM only (tmpfs is in-memory). Gone after reboot or
`kpxc lock`.

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

```sh
mkdir -p ~/.config/kpxc
cat > ~/.config/kpxc/config <<'EOF'
KPXC_DB="/path/to/your.kdbx"
KPXC_DEFAULT_SCOPE="Email/personal Backup/restic"   # entries to cache by default
# KPXC_KEYFILE="/path/to/keyfile"   # if your DB uses one
# KPXC_TTL=28800                    # optional: expire cache after 8h
EOF
chmod 600 ~/.config/kpxc/config   # required - kpxc refuses world/group-writable configs
```

## Integrate with other tools

Set `KPXC_DEFAULT_SCOPE` in your config so that `kpxc unlock` (no args)
caches exactly the credentials your tools need:

```sh
KPXC_DEFAULT_SCOPE="Email/personal Email/work Backup/restic"
```

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

## Subcommand denylist

A few `keepassxc-cli` subcommands are blocked because wrapping them
would corrupt data:

- `kpxc db-create / import / open / close / merge` - non-standard argument
  shape; injecting the database would target the wrong file.
- `kpxc add -p / edit -p / db-edit -p / db-edit --set-password` - these
  prompt for an additional password on stdin, but the cache holds only
  the master password. Use `-g` for a generated entry password, or
  invoke `keepassxc-cli` directly.

## Security model

**What kpxc protects against:**

- The master password is never passed as a command-line argument, so it
  doesn't appear in `ps aux` or shell history.
- Cache files are created atomically with `install -m 600 /dev/null`,
  so there's no readable window even before `chmod`.
- `set -euo pipefail` plus an `ERR/INT/TERM` trap ensure caches are
  removed if `kpxc unlock` is interrupted mid-write.
- Config files are not sourced unless owned by the current user and not
  group/world-writable. Prevents code injection via a writable config.
- Entry paths are passed to `keepassxc-cli show` after `--`, so an entry
  name starting with `-` cannot be misinterpreted as an option.
- **Scope mode**: an attacker reading the cache only gets the scoped
  credentials, not the master password. The rest of the database stays
  safe.

**What kpxc does *not* protect against:**

- **Root.** A root user can read any process memory or any file on the
  system. Not a goal here.
- **Memory forensics during unlock.** During the few seconds of
  `kpxc unlock`, the master password sits in the bash process memory. A
  process with `ptrace` privileges can extract it.
- **A compromised user account in master mode.** Any process running as
  your user can read `/dev/shm/<uid>-kpxc.d/master`. Use scope mode if
  you care.
- **A compromised user account in scope mode.** Same caveat for scoped
  credentials, but the blast radius is bounded: only the scoped entries
  are exposed.
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

- [passhole](https://github.com/Evidlo/passhole): pure-Python CLI
  password manager, pass-style. Has a richer interactive interface (add,
  type, generate as first-class commands, dmenu integration) and
  built-in TOTP. Best fit for default-KDF databases and interactive
  desktop use; the pure-Python KDF makes it slow on high-rounds
  databases.
- [kpsh](https://git.goral.net.pl/keepass-shell.git): pure-Python
  daemon, same KDF caveat as passhole.
- [git-credential-keepassxc](https://github.com/Frederick888/git-credential-keepassxc):
  talks to a running KeePassXC GUI via the browser-extension protocol.
  Best if you have a GUI session anyway.
- [pass](https://www.passwordstore.org/): drop KeePass, use GPG-encrypted
  files with `gpg-agent` for caching. Larger migration.

## License

MIT, see [LICENSE](LICENSE).
