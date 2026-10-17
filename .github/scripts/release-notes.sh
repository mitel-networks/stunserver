#!/usr/bin/env bash
# Prints the release notes for TAG as Markdown on stdout: every commit since the
# previous release tag, one line each with a linked short SHA and the subject.
# Used twice: the approval screen shows it, then the release carries it.
#
# The baseline is the highest *released* version below TAG by version order (not
# the most recently created tag), so neither a backfilled tag nor a failed or
# rejected one produces a wrong range. Needs full history and tags
# (fetch-depth: 0) and, to see releases, GH_TOKEN and GITHUB_REPOSITORY.
#
# Usage: release-notes.sh <tag> [domain]
#   domain  when given, the notes end with a line saying it is live. Pass it
#           only once the deploy has succeeded.
#        release-notes.sh --previous <tag>
#   prints just the previous release tag (empty if there is none).
# Env: GITHUB_REPOSITORY (owner/name), for the commit links.
set -euo pipefail

MODE=notes
if [ "${1:-}" = --previous ]; then
  MODE=previous
  shift
fi
TAG=${1:?tag}
DOMAIN=${2:-}
REPO=${GITHUB_REPOSITORY:-}

[[ $TAG =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "release-notes.sh: '$TAG' is not a release tag like v1.2.3" >&2; exit 1; }
[[ -z $DOMAIN || $DOMAIN =~ ^[a-z0-9.-]+$ ]] || { echo "release-notes.sh: unexpected domain" >&2; exit 1; }

# Tags that have a GitHub release. A release is only created once its deploy
# succeeded, so these are the versions that actually went live: a tag whose
# build failed or whose deploy was rejected must not become the baseline, or
# the next changelog would silently skip everything since the last real release.
export GH_TOKEN=${GH_TOKEN:-${GITHUB_TOKEN:-}}
released=""
if [ -n "$REPO" ] && [ -n "$GH_TOKEN" ] && command -v gh >/dev/null; then
  released=$(gh release list --repo "$REPO" --limit 200 --json tagName --jq '.[].tagName' 2>/dev/null || true)
fi

previous=""
previous_released=""
while read -r t; do
  [ "$t" = "$TAG" ] && break
  previous=$t
  if [ -n "$released" ] && grep -qxF "$t" <<<"$released"; then
    previous_released=$t
  fi
done < <({ git tag --list 'v*' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' || true; echo "$TAG"; } | sort -V -u)
# The latest released version below TAG. Before any release exists (or if the
# list could not be read) the latest tag below TAG stands in.
previous=${previous_released:-$previous}

if [ "$MODE" = previous ]; then
  echo "$previous"
  exit 0
fi

if [ -n "$previous" ]; then
  echo "## Changes since ${previous}"
  echo
  # Merge commits are skipped (a fork syncing upstream creates many); the
  # commits they bring in are listed on their own. The "@" is defused so a
  # subject mentioning someone does not notify them.
  log=$(git log --no-merges --pretty=format:'%H %h %s' "${previous}..${TAG}" || true)
  if [ -z "$log" ]; then
    echo "No commits since ${previous}."
  else
    while read -r full short subject; do
      subject=${subject//@/@&#8203;}
      if [ -n "$REPO" ]; then
        echo "- [\`${short}\`](https://github.com/${REPO}/commit/${full}) ${subject}"
      else
        echo "- \`${short}\` ${subject}"
      fi
    done <<<"$log"
  fi
else
  echo "## Changes"
  echo
  echo "Initial release (no earlier release tag to compare against)."
fi

if [ -n "$DOMAIN" ]; then
  echo
  echo "---"
  echo
  echo "Deployed to \`${DOMAIN}\`."
fi
