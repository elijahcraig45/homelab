#!/usr/bin/env python3
"""Export a cleaned public snapshot of this repo into a checkout of the public repo.

    python3 scripts/publish_public.py --rules PATH/TO/public.rules DEST
    python3 scripts/publish_public.py --rules PATH/TO/public.rules --check --source staged x

It exports the COMMITTED tree (git archive HEAD, so uncommitted and untracked files never leave),
applies the replacements from the rules file, then refuses to write anything to DEST if a deny
pattern still matches. DEST keeps its own .git; everything else in it is replaced. Review and
commit in DEST yourself.

The rules file holds the private values, so keep it OUTSIDE every repo. One rule per line:

    replace <literal> => <replacement>
    deny <regex>              (Python regex; any match blocks the export)
    exclude <path or dir/>    (left out of the export)

Lines starting with # are comments.
"""
from __future__ import annotations

import argparse
import io
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path

# Generic patterns that hold no private value, so they can live in the code.
BUILTIN_DENY = [
    r"/api/push/(?!<)[A-Za-z0-9]{6,}",                      # Uptime Kuma push tokens
    r"AIza(?!FakeKey)[0-9A-Za-z_\-]{35}",                    # Google API keys (the test fixture is allowed)
    r"ghp_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{40,}",     # GitHub tokens
    r"sk-[A-Za-z0-9_\-]{32,}",                               # API secret keys
    r"-----BEGIN [A-Z ]*PRIVATE KEY-----\s*[A-Za-z0-9+/=\s]{100,}",  # real key bodies
    r"tail[0-9a-f]{6}\.ts\.net",                             # a real tailnet name
    r"\b192\.168\.\d+\.\d+\b",                               # LAN addresses
    r"\b100\.(?:6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.\d+\.\d+\b",  # tailnet addresses
]


def parse_rules(path: Path) -> tuple[list[tuple[str, str]], list[str], list[str]]:
    replace, deny, exclude = [], [], []
    for n, raw in enumerate(path.read_text().splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        kind, _, rest = line.partition(" ")
        rest = rest.strip()
        if kind == "replace" and " => " in rest:
            old, new = rest.split(" => ", 1)
            replace.append((old, new))
        elif kind == "deny" and rest:
            deny.append(rest)
        elif kind == "exclude" and rest:
            exclude.append(rest)
        else:
            raise SystemExit(f"{path}:{n}: cannot parse rule: {raw!r}")
    replace.sort(key=lambda r: len(r[0]), reverse=True)  # longest first, so specific rules win
    return replace, deny, exclude


def export_head(repo: Path, out: Path) -> None:
    data = subprocess.run(["git", "-C", str(repo), "archive", "--format=tar", "HEAD"],
                          check=True, capture_output=True).stdout
    with tarfile.open(fileobj=io.BytesIO(data)) as tar:
        tar.extractall(out, filter="data")


def export_staged(repo: Path, out: Path) -> None:
    """The index (what the next commit would contain), for checking before committing."""
    subprocess.run(["git", "-C", str(repo), "checkout-index", "--all", f"--prefix={out}/"], check=True)


def is_excluded(rel: str, exclude: list[str]) -> bool:
    return any(rel == e or (e.endswith("/") and rel.startswith(e)) for e in exclude)


def clean(tree: Path, replace, exclude) -> int:
    changed = 0
    for path in sorted(p for p in tree.rglob("*") if p.is_file()):
        rel = path.relative_to(tree).as_posix()
        if is_excluded(rel, exclude):
            path.unlink()
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue  # binary files are checked as bytes below
        new = text
        for old, rep in replace:
            new = new.replace(old, rep)
        if new != text:
            path.write_text(new, encoding="utf-8")
            changed += 1
    return changed


def leaks(tree: Path, deny: list[str]) -> list[str]:
    patterns = [re.compile(p, re.IGNORECASE) for p in [*BUILTIN_DENY, *deny]]
    found = []
    for path in sorted(p for p in tree.rglob("*") if p.is_file()):
        text = path.read_bytes().decode("utf-8", errors="ignore")
        for lineno, line in enumerate(text.splitlines(), 1):
            for pat in patterns:
                if pat.search(line):
                    found.append(f"{path.relative_to(tree)}:{lineno}: matches deny rule #{patterns.index(pat) + 1}")
    return found


def sync(tree: Path, dest: Path) -> None:
    for child in dest.iterdir():
        if child.name == ".git":
            continue
        shutil.rmtree(child) if child.is_dir() else child.unlink()
    for child in tree.iterdir():
        target = dest / child.name
        shutil.copytree(child, target) if child.is_dir() else shutil.copy2(child, target)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("dest", type=Path, help="checkout of the public repo (must contain .git)")
    ap.add_argument("--rules", type=Path, required=True, help="rules file kept outside every repo")
    ap.add_argument("--check", action="store_true", help="export and check only; do not touch DEST")
    ap.add_argument("--source", choices=("head", "staged"), default="head",
                    help="export the last commit (default) or the staged files, to check before committing")
    ap.add_argument("--keep", type=Path, help="with --check: also copy the cleaned tree here, e.g. to run the tests on it")
    args = ap.parse_args(argv)

    repo = Path(__file__).resolve().parents[1]
    if args.rules.resolve().is_relative_to(repo):
        print("refusing: the rules file must live outside the repo", file=sys.stderr)
        return 2
    if not args.check and not (args.dest / ".git").is_dir():
        print(f"refusing: {args.dest} is not a git checkout", file=sys.stderr)
        return 2
    replace, deny, exclude = parse_rules(args.rules)
    with tempfile.TemporaryDirectory() as tmp:
        tree = Path(tmp)
        (export_staged if args.source == "staged" else export_head)(repo, tree)
        changed = clean(tree, replace, exclude)
        problems = leaks(tree, deny)
        files = sum(1 for p in tree.rglob("*") if p.is_file())
        if problems:
            print(f"BLOCKED: {len(problems)} line(s) still match a deny rule; nothing was written:", file=sys.stderr)
            print("\n".join(problems[:50]), file=sys.stderr)
            return 1
        print(f"clean: {files} files exported, {changed} changed by replacements, 0 deny matches")
        if args.check:
            if args.keep:
                shutil.copytree(tree, args.keep)
            return 0
        sync(tree, args.dest)
    print(f"synced into {args.dest}; review with: git -C {args.dest} status")
    return 0


if __name__ == "__main__":
    sys.exit(main())
