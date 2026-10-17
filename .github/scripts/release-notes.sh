#!/usr/bin/env bash
# Prints the release notes for TAG as Markdown on stdout: every commit since the
# previous release tag, one line each with a linked short SHA and the subject.
# Used twice: the approval screen shows it, then the release carries it.
#
# The previous tag is the highest release tag *below* TAG by version order, not
# the most recently created one, so a backfilled or out-of-order tag does not
# produce a nonsensical range. Needs full history and tags (fetch-depth: 0).
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

previous=""
while read -r t; do
  [ "$t" = "$TAG" ] && break
  previous=$t
done < <({ git tag --list 'v*' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' || true; echo "$TAG"; } | sort -V -u)

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
