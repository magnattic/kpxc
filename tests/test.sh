#!/usr/bin/env bash
# Integration tests for kpxc.
#
# Builds an ephemeral test database with low KDF rounds, exercises both
# master-mode and scope-mode end-to-end.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$REPO_ROOT/bin"

if ! command -v keepassxc-cli >/dev/null 2>&1; then
  echo "keepassxc-cli not found in PATH" >&2
  exit 1
fi

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

DB="$WORKDIR/test.kdbx"
CACHE_DIR="$WORKDIR/cache.d"
MASTER_PW="kpxc-testpw"

export KPXC_DB="$DB"
export KPXC_CACHE="$CACHE_DIR"
export KPXC_RC="$WORKDIR/no-such-rc"
export KPXC_SCOPE="$WORKDIR/no-such-scope"
export PATH="$BIN:$PATH"

build_fixture() {
  printf '%s\n%s\n' "$MASTER_PW" "$MASTER_PW" \
    | keepassxc-cli db-create -q -p -t 100 "$DB"
  for group in Email Servers Backup; do
    printf '%s\n' "$MASTER_PW" \
      | keepassxc-cli mkdir -q "$DB" "$group"
  done
  printf '%s\n%s\n%s\n' "$MASTER_PW" "secret123" "secret123" \
    | keepassxc-cli add -q -p -u alice --url "https://mail.example.com" "$DB" Email/personal
  printf '%s\n%s\n%s\n' "$MASTER_PW" "prodpw" "prodpw" \
    | keepassxc-cli add -q -p -u admin --url "https://prod.example.com" "$DB" Servers/prod
  printf '%s\n%s\n%s\n' "$MASTER_PW" "resticpw" "resticpw" \
    | keepassxc-cli add -q -p "$DB" Backup/restic
}

prime_master_cache() {
  rm -rf "$CACHE_DIR"
  install -d -m 0700 "$CACHE_DIR"
  install -m 600 /dev/null "$CACHE_DIR/master"
  printf '%s\n' "$MASTER_PW" > "$CACHE_DIR/master"
}

prime_scoped_cache() {
  # Args: list of "path:field=value" triples
  rm -rf "$CACHE_DIR"
  install -d -m 0700 "$CACHE_DIR"
  install -m 600 /dev/null "$CACHE_DIR/scoped"
  for triple in "$@"; do
    local pf="${triple%%=*}"
    local v="${triple#*=}"
    local p="${pf%%:*}"
    local f="${pf#*:}"
    printf '%s\t%s\t%s\n' "$p" "$f" "$(printf '%s' "$v" | base64 -w0)" >> "$CACHE_DIR/scoped"
  done
}

clear_cache() { rm -rf "$CACHE_DIR"; }

PASS=0
FAIL=0

check() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    printf '  ok   %s\n' "$name"
    PASS=$((PASS + 1))
  else
    printf '  FAIL %s\n       expected: %q\n       actual:   %q\n' "$name" "$expected" "$actual"
    FAIL=$((FAIL + 1))
  fi
}

check_contains() {
  local name="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    printf '  ok   %s\n' "$name"
    PASS=$((PASS + 1))
  else
    printf '  FAIL %s\n       expected to contain: %q\n       actual:              %q\n' \
      "$name" "$needle" "$haystack"
    FAIL=$((FAIL + 1))
  fi
}

check_fails() {
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then
    printf '  FAIL %s (command unexpectedly succeeded)\n' "$name"
    FAIL=$((FAIL + 1))
  else
    printf '  ok   %s\n' "$name"
    PASS=$((PASS + 1))
  fi
}

# Run command, assert: exit 0, empty stderr, and stdout == expected.
# Catches silent failures that "$(cmd)" would mask (non-zero exit + warning
# on stderr that the user never sees).
check_clean() {
  local name="$1" expected="$2"; shift 2
  local out_f err_f code=0
  out_f=$(mktemp); err_f=$(mktemp)
  "$@" >"$out_f" 2>"$err_f" || code=$?
  local actual_stdout actual_stderr
  actual_stdout=$(cat "$out_f")
  actual_stderr=$(cat "$err_f")
  rm -f "$out_f" "$err_f"

  if (( code != 0 )); then
    printf '  FAIL %s (exit %d)\n       stderr: %q\n' "$name" "$code" "$actual_stderr"
    FAIL=$((FAIL + 1))
    return
  fi
  if [[ -n "$actual_stderr" ]]; then
    printf '  FAIL %s (stderr not empty)\n       stderr: %q\n' "$name" "$actual_stderr"
    FAIL=$((FAIL + 1))
    return
  fi
  if [[ "$expected" != "$actual_stdout" ]]; then
    printf '  FAIL %s\n       expected: %q\n       actual:   %q\n' "$name" "$expected" "$actual_stdout"
    FAIL=$((FAIL + 1))
    return
  fi
  printf '  ok   %s\n' "$name"
  PASS=$((PASS + 1))
}

