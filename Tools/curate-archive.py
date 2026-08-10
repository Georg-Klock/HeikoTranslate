#!/usr/bin/env python3
"""Build the publishable review archive from the raw one.

`Tools/archive-github.py` exports every thread verbatim into `private/`. Most
of it is ordinary engineering discussion and belongs in public — it is the
record of how this work was actually reviewed. Some of it is not: personal
detail about people who did not sign up to be in a public repository, and
session notes rather than engineering.

This splits the two. The raw export stays in `private/`; the publishable
subset is written to `docs/review-archive/`. A thread is held back whole
rather than edited: redacting someone's words leaves a document that claims to
be a transcript and is not one.

Re-run after `archive-github.py`. It rewrites `docs/review-archive/` in place.
"""
import pathlib
import re
import shutil

ROOT = pathlib.Path(__file__).resolve().parent.parent
RAW = ROOT / "private" / "github-archive"
PUB = ROOT / "docs" / "review-archive"

PATTERNS = ROOT / "private" / "hold-back-patterns.txt"


def load_patterns():
    """The rules live in a gitignored file, deliberately.

    A checked-in list of the exact strings you are keeping out of a public
    repository publishes them — the filter would leak precisely what it exists
    to catch. So this file is required and never committed; if it is missing,
    refuse to run rather than quietly publishing everything.
    """
    if not PATTERNS.exists():
        raise SystemExit(
            f"Missing {PATTERNS.relative_to(ROOT)}.\n"
            "It is gitignored by design, so a fresh clone will not have it. "
            "Restore it from your own copy before curating — running without it "
            "would publish every thread unfiltered.")
    rules = {}
    for line in PATTERNS.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        name, _, pattern = line.partition("=")
        rules[name.strip()] = pattern.strip()
    if not rules:
        raise SystemExit(f"{PATTERNS.name} has no rules — refusing to run.")
    return rules


def reasons(text, rules):
    return [name for name, pat in rules.items() if re.search(pat, text, re.I)]


def main():
    if not RAW.exists():
        raise SystemExit("No raw archive — run Tools/archive-github.py first.")
    if PUB.exists():
        for old in PUB.glob("*.md"):
            old.unlink()
    PUB.mkdir(parents=True, exist_ok=True)

    rules = load_patterns()
    rows, held = [], []
    for f in sorted(RAW.glob("*.md")):
        text = f.read_text(encoding="utf-8")
        why = reasons(text, rules)
        if why:
            held.append((f.name, why))
            continue
        shutil.copy(f, PUB / f.name)
        head = text.splitlines()[0]
        m = re.match(r"# (\w+) #(\d+) — (.*)", head)
        state = re.search(r"\*\*State:\*\* (\w+)", text)
        if m:
            rows.append((int(m.group(2)), m.group(1), m.group(3),
                         state.group(1) if state else "?", text.count("\n### "), f.name))
    rows.sort()

    idx = [
        "# Review archive", "",
        "Issue and pull-request discussion from this project, as Markdown.", "",
        "This history was migrated to a new remote, and GitHub has no migration",
        "path for pull-request conversations — they exist only in the database of",
        "the repository they were written in. Since they are the record of how the",
        "work was actually reviewed, they are kept here as files instead.", "",
        f"**{len(rows)} threads.** {len(held)} others are held back: they contain personal",
        "detail about people who did not sign up to be in a public repository, or",
        "session notes rather than engineering discussion.", "",
        "Numbers match the live issue tracker — the migration preserved them, so a",
        "`#21` in a commit message still resolves to the right issue.", "",
        "| # | kind | comments | state | title |", "|---|---|---|---|---|",
    ]
    for n, kind, title, state, ncom, fn in rows:
        idx.append(f"| [{n}]({fn}) | {kind} | {ncom} | {state} | {title.replace('|', chr(92) + '|')} |")
    (PUB / "README.md").write_text("\n".join(idx) + "\n", encoding="utf-8")

    print(f"==> published {len(rows)} threads to docs/review-archive/")
    print(f"==> held back {len(held)}:")
    for name, why in held:
        print(f"      {name:<18} {', '.join(why)}")


if __name__ == "__main__":
    main()
