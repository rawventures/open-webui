#!/usr/bin/env bash
#
# Keep GitHub Actions on the fork in a known state: our workflow enabled,
# every upstream workflow disabled.
#
# We no longer delete upstream workflow files (deleting them made every rebase
# onto a new release conflict in .github/). Instead the files stay in the tree
# and we disable them through the API.
#
# This is not cosmetic. Upstream's .github/workflows/docker.yaml triggers on
# `push: tags: [v*]`, which matches our own release tags (v0.10.2-custom). If it
# is left enabled, pushing a release tag kicks off upstream's full build matrix
# (cuda/ollama variants, helm notification, Docker Hub copy) against our ghcr
# repo. Run this script BEFORE pushing a tag.
#
# Usage:
#   scripts/fork/sync-workflow-state.sh            # report only
#   scripts/fork/sync-workflow-state.sh --apply    # actually disable
#
set -euo pipefail

REPO="${FORK_REPO:-rawventures/open-webui}"
KEEP_ENABLED="rawventures-docker.yaml"

APPLY=0
[[ "${1:-}" == "--apply" ]] && APPLY=1

command -v gh >/dev/null || { echo "gh CLI not found: https://cli.github.com"; exit 1; }
command -v jq >/dev/null || { echo "jq not found"; exit 1; }

echo "repo:          $REPO"
echo "keep enabled:  $KEEP_ENABLED"
echo

# GitHub only registers a workflow once its file has been pushed to the default
# branch, so run this AFTER pushing main-custom and BEFORE pushing the tag.
workflows="$(gh api "repos/$REPO/actions/workflows" --paginate \
  --jq '.workflows[] | [.id, .state, .path] | @tsv')"

if [[ -z "$workflows" ]]; then
  echo "No workflows registered. Push main-custom first, then re-run."
  exit 1
fi

rc=0
while IFS=$'\t' read -r id state path; do
  name="${path##*/}"

  if [[ "$name" == "$KEEP_ENABLED" ]]; then
    if [[ "$state" == "active" ]]; then
      echo "ok       $path (ours, active)"
    else
      echo "PROBLEM  $path is '$state' — this is our build workflow, it must be active"
      if (( APPLY )); then
        gh workflow enable "$id" -R "$REPO" && echo "         -> enabled"
      else
        rc=1
      fi
    fi
    continue
  fi

  if [[ "$state" == "active" ]]; then
    echo "DISABLE  $path (upstream, currently active)"
    if (( APPLY )); then
      gh workflow disable "$id" -R "$REPO" && echo "         -> disabled"
    else
      rc=1
    fi
  else
    echo "ok       $path (upstream, $state)"
  fi
done <<< "$workflows"

echo
if (( APPLY )); then
  echo "Done. Safe to push the release tag."
elif (( rc )); then
  echo "Workflow state is WRONG. Re-run with --apply, then push the tag."
else
  echo "Workflow state is correct. Safe to push the release tag."
fi
exit $rc
