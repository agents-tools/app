#!/bin/bash
set -euo pipefail

fail() { echo "Release source verification failed: $1" >&2; exit 1; }

[[ ${GITHUB_ACTIONS:-} == true &&
   ${GITHUB_REPOSITORY:-} == agents-tools/app &&
   ${GITHUB_EVENT_NAME:-} == workflow_dispatch &&
   ${GITHUB_REF:-} == refs/heads/main ]] || fail "Dispatch from agents-tools/app main."
[[ ${RELEASE_TAG:-} =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "Expected a version tag."
[[ ${SOURCE_COMMIT:-} =~ ^[a-f0-9]{40}$ &&
   $SOURCE_COMMIT == "${GITHUB_SHA:-}" &&
   $SOURCE_COMMIT == "$(git rev-parse HEAD)" ]] || fail "Approve the exact source commit on main."
git merge-base --is-ancestor HEAD refs/remotes/origin/main || fail "Source is outside origin/main."

# Resolve the tag from the remote again so a deleted or moved tag fails.
git fetch --quiet --no-tags origin "refs/tags/$RELEASE_TAG"
[[ $(git rev-parse 'FETCH_HEAD^{commit}') == "$SOURCE_COMMIT" ]] || fail "Tag points to another commit."
[[ $(git rev-parse FETCH_HEAD) == "$(git rev-parse "refs/tags/$RELEASE_TAG")" ]] ||
  fail "Tag object changed after checkout."
