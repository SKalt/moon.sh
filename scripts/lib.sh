#!/usr/bin/env bash

export api_base="https://svs.gsfc.nasa.gov/api/dialamoon"
export gh_api="https://api.github.com"
export gravatar_api="https://api.gravatar.com/v3"
export gravatar_oauth="https://public-api.wordpress.com/oauth2"

gravatar_redirect_uri() {
  printf '%s' "${GRAVATAR_REDIRECT_URI:-http://localhost:5000/callback}"
}

gravatar_token_file() {
  printf '%s' "${GRAVATAR_TOKEN_FILE:-${XDG_CACHE_HOME:-$HOME/.cache}/zamoon/gravatar.token}"
}

get_moon_api() {
  local dir="$1"
  local date="${2:-$(date -u +%Y-%m-%d)}"
  local cache="$dir/api.${date}.json"
  if [ -f "$cache" ]; then
    cat "$cache"
  else
    curl -fsSL "$api_base/${date}T00:00" | tee "$cache"
  fi
}

get_image_url() { cat - | jq -r '.image.url'; }
get_moon_age() { cat - | jq -r '.age'; }

get_original_image() {
  local dir="$1"
  cat - | get_image_url | xargs curl -fsSL -o "$dir/moon.jpg"
}

dither_moon() {
  local dir="$1"
  magick "$dir/moon.jpg" \
    -colorspace Gray \
    -resize '128x128!' \
    -dither FloydSteinberg \
    -depth 1 \
    "$dir/moon.bmp"
  magick "$dir/moon.bmp" "$dir/moon.png"
}

get_emoji() {
  local age
  age="$(cat - | jq -r '.age')"
  awk -v age="$age" 'BEGIN {
    month = 29.53
    frac = age / month
    if (frac < 1/16 || frac >= 15/16)      print ":new_moon:"
    else if (frac < 3/16)                  print ":waxing_crescent_moon:"
    else if (frac < 5/16)                  print ":first_quarter_moon:"
    else if (frac < 7/16)                  print ":waxing_gibbous_moon:"
    else if (frac < 9/16)                  print ":full_moon:"
    else if (frac < 11/16)                 print ":waning_gibbous_moon:"
    else if (frac < 13/16)                 print ":last_quarter_moon:"
    else                                   print ":waning_crescent_moon:"
  }'
}

set_github_avatar() {
  # this doesn't yet exist; see https://github.com/orgs/community/discussions/65206
  # example working frontend request:
  # POST https://github.com/settings/avatars/60464616
  # op=save
  # &authenticity_token=l-a_base64-base64-v1w
  # &cropped_x=0
  # &cropped_y=0
  # &cropped_width=128
  # &cropped_height=128
  :
}

gravatar_email_hash() {
  local email="${1:-}"
  if [ -z  "$email" ]; then email="$(git config user.email)"; fi
  if [ -z "$email" ]; then return 1; fi
  printf "%s" "$email" | tr '[:upper:]' '[:lower:]' | shasum -a 256 - | cut -d' ' -f1
}

# build the authorization URL to visit (step 1 of the OAuth code flow)
# requests the `auth` and `gravatar-profile:manage` scopes by default
# https://docs.gravatar.com/rest/authentication/#receiving-an-access-token
gravatar_authorize_url() {
  local cid="${GRAVATAR_CLIENT_ID:?GRAVATAR_CLIENT_ID is required}"
  local ru scope
  ru="$(gravatar_redirect_uri)"
  scope="${GRAVATAR_SCOPE:-auth gravatar-profile:manage}"
  printf '%s/authorize?%s\n' "$gravatar_oauth" "$(
    jq -nr --arg cid "$cid" --arg ru "$ru" --arg scope "$scope" '
      ([["client_id", $cid], ["redirect_uri", $ru], ["response_type", "code"]]
        + ($scope | split(" ") | map(select(. != "")) | to_entries | map(["scope[\(.key)]", .value])))
      | map("\(.[0] | @uri)=\(.[1] | @uri)")
      | join("&")'
  )"
}

# exchange an authorization code for an access token (step 2 of the OAuth code flow)
gravatar_exchange_code() {
  local ru
  local client_secret="${GRAVATAR_CLIENT_SECRET:-${GRAVATAR_API_KEY:-${GRAVATAR_TOKEN:-}}}"
  ru="$(gravatar_redirect_uri)"
  curl -fsSL -X POST \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    --data-urlencode "client_id=${GRAVATAR_CLIENT_ID:?GRAVATAR_CLIENT_ID is required}" \
    --data-urlencode "client_secret=${client_secret:?GRAVATAR_CLIENT_SECRET or GRAVATAR_API_KEY is required}" \
    --data-urlencode "grant_type=authorization_code" \
    --data-urlencode "code=${GRAVATAR_CODE:?GRAVATAR_CODE is required (visit gravatar_authorize_url and complete the flow)}" \
    --data-urlencode "redirect_uri=$ru" \
    "$gravatar_oauth/token" \
    | jq -r '.access_token'
}

# resolve an access token: env var > cached file > fresh code exchange
# (code-grant tokens do not expire, so a cached token is reused indefinitely)
# returns empty if no token can be obtained without more input
gravatar_access_token() {
  local token="${GRAVATAR_ACCESS_TOKEN:-}"
  local cache
  cache="$(gravatar_token_file)"
  if [ -z "$token" ] && [ -s "$cache" ]; then
    token="$(cat "$cache")"
  fi
  if [ -z "$token" ] && [ -n "${GRAVATAR_CODE:-}" ]; then
    token="$(gravatar_exchange_code)"
    mkdir -p "${cache%/*}"
    printf '%s' "$token" >"$cache"
    chmod 600 "$cache"
  fi
  printf '%s' "$token"
}

set_gravatar_avatar() {
  local image="$1"
  local email_hash="${GRAVATAR_EMAIL_HASH:-}"
  local token
  token="$(gravatar_access_token)"
  if [ -z "$token" ]; then
    echo "skipping Gravatar upload: no access token available" >&2
    echo "  set GRAVATAR_ACCESS_TOKEN, or run scripts/oauth_server.py once to cache one" >&2
    return 0
  fi
  local url="$gravatar_api/me/avatars"
  if [ -n "$email_hash" ]; then
    url="$url?selected_email_hash=$email_hash&select_avatar=true"
  fi
  curl -fsSL -X POST \
    -H "Authorization: Bearer $token" \
    -H 'Content-Type: multipart/form-data' \
    -F "image=@$image;type=image/png" \
    "$url"
}

set_github_status() {
  local emoji="$1"; shift
  local message="${1:-}"
  local body
  body="$(
    jq -nc \
      --arg e "$emoji" \
      --arg m "$message" \
      '{query: ("
        mutation($emoji: String!, $message: String!) {
          changeUserStatus(input: {emoji: $emoji, message: $message}) {
            status { emoji message }
          }
        }
      "), variables: {emoji: $e, message: $m}}'
  )"
  curl -fsSL -X POST \
    -H "Authorization: Bearer ${GH_PAT:?GH_PAT is required}" \
    -H "Content-Type: application/json" \
    --data "$body" \
    "$gh_api/graphql"
}