echo "Building fixture..."
build_fixture

echo
echo "## kpxc get without cache"
clear_cache
check_fails "kpxc get exits non-zero without cache" kpxc get Email/personal
check_fails "kpxc show exits non-zero without cache" kpxc show -a Password Email/personal

echo
echo "## kpxc get with master cache (legacy mode)"
prime_master_cache
check_clean "kpxc get default returns Password" "secret123" kpxc get Email/personal
check_clean "kpxc get -a Username returns user" "alice" kpxc get Email/personal -a Username
check_clean "kpxc get -a URL returns URL" "https://prod.example.com" kpxc get Servers/prod -a URL
check_clean "kpxc get Backup/restic returns Password" "resticpw" kpxc get Backup/restic

echo
echo "## kpxc generic wrapper (master mode)"
check_contains "kpxc ls /Email lists personal" "personal" "$(kpxc ls /Email)"
check_contains "kpxc search prod finds entry" "prod" "$(kpxc search prod)"
check_contains "kpxc db-info shows cipher" "Cipher:" "$(kpxc db-info)"

echo
echo "## kpxc scope (master mode)"
scope_out="$(kpxc scope)"
check_contains "kpxc scope reports master mode" "master" "$scope_out"

echo
echo "## kpxc get with scoped cache"
prime_scoped_cache \
  "Email/personal:Password=secret123" \
  "Email/personal:Username=alice" \
  "Backup/restic:Password=resticpw"
check_clean "kpxc get default returns scoped Password" "secret123" kpxc get Email/personal
check_clean "kpxc get -a Username returns scoped Username" "alice" kpxc get Email/personal -a Username
check_clean "kpxc get scoped Backup/restic" "resticpw" kpxc get Backup/restic

echo
echo "## kpxc get refuses out-of-scope entries"
check_fails "kpxc get refuses unscoped entry" kpxc get Servers/prod
err_out="$(kpxc get Servers/prod 2>&1 || true)"
check_contains "out-of-scope error mentions 'not in current scope'" "not in current scope" "$err_out"
check_fails "kpxc get refuses unscoped field on scoped entry" kpxc get Email/personal -a URL

echo
echo "## generic subcommands refuse scope mode"
check_fails "kpxc ls refuses scope-only cache" kpxc ls /Email
err_out="$(kpxc ls /Email 2>&1 || true)"
check_contains "ls error suggests --master" "kpxc unlock --master" "$err_out"
check_fails "kpxc search refuses scope-only cache" kpxc search foo
check_fails "kpxc db-info refuses scope-only cache" kpxc db-info
check_fails "kpxc add refuses scope-only cache" kpxc add -u bob Email/new

echo
echo "## kpxc scope (scope mode) lists entries without values"
scope_out="$(kpxc scope)"
check_contains "scope shows mode" "Mode: scoped" "$scope_out"
check_contains "scope lists entry+field" "Email/personal:Password" "$scope_out"
check_contains "scope lists Username" "Email/personal:Username" "$scope_out"
[[ "$scope_out" != *"secret123"* ]] && {
  printf '  ok   scope output does not leak values\n'; PASS=$((PASS + 1))
} || {
  printf '  FAIL scope output leaked a value\n'; FAIL=$((FAIL + 1))
}

echo
echo "## kpxc passthrough (no DB, no cache needed)"
clear_cache
generated="$(kpxc generate -L 12 -l -U -n)"
check "kpxc generate produces 12 chars" "12" "${#generated}"

echo
echo "## kpxc denylists in master mode"
prime_master_cache
check_fails "kpxc db-create refuses (non-standard arg shape)" \
  kpxc db-create "$WORKDIR/new.kdbx"
