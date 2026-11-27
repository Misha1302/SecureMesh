#!/usr/bin/env bash
# Reuse only a same-repository, same-branch APK whose complete client inputs
# and Android build/launch/test steps match. Otherwise build a fresh APK.
set -euo pipefail
api="repos/$GITHUB_REPOSITORY/actions"
name=securemesh-android-ephemeral-test-key
branch=${GITHUB_HEAD_REF:-$GITHUB_REF_NAME}
build_steps() {
  # Compare the exact runner image and build/test steps, ignoring only job
  # dependency/condition expressions governing whether the build is needed.
  awk '/^  package-and-launch:/ {job=1; next}
       job && /^  [a-zA-Z][^ ]*:/ {exit}
       job && /^    runs-on:/ {print}
       job && /^    steps:/ {steps=1}
       steps && NF {print}'
}
runs=$(gh api "$api/artifacts?name=$name&per_page=10") || exit 0
while IFS=$'\t' read -r run previous; do
  [[ -n "$run" && "$previous" =~ ^[0-9a-f]{40}$ ]] || continue
  git cat-file -e "$previous^{commit}" 2>/dev/null || continue
  # Both builds must use exactly the PR head's product inputs, without a
  # separate merge-resolution patch from the base branch.
  git merge-base --is-ancestor "$PR_BASE_SHA" "$previous" || continue
  git diff --quiet "$previous" HEAD -- apps/client_flutter src/crypto_core \
    scripts/build-android-release.sh .github/gradle rust-toolchain.toml || continue
  workflow=.github/workflows/android-candidate.yml
  old_steps=$(git show "$previous:$workflow" | build_steps)
  current_steps=$(build_steps < "$workflow")
  [[ "$old_steps" == "$current_steps" ]] || continue
  # Require this exact workflow and successful installed-device verification.
  [[ "$(gh api "$api/runs/$run" --jq '.path')" == "$workflow" ]] || continue
  gh api "$api/runs/$run/jobs" --jq '.jobs[] | select(.name=="package-and-launch" and .conclusion=="success") | .id' | grep -Eq '^[0-9]+$' || continue
  echo "Reusing verified APK from workflow $run at $previous."
  echo "run=$run" >> "$GITHUB_OUTPUT"
  echo "source=$previous" >> "$GITHUB_OUTPUT"
  break
done < <(jq -r --arg branch "$branch" --argjson repo "$GITHUB_REPOSITORY_ID" \
  '.artifacts[] | select(.expired == false and .workflow_run.head_branch == $branch and .workflow_run.head_repository_id == $repo) |
    [.workflow_run.id, .workflow_run.head_sha] | @tsv' <<<"$runs")
