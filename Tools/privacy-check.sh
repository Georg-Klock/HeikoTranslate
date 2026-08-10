#!/usr/bin/env bash
# Run the hold-back patterns against EVERY tracked file, not just the archive.
#
# Tools/curate-archive.py applies private/hold-back-patterns.txt to the review
# archive only. That left the rest of the repository unchecked, and it is where
# the leaks actually were: a family relationship in a design doc, a distance in
# a source comment, an account identifier in the build config — each one
# already named by a pattern that was never pointed at those files.
#
# Run before pushing anything to a public remote. Exits nonzero on a hit, so it
# can gate a push.
#
#   Tools/privacy-check.sh
set -uo pipefail
cd "$(dirname "$0")/.."

PATTERNS=private/hold-back-patterns.txt
ALLOW=private/privacy-allow.txt
if [ ! -f "$PATTERNS" ]; then
  echo "Missing $PATTERNS — it is gitignored by design, so a fresh clone will" >&2
  echo "not have it. Restore it from your own copy before checking; running" >&2
  echo "without it would report clean on an unchecked tree." >&2
  exit 2
fi

FAIL=0

# macOS ships bash 3.2, which has no `mapfile`; use a file list. Written to a
# temp file rather than a variable so filenames with spaces survive.
LIST=$(mktemp)
BINLIST=$(mktemp)
trap 'rm -f "$LIST" "$BINLIST"' EXIT
# NUL-delimited: filenames with spaces must survive, and `xargs -a` is a GNU
# extension that BSD xargs (macOS) rejects outright — with stderr discarded
# that failure reads as "no hits", i.e. a silent pass.
git ls-files -z | tr '\0' '\n' | grep -vE '\.(png|jpg|jpeg|wav|mp4|ico|icns)$' > "$LIST"
git ls-files -z | tr '\0' '\n' | grep -E '\.(png|jpg|jpeg|wav|mp4)$' > "$BINLIST"

# A check that scans nothing and exits 0 is worse than no check: it reads as a
# pass. Assert there is something to scan, the same way Tools/l1.sh asserts a
# non-zero test count.
NTEXT=$(wc -l < "$LIST" | tr -d ' ')
if [ "$NTEXT" -lt 20 ]; then
  echo "Only $NTEXT text files to scan — that is not a real tree." >&2
  echo "Run this from inside the repository, with the work committed or staged." >&2
  exit 2
fi

while IFS='=' read -r name pattern; do
  case "$name" in ''|\#*) continue ;; esac
  name="${name// /}"
  pattern="${pattern# }"
  hits=$(tr '\n' '\0' < "$LIST" | xargs -0 grep -InE "$pattern" 2>/dev/null)
  # Drop reviewed exceptions: places where the repo states a rule rather than
  # breaking it. Scoped to pattern name AND line content, so an exception
  # cannot blind the check to the rest of the same file.
  if [ -n "$hits" ] && [ -f "$ALLOW" ]; then
    allow=$(grep -E "^${name} *=" "$ALLOW" | sed "s/^${name} *= *//")
    if [ -n "$allow" ]; then
      while IFS= read -r rule; do
        [ -n "$rule" ] || continue
        hits=$(printf '%s\n' "$hits" | grep -vE "$rule" || true)
      done <<EOF
$allow
EOF
    fi
  fi
  if [ -n "$hits" ]; then
    echo "=== [$name] ==="
    echo "$hits"
    FAIL=1
  fi
done < "$PATTERNS"

# Anything tracked under private/ is a mistake by definition: `git mv` into a
# gitignored directory still stages the file, and ignore rules do not apply to
# already-tracked paths. This is how paperwork ends up published inside a
# folder named "private".
if git ls-files private/ | grep -q .; then
  echo "=== [tracked-under-private] ==="
  git ls-files private/
  echo "  Fix with: git rm --cached <path>"
  FAIL=1
fi

# Binary files carry metadata that text greps miss: EXIF, GPS, embedded paths.
while IFS= read -r f; do
  [ -n "$f" ] || continue
  meta=$(grep -aoE "/Users/[a-zA-Z0-9_-]+|GPSLatitude|GPSLongitude" "$f" 2>/dev/null | sort -u)
  if [ -n "$meta" ]; then
    echo "=== [binary-metadata] $f ==="
    echo "$meta"
    FAIL=1
  fi
done < "$BINLIST"

NBIN=$(wc -l < "$BINLIST" | tr -d ' ')
if [ "$FAIL" -eq 0 ]; then
  echo "==> privacy check clean ($NTEXT text files, $NBIN binaries)"
else
  echo
  echo "==> privacy check FAILED — see hits above. Do not push to a public remote." >&2
fi
exit "$FAIL"
