#!/usr/bin/env bash
# Keeps one open issue per title: updates its body, or opens it. Needs GH_TOKEN and GH_REPO.
set -euo pipefail
title=$1
body_file=$2
number=$(gh api --paginate "repos/$GH_REPO/issues?state=open&per_page=100" \
  --jq ".[] | select(.pull_request == null and .title == $(jq -Rn --arg t "$title" '$t')) | .number" | head -n 1)
if [ -n "$number" ]; then
  gh api -X PATCH "repos/$GH_REPO/issues/$number" -F body=@"$body_file" > /dev/null
  echo "Updated issue #$number: $title"
else
  gh api "repos/$GH_REPO/issues" -f title="$title" -F body=@"$body_file" --jq '"Opened issue #\(.number): \(.title)"'
fi
