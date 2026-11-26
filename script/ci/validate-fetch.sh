#!/usr/bin/env bash
# validate-fetch.sh <host> <dir>
#
# Downloads the <host> archive of a ci run into <dir>: the run in
# INPUT_RUN_ID, else the newest successful ci run on main. Used by
# validate.yml; needs GH_TOKEN with actions: read.
set -euo pipefail
. "$(dirname "$0")/../lib.sh"

host=${1:?usage: validate-fetch.sh <host> <dir>}
dir=${2:?}
run=${INPUT_RUN_ID:-}
if [ -z "$run" ]; then
  run=$(gh run list --workflow ci.yml --branch main --status success --limit 1 --json databaseId --jq '.[0].databaseId')
  [ -n "$run" ] || die "no successful ci run on main"
fi
[[ "$run" =~ ^[0-9]+$ ]] || die "run id must be a number, not '$run'"
echo "testing the $host archive of ci run $run ($(gh run view "$run" --json headSha --jq .headSha))"
mkdir -p "$dir"
gh run download "$run" -n "release-$host" -D "$dir"
ls -l "$dir"
