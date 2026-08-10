#!/usr/bin/env python3
"""Archive every issue and pull-request conversation to local Markdown.

Git history survives anything — it is on disk, on the remote, and in a bundle.
Review CONVERSATIONS do not: they live only in GitHub's database and cannot be
migrated to another repository. If this project ever has to move to a fresh
remote, the threads are the only thing that would actually be lost.

Run before any repo move, and periodically while one is on the cards.

    Tools/archive-github.py [owner/repo]

Output goes to private/ (gitignored): the threads quote other people, discuss a
third party, and are working material rather than the work product.
"""
import json
import pathlib
import subprocess
import sys

REPO = sys.argv[1] if len(sys.argv) > 1 else "Georg-Klock/HeikoTranslate"
OUT = pathlib.Path(__file__).resolve().parent.parent / "private" / "github-archive"


def gh(path, jq):
    """One paginated gh api call, decoded. Returns [] rather than raising, so a
    single inaccessible endpoint cannot abort the whole archive."""
    r = subprocess.run(["gh", "api", "--paginate", path, "--jq", jq],
                       capture_output=True, text=True)
    if r.returncode != 0 or not r.stdout.strip():
        return []
    # --paginate emits one JSON array per page; concatenate them.
    items = []
    for line in r.stdout.splitlines():
        line = line.strip()
        if line:
            items.extend(json.loads(line))
    return items


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    print(f"==> Archiving {REPO} to {OUT.relative_to(pathlib.Path.cwd())}/")

    # Issues and PRs share one numbering space and this endpoint returns both,
    # so a single pass covers everything and nothing is archived twice.
    threads = gh(f"repos/{REPO}/issues?state=all&per_page=100",
                 "[.[] | {number, title, state, user: .user.login, "
                 "created_at, body, url: .html_url, pr: (.pull_request != null)}]")
    if not threads:
        sys.exit("No threads returned — is `gh` authenticated for this repo?")

    total_comments = 0
    for d in sorted(threads, key=lambda t: t["number"]):
        n = d["number"]
        kind = "pull" if d["pr"] else "issue"

        comments = gh(f"repos/{REPO}/issues/{n}/comments",
                      "[.[] | {user: .user.login, created_at, body}]")
        # Review comments are a separate endpoint — inline code feedback, which
        # is most of what a reviewer actually said. Omitting it guts the archive.
        if d["pr"]:
            for c in gh(f"repos/{REPO}/pulls/{n}/comments",
                        "[.[] | {user: .user.login, created_at, body, path, line}]"):
                c["body"] = f"*on `{c.get('path')}`:{c.get('line')}*\n\n{c['body'] or ''}"
                comments.append(c)
        comments.sort(key=lambda c: c["created_at"])
        total_comments += len(comments)

        lines = [
            f"# {kind} #{n} — {d['title']}", "",
            f"- **State:** {d['state']}",
            f"- **Opened by:** {d['user']} on {d['created_at']}",
            f"- **URL:** {d['url']}", "", "---", "",
            (d["body"] or "*(no description)*").strip(), "",
        ]
        for c in comments:
            lines += ["---", "", f"### {c['user']} — {c['created_at']}", "",
                      (c["body"] or "").strip(), ""]

        (OUT / f"{n:03d}-{kind}.md").write_text("\n".join(lines), encoding="utf-8")
        print(f"  #{n:<4} {kind:<5} {len(comments):>3} comments  {d['title'][:56]}")

    print(f"==> {len(threads)} threads, {total_comments} comments archived")


if __name__ == "__main__":
    main()
