#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
from pathlib import Path
import re
import subprocess
import sys

BLOCKED_SUFFIXES = {".cookies", ".db", ".p12", ".pem", ".pfx", ".sqlite", ".sqlite3", ".clipboxbackup"}
SECRET_PATTERNS = [
    re.compile(r"(?i)authorization\s*:\s*bearer\s+[A-Za-z0-9._~+/=-]{12,}"),
    re.compile(r"(?i)cookie\s*:\s*[^\s]{12,}"),
]

def run_git(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(["git", *args], check=False, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

def denylist_candidates() -> list[Path]:
    configured = os.environ.get("CLIPBOX_PRIVACY_DENYLIST")
    result = [Path(configured).expanduser()] if configured else []
    home = Path.home()
    if sys.platform == "darwin":
        result.append(home / "Library" / "Application Support" / "ClipBox" / "privacy" / "denylist.txt")
    elif os.name == "nt" and os.environ.get("APPDATA"):
        result.append(Path(os.environ["APPDATA"]) / "ClipBox" / "privacy" / "denylist.txt")
    else:
        result.append(Path(os.environ.get("XDG_CONFIG_HOME", home / ".config")) / "clipbox" / "privacy" / "denylist.txt")
    return result

def load_denylist() -> tuple[list[str], Path | None]:
    for path in denylist_candidates():
        if path.is_file():
            values = [line.strip() for line in path.read_text(encoding="utf-8").splitlines() if line.strip() and not line.lstrip().startswith("#")]
            return values, path
    return [], None

def blocked_path(path: str) -> bool:
    name = Path(path).name.lower()
    if name == ".env" or "cookies" in name:
        return True
    return any(name.endswith(suffix) for suffix in BLOCKED_SUFFIXES)

def staged_files() -> list[str]:
    cp = run_git("diff", "--cached", "--name-only", "--diff-filter=ACMR")
    if cp.returncode != 0:
        raise RuntimeError(cp.stderr.strip())
    return [x for x in cp.stdout.splitlines() if x]

def tracked_files() -> list[str]:
    cp = run_git("ls-files")
    if cp.returncode != 0:
        raise RuntimeError(cp.stderr.strip())
    return [x for x in cp.stdout.splitlines() if x]

def read_staged(path: str) -> str | None:
    cp = run_git("show", f":{path}")
    return cp.stdout if cp.returncode == 0 else None

def read_worktree(path: str) -> str | None:
    try:
        return Path(path).read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return None

def scan(paths: list[str], staged: bool, denylist: list[str]) -> list[str]:
    findings: list[str] = []
    for path in paths:
        if blocked_path(path):
            findings.append(f"blocked sensitive/runtime filename: {path}")
            continue
        data = read_staged(path) if staged else read_worktree(path)
        if data is None:
            continue
        folded = data.casefold()
        for value in denylist:
            if value.casefold() in folded:
                findings.append(f"private denylist value found in {path}")
        for pattern in SECRET_PATTERNS:
            if pattern.search(data):
                findings.append(f"possible credential/session material found in {path}")
    return findings

def scan_history(denylist: list[str]) -> list[str]:
    findings: list[str] = []
    cp = run_git("rev-list", "--all")
    if cp.returncode != 0:
        return findings
    commits = cp.stdout.splitlines()
    for value in denylist:
        for commit in commits:
            grep = run_git("grep", "-I", "-l", "-F", value, commit)
            if grep.returncode == 0 and grep.stdout.strip():
                findings.append(f"private denylist value exists in Git history at commit {commit[:12]}")
                break
    return findings

def main() -> int:
    parser = argparse.ArgumentParser()
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--staged", action="store_true")
    group.add_argument("--worktree", action="store_true")
    group.add_argument("--history", action="store_true")
    args = parser.parse_args()
    denylist, source = load_denylist()
    print(f"External privacy denylist: {source if source else 'not configured'}")
    findings = scan_history(denylist) if args.history else scan(staged_files() if args.staged else tracked_files(), args.staged, denylist)
    if findings:
        print("Privacy check FAILED:", file=sys.stderr)
        for finding in sorted(set(findings)):
            print(f"- {finding}", file=sys.stderr)
        return 1
    print("Privacy check passed.")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