check_fails "kpxc import refuses (would overwrite target)" \
  kpxc import "$WORKDIR/source.xml" "$WORKDIR/dest.kdbx"
check_fails "kpxc open refuses" kpxc open "$WORKDIR/other.kdbx"
check_fails "kpxc add -p refuses" kpxc add -p -u alice "Email/new"
check_fails "kpxc edit -p refuses" kpxc edit -p "Email/personal"
check_fails "kpxc db-edit -p refuses" kpxc db-edit -p
check_fails "kpxc db-edit --set-password refuses" kpxc db-edit --set-password
check_contains "kpxc add (no -p) is allowed" "Successfully" \
  "$(kpxc add -u bob "Email/no-pw" 2>&1)"

echo
echo "## kpxc subcommand --help passthrough"
help_out="$(kpxc show --help 2>&1 || true)"
check_contains "kpxc show --help renders help" "Show an entry" "$help_out"
help_out="$(kpxc ls -h 2>&1 || true)"
check_contains "kpxc ls -h renders help" "List database" "$help_out"

echo
echo "## kpxc top-level help"
help_out="$(kpxc 2>&1 || true)"
check_contains "kpxc with no args prints usage" "Usage" "$help_out"

echo
echo "## config permission check (security)"
PERM_RC="$WORKDIR/perm-test-rc"
echo 'KPXC_DB='"$DB" > "$PERM_RC"
chmod 666 "$PERM_RC"
check_fails "kpxc get refuses world-writable config" \
  env KPXC_RC="$PERM_RC" kpxc get Email/personal
check_fails "kpxc ls refuses world-writable config" \
  env KPXC_RC="$PERM_RC" kpxc ls /
chmod 600 "$PERM_RC"
prime_master_cache
check "kpxc get accepts 0600 config" "secret123" \
  "$(env KPXC_RC="$PERM_RC" kpxc get Email/personal)"

echo
echo "## TTL expiry"
prime_master_cache
sleep 1
check_fails "master-mode kpxc get with KPXC_TTL=0 expires" env KPXC_TTL=0 kpxc get Email/personal
prime_scoped_cache "Email/personal:Password=secret123"
sleep 1
check_fails "scoped kpxc get with KPXC_TTL=0 expires" env KPXC_TTL=0 kpxc get Email/personal

echo
echo "## kpxc lock"
prime_master_cache
kpxc lock >/dev/null
[[ ! -e "$CACHE_DIR/master" && ! -e "$CACHE_DIR/scoped" ]] && {
  printf '  ok   kpxc lock removes both cache files\n'; PASS=$((PASS + 1))
} || {
  printf '  FAIL kpxc lock left cache files behind\n'; FAIL=$((FAIL + 1))
}
prime_scoped_cache "Email/personal:Password=secret123"
kpxc lock >/dev/null
[[ ! -e "$CACHE_DIR/scoped" ]] && {
  printf '  ok   kpxc lock removes scoped cache\n'; PASS=$((PASS + 1))
} || {
  printf '  FAIL kpxc lock did not remove scoped cache\n'; FAIL=$((FAIL + 1))
}
output="$(kpxc lock)"
check "kpxc lock on no cache prints (no cache)" "(no cache)" "$output"

echo
echo "## values containing tabs/newlines survive base64 round-trip"
prime_scoped_cache $'Email/quirky:Password=line1\nline2\ttabbed'
expected=$'line1\nline2\ttabbed'
check_clean "scoped cache preserves newlines and tabs" "$expected" kpxc get Email/quirky

echo
echo "## migration: legacy v0.3 cache file path"
clear_cache
touch "$CACHE_DIR"   # simulate v0.3.x file at the location now used as a dir
err_out="$(kpxc scope 2>&1 || true)"
check_contains "kpxc detects legacy cache file and aborts" "legacy v0.3.x cache file" "$err_out"
rm -f "$CACHE_DIR"

echo
echo "## scope file load and permission check"
SCOPE_PATH="$WORKDIR/scope-test"
echo 'Email/personal' > "$SCOPE_PATH"
chmod 666 "$SCOPE_PATH"
prime_scoped_cache "Email/personal:Password=secret123"
err_out="$(env KPXC_SCOPE="$SCOPE_PATH" kpxc scope 2>&1 || true)"
check_contains "scope command refuses world-writable scope file" "group/world-writable" "$err_out"
chmod 600 "$SCOPE_PATH"
out="$(env KPXC_SCOPE="$SCOPE_PATH" kpxc scope 2>&1 || true)"
check_contains "scope command shows scope file when 0600" "Saved scope" "$out"
check_contains "scope command lists entry from scope file" "Email/personal" "$out"

