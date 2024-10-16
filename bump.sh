#!/usr/bin/env bash

function bump_version() {
  local bump_type=$1
  # Get current version from file
  current_version=$(jq -r '.version' ./package.json)

  # Split the version into an array
  IFS='.' read -ra version_parts <<<"$current_version"

  # Increment version based on the provided argument
  if [[ $bump_type == "major" ]]; then
    ((version_parts[0]++))
    version_parts[1]=0
    version_parts[2]=0
  elif [[ $bump_type == "minor" ]]; then
    ((version_parts[1]++))
    version_parts[2]=0
  elif [[ $bump_type == "patch" ]]; then
    ((version_parts[2]++))
  else
    echo "Invalid argument. Please use 'major', 'minor', or 'patch'."
    return 1
  fi

  # Join the version parts back together
  new_version="${version_parts[0]}.${version_parts[1]}.${version_parts[2]}"

  jq --arg nv "$new_version" '.+{version: $nv}' ./package.json >tmpfile && mv tmpfile ./package.json

  git add package.json &>/dev/null
  git commit -m "${bump_type^^} Bump version to ${new_version}" &>/dev/null
  # git push origin main &>/dev/null

  echo -n "$new_version"
}

# Usage:
#   bump_version major
#   bump_version minor
#   bump_version patch
bump_version "$@"
