#!/usr/bin/env bash
# Integration tests for kpxc.
#
# Builds an ephemeral test database with low KDF rounds, primes the cache
# directly, and exercises kpget/kpxc/kplock against it. Exits non-zero on
# any failure.
#
# Run from anywhere: bash tests/test.sh

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
CACHE="$WORKDIR/cache"
MASTER_PW="kpxc-testpw"

export KP_DB="$DB"
export KP_CACHE="$CACHE"
export KP_CONFIG="$WORKDIR/no-such-config"
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

prime_cache() {
  install -m 600 /dev/null "$CACHE"
  printf '%s' "$MASTER_PW" > "$CACHE"
}

clear_cache() { rm -f "$CACHE"; }

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

echo "Building fixture (this takes ~1s for the low-rounds KDF)..."
build_fixture

echo
echo "## kpget without cache"
clear_cache
check_fails "kpget exits non-zero without cache" kpget Email/personal
check_fails "kpxc show exits non-zero without cache" kpxc show -a Password Email/personal

echo
echo "## kpget with cache"
prime_cache
check "kpget default returns Password" "secret123" "$(kpget Email/personal)"
check "kpget -a Username returns user" "alice" "$(kpget Email/personal -a Username)"
check "kpget -a URL returns URL" "https://prod.example.com" "$(kpget Servers/prod -a URL)"
check "kpget Backup/restic returns Password" "resticpw" "$(kpget Backup/restic)"

echo
echo "## kpxc generic wrapper"
check_contains "kpxc ls /Email lists personal" "personal" "$(kpxc ls /Email)"
check_contains "kpxc search prod finds entry" "prod" "$(kpxc search prod)"
check_contains "kpxc db-info shows cipher" "Cipher:" "$(kpxc db-info)"
check "kpxc show -a Password matches kpget" "secret123" \
  "$(kpxc show -q -a Password -- Email/personal | tr -d '\r')"

echo
echo "## kpxc passthrough (no DB, no cache needed)"
clear_cache
generated="$(kpxc generate -L 12 -l -U -n)"
check "kpxc generate produces 12 chars" "12" "${#generated}"

echo
echo "## kpxc denylists (refuses unsafe / mutating subcommands)"
prime_cache
check_fails "kpxc db-create refuses (non-standard arg shape)" \
  kpxc db-create "$WORKDIR/new.kdbx"
check_fails "kpxc import refuses (would overwrite target)" \
  kpxc import "$WORKDIR/source.xml" "$WORKDIR/dest.kdbx"
check_fails "kpxc open refuses" kpxc open "$WORKDIR/other.kdbx"
check_fails "kpxc add -p refuses (would create empty-pw entry)" \
  kpxc add -p -u alice "Email/new"
check_fails "kpxc edit -p refuses" kpxc edit -p "Email/personal"
check_fails "kpxc db-edit -p refuses" kpxc db-edit -p
check_fails "kpxc db-edit --set-password refuses" kpxc db-edit --set-password
check_contains "kpxc add (no -p) is allowed and creates entry" "Successfully" \
  "$(kpxc add -u bob "Email/no-pw" 2>&1)"

echo
echo "## kpxc subcommand --help passthrough"
# keepassxc-cli exits non-zero on --help (its arg parser flags missing
# positionals before checking the help flag), so allow non-zero here.
help_out="$(kpxc show --help 2>&1 || true)"
check_contains "kpxc show --help renders help (no DB injection)" \
  "Show an entry" "$help_out"
help_out="$(kpxc ls -h 2>&1 || true)"
check_contains "kpxc ls -h renders help" "List database" "$help_out"

echo
echo "## config permission check (security)"
PERM_CONFIG="$WORKDIR/perm-test-config"
echo 'KP_DB='"$DB" > "$PERM_CONFIG"
chmod 644 "$PERM_CONFIG"   # group/world-readable but world-writable is the threat
chmod 666 "$PERM_CONFIG"
check_fails "kpget refuses world-writable config" \
  env KP_CONFIG="$PERM_CONFIG" kpget Email/personal
check_fails "kpxc refuses world-writable config" \
  env KP_CONFIG="$PERM_CONFIG" kpxc ls /
chmod 600 "$PERM_CONFIG"
check "kpget accepts 0600 config" "secret123" \
  "$(env KP_CONFIG="$PERM_CONFIG" kpget Email/personal)"

echo
echo "## TTL expiry"
prime_cache
sleep 1
check_fails "kpget with KP_TTL=0 expires" env KP_TTL=0 kpget Email/personal
prime_cache
sleep 1
check_fails "kpxc with KP_TTL=0 expires" env KP_TTL=0 kpxc ls /Email

echo
echo "## kplock"
prime_cache
kplock >/dev/null
if [[ ! -e "$CACHE" ]]; then
  printf '  ok   kplock removes cache file\n'
  PASS=$((PASS + 1))
else
  printf '  FAIL kplock did not remove cache file\n'
  FAIL=$((FAIL + 1))
fi
output="$(kplock)"
check "kplock on empty cache prints (no cache)" "(no cache)" "$output"

echo
echo "## Results"
printf 'Passed: %d   Failed: %d\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
