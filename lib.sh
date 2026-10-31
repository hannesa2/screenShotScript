#!/usr/bin/env bash

## This file is intended to be sourced by other scripts

function err() {
  echo >&2 "$@"
}

function curl_gh() {
  if [[ -n "$CLASSIC_TOKEN" ]]; then
    curl \
      --silent \
      --show-error \
      --fail-with-body \
      --header "Authorization: token $CLASSIC_TOKEN" \
      --header "X-GitHub-Api-Version: 2022-11-28" \
      "$@"
  else
    err "WARNING: No CLASSIC_TOKEN found. Skipping API call"
  fi
}
