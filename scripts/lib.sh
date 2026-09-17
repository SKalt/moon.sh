#!/usr/bin/env bash

export api_base="https://svs.gsfc.nasa.gov/api/dialamoon"
export gh_api="https://api.github.com"

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
