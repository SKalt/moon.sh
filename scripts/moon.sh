#!/usr/bin/env bash
### USAGE: moon.sh [-i] [-e] [-h] [YYYY-MM-DD] [output.png]
### Fetch the moon at 00:00 UTC and render it as a 128x128 black/white dithered
### image, and/or print its phase emoji. If a Gravatar access token is
### available (GRAVATAR_ACCESS_TOKEN, the token file cached by
### scripts/oauth_server.py, or GRAVATAR_CODE to complete the OAuth flow),
### upload the resulting avatar image to Gravatar; if GH_PAT is set, update
### the GitHub status emoji.
### OPTIONS:
###   -i  fetch and process the image
###   -e  print the moon phase emoji
### when neither -i nor -e is given, both are done
### defaults: today at 00:00 UTC, ./moon.png
### requires for uploads: Gravatar OAuth credentials (GRAVATAR_CLIENT_ID and
###   GRAVATAR_CLIENT_SECRET) with an access token (run scripts/oauth_server.py
###   once to obtain and cache one), plus optional GRAVATAR_EMAIL_HASH to
###   select the avatar for an email, and GH_PAT (token with the `user` scope)
usage() { grep '^###' "$0"  | sed 's/^### //g; s/^###//g'| sed "s#$0##g"; }

this_dir="${BASH_SOURCE[0]%/*}"
# shellcheck source=scripts/lib.sh
. "$this_dir/lib.sh"

set -euo pipefail

fetch_image=0
fetch_emoji=0
while getopts "ieh" opt; do
  case "$opt" in
    h) usage && exit 0;;
    i) fetch_image=1 ;;
    e) fetch_emoji=1 ;;
    *) echo "usage: $(basename "$0") [-i] [-e] [YYYY-MM-DD] [output.png]" >&2; exit 2 ;;
  esac
done
shift "$((OPTIND - 1))"

if [ "$fetch_image" -eq 0 ] && [ "$fetch_emoji" -eq 0 ]; then
  fetch_image=1
  fetch_emoji=1
fi

date="${1:-$(date -u +%Y-%m-%d)}"
out="${2:-moon.png}"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

if [ "$fetch_image" -eq 1 ]; then
  get_moon_api "$tmpdir" "$date" | get_original_image "$tmpdir"
  dither_moon "$tmpdir"
  mv "$tmpdir/moon.png" "$out"
  echo "$out"
  if [ -n "${GRAVATAR_TOKEN:-${GRAVATAR_ACCESS_TOKEN:-}}" ] || [ -f "$(gravatar_token_file)" ]; then
    set_gravatar_avatar "$out"
  fi
fi

if [ "$fetch_emoji" -eq 1 ]; then
  api_json="$(get_moon_api "$tmpdir" "$date")"
  emoji="$(printf '%s' "$api_json" | get_emoji)"
  age="$(printf '%s' "$api_json" | get_moon_age)"
  echo "$emoji"
  if [ -n "${GH_PAT:-}" ]; then
    set_github_status "$emoji" "Moon age ${age} days"
  fi
fi