echo
echo "## scope file roundtrip preserves tricky paths/fields"
# Regression: C3 (spaces in path got word-split) and C4 (':' was treated as
# the field separator, breaking entry titles like "Email/foo: bar").
TRICKY="$WORKDIR/scope-tricky"
{
  printf '%s\n' 'Email/My Personal Account'
  printf '%s\t%s\n' 'Servers/prod' 'Username'
  printf '%s\t%s\n' 'Notes/Has:Colon' 'Password,URL'
  printf '# a comment\n'
  printf '   \n'   # blank-ish line
} > "$TRICKY"
chmod 600 "$TRICKY"
out="$(env KPXC_SCOPE="$TRICKY" kpxc scope 2>&1 || true)"
check_contains "scope file preserves spaces in path" "Email/My Personal Account" "$out"
check_contains "scope file preserves TAB-separated Username field" $'Servers/prod\tUsername' "$out"
check_contains "scope file preserves colon in entry title" "Notes/Has:Colon" "$out"
check_contains "scope file does not echo comment lines" "Saved scope" "$out"
[[ "$out" != *"a comment"* ]] && {
  printf '  ok   scope file strips comments\n'; PASS=$((PASS + 1))
} || {
  printf '  FAIL scope file leaked comment to output\n'; FAIL=$((FAIL + 1))
}

echo
echo "## scope file: legacy v0.4.1 ':' syntax migration warning"
LEGACY="$WORKDIR/scope-legacy"
{
  printf '%s\n' 'Email/personal:Username'
  printf '%s\n' 'Backup/restic:Password,URL'
} > "$LEGACY"
chmod 600 "$LEGACY"
err_out="$(env KPXC_SCOPE="$LEGACY" kpxc scope 2>&1 || true)"
check_contains "legacy ':' syntax triggers migration warning" "legacy v0.4.1" "$err_out"
check_contains "warning lists offending line" "Email/personal:Username" "$err_out"
# Real entry titles with ':' should NOT trigger the warning.
NONLEGACY="$WORKDIR/scope-nonlegacy"
printf '%s\t%s\n' 'Notes/Has:Colon' 'Password' > "$NONLEGACY"
chmod 600 "$NONLEGACY"
err_out="$(env KPXC_SCOPE="$NONLEGACY" kpxc scope 2>&1 || true)"
[[ "$err_out" != *"legacy v0.4.1"* ]] && {
  printf '  ok   real entry with TAB+colon does not falsely trigger warning\n'; PASS=$((PASS + 1))
} || {
  printf '  FAIL warning fired on a non-legacy entry\n'; FAIL=$((FAIL + 1))
}

echo
echo "## kpxc lock: refuses to remove cache dir with stray files"
rm -rf "$CACHE_DIR"
install -d -m 0700 "$CACHE_DIR"
touch "$CACHE_DIR/some-other-file"
err_out="$(kpxc lock 2>&1 || true)"
check_contains "lock refuses dir with stray files" "refusing to remove" "$err_out"
[[ -d "$CACHE_DIR" && -f "$CACHE_DIR/some-other-file" ]] && {
  printf '  ok   lock left stray file untouched\n'; PASS=$((PASS + 1))
} || {
  printf '  FAIL lock removed stray file or its directory\n'; FAIL=$((FAIL + 1))
}
rm -rf "$CACHE_DIR"

echo
echo "## unlock requires TTY"
clear_cache
err_out="$(echo somepw | kpxc unlock 2>&1 || true)"
check_contains "unlock without TTY produces clear error" "requires a TTY" "$err_out"

echo
echo "## picker has fzf-required error path"
# The picker is only reachable after password prompt (TTY-only), so end-to-end
# testing isn't practical here. Verify the fzf-missing message exists.
check_contains "fzf-required message present in script" \
  "picker requires fzf" "$(grep -m1 'picker requires fzf' "$BIN/kpxc" || true)"

echo
echo "## Results"
printf 'Passed: %d   Failed: %d\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
