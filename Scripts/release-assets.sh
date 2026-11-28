#!/bin/bash
set -euo pipefail

fail() { echo "Release assets: $1" >&2; exit 1; }

zip="Agents-App-${RELEASE_TAG#v}-universal.zip"
checksum="$zip.sha256"
candidate="$RUNNER_TEMP/distribution"
repo="repos/$GITHUB_REPOSITORY"

check_candidate() (
  expected_source=$(git rev-parse "$SOURCE_COMMIT" "refs/tags/$RELEASE_TAG")
  cd "$candidate"
  [[ "$(cat source)" == "$expected_source" ]] || fail "Candidate tag or source commit differs."
  [[ $(shasum -a 256 "$zip") == "$(cat "$checksum")" ]] || fail "Candidate checksum does not match."
)

restore_candidate() {
  [[ ${CANDIDATE_RUN_ID:-} =~ ^[0-9]+$ ]] || fail "Specify the run ID holding the signed candidate."
  gh api "$repo/actions/runs/$CANDIDATE_RUN_ID" | jq -e --arg commit "$SOURCE_COMMIT" '
    .event == "workflow_dispatch" and .head_branch == "master" and .head_sha == $commit
    and .path == ".github/workflows/release-gate.yml"
  ' >/dev/null || fail "Candidate run does not match the approved master workflow and source."
  gh run download "$CANDIDATE_RUN_ID" --repo "$GITHUB_REPOSITORY" \
    --name "agents-app-$RELEASE_TAG-signed" --dir "$candidate"
  check_candidate
}

assert_asset_names() {
  jq -e --arg zip "$zip" --arg checksum "$checksum" '
    [.assets[].name] as $names
    | ($names | length) == ($names | unique | length)
    and all($names[]; . == $zip or . == $checksum)
  ' <<<"$1" >/dev/null || fail "Existing release has duplicate or unexpected assets."
}

verify_public() (
  check_candidate
  local_release=$(gh api "$repo/releases/tags/$RELEASE_TAG")
  [[ $(jq -r '.draft' <<<"$local_release") == false ]] || fail "Expected a published release."
  assert_asset_names "$local_release"
  mkdir "$RUNNER_TEMP/public-release"
  cd "$RUNNER_TEMP/public-release"
  for asset in "$zip" "$checksum"; do
    curl --fail --location --silent --show-error --retry 2 --max-time 120 \
      --output "$asset" "https://github.com/$GITHUB_REPOSITORY/releases/download/$RELEASE_TAG/$asset"
    cmp "$asset" "$candidate/$asset"
  done
  shasum -a 256 -c "$checksum"
)

list_matching_releases() {
  # The releases-by-tag endpoint excludes drafts.
  gh api --paginate --slurp "$repo/releases?per_page=100" \
    | jq -c --arg tag "$RELEASE_TAG" '[.[][] | select(.tag_name == $tag)]'
}

publish_candidate() {
  check_candidate
  matches=$(list_matching_releases)
  count=$(jq 'length' <<<"$matches")
  [[ $count -le 1 ]] || fail "Multiple releases exist for $RELEASE_TAG."
  if [[ $count == 0 ]]; then
    gh release create "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" --verify-tag --draft \
      --generate-notes --title "Agents App ${RELEASE_TAG#v}"
    matches=$(list_matching_releases)
    [[ $(jq 'length' <<<"$matches") == 1 ]] || fail "Cannot identify the new draft."
  fi
  existing=$(jq -c '.[0]' <<<"$matches")
  assert_asset_names "$existing"
  if [[ $(jq -r '.draft' <<<"$existing") == true ]]; then
    missing=()
    for asset in "$zip" "$checksum"; do
      id=$(jq -r --arg asset "$asset" '.assets[] | select(.name == $asset) | .id' <<<"$existing")
      if [[ -n $id ]]; then
        gh api "$repo/releases/assets/$id" -H 'Accept: application/octet-stream' \
          | cmp - "$candidate/$asset" || fail "Draft asset $asset differs from the signed candidate."
      else
        missing+=("$candidate/$asset")
      fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
      gh release upload "$RELEASE_TAG" "${missing[@]}" --repo "$GITHUB_REPOSITORY"
    fi
    Scripts/verify-release-source.sh
    gh release edit "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" --draft=false
  fi
  verify_public
}

case ${1:-} in
  restore) restore_candidate ;;
  publish) publish_candidate ;;
  verify-public) verify_public ;;
  *) fail "Choose restore, publish, or verify-public." ;;
esac
