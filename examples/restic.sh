#!/usr/bin/env bash
# restic backup example
# https://restic.net/
#
# Source this in your shell init or a wrapper script.

export RESTIC_REPOSITORY="/path/to/repo"
export RESTIC_PASSWORD_COMMAND="kpget Backup/restic"

# Now restic commands will pull the repo password from KeePass:
#   restic snapshots
#   restic backup ~/Documents
