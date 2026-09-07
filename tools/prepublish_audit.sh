#!/bin/sh
set -eu

printf '%s\n' '== ClipBox pre-publication audit =='
python3 tools/privacy_check.py --worktree
python3 tools/privacy_check.py --staged
if git rev-parse --verify HEAD >/dev/null 2>&1; then
  python3 tools/privacy_check.py --history

  if git log --format='%an <%ae>%n%cn <%ce>' | grep -Ei '@[^ >]*\.local>' >/dev/null 2>&1; then
    printf '%s\n' 'Local-machine Git identity detected in commit history.' >&2
    exit 1
  fi
fi
printf '%s\n' '== Git status =='
git status --short
printf '%s\n' 'Pre-publication audit passed.'
