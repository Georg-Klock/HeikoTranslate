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

# --- UUIDs -----------------------------------------------------------------
# No UUID belongs in a tracked file unless it is deliberately fake. This gate
# exists because the pattern file did NOT catch the real one: a device
# identifier lifted straight out of gitignored Tools/local.env sat in a test
# fixture, passed this check, and was pushed to the public remote. A force-push
# does not unpublish a commit, so the gate has to be structural rather than a
# list of values anyone remembered to add.
#
# Rule: every UUID-shaped string in a tracked file must be on SYNTHETIC_UUIDS
# below. Adding one is a deliberate, reviewable act — which is the point. Test
# fixtures should look obviously invented: prefer a run of repeated nibbles
# over anything a tool could have generated.
SYNTHETIC_UUIDS='
AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE
11111111-1111-1111-1111-111111111111
22222222-2222-2222-2222-222222222222
'
UUID_RE='[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}'
uuid_hits=$(tr '\n' '\0' < "$LIST" | xargs -0 grep -InoE "$UUID_RE" 2>/dev/null)
if [ -n "$uuid_hits" ]; then
  while IFS= read -r allowed; do
    [ -n "$allowed" ] || continue
    uuid_hits=$(printf '%s\n' "$uuid_hits" | grep -viE ":$allowed\$" || true)
  done <<EOF
$SYNTHETIC_UUIDS
EOF
fi
if [ -n "$uuid_hits" ]; then
  echo "=== [uuid] ==="
  echo "$uuid_hits"
  echo "  A UUID in a tracked file is a machine or account identifier until"
  echo "  proven otherwise. If it is genuinely invented, add it to"
  echo "  SYNTHETIC_UUIDS in Tools/privacy-check.sh with a reason."
  FAIL=1
fi

# Belt and braces: the machine-local values themselves must never appear in a
# tracked file, whatever shape they are. Read from the gitignored file so this
# check can name the value without ever containing it.
if [ -f Tools/local.env ]; then
  # shellcheck disable=SC1091
  . Tools/local.env 2>/dev/null || true
  for secret_name in DEVICE_UUID DEVELOPMENT_TEAM; do
    eval "secret_value=\${$secret_name:-}"
    [ -n "$secret_value" ] || continue
    leaked=$(tr '\n' '\0' < "$LIST" | xargs -0 grep -InFi -- "$secret_value" 2>/dev/null)
    if [ -n "$leaked" ]; then
      echo "=== [local-env-leak: $secret_name] ==="
      echo "$leaked"
      echo "  This value lives in gitignored Tools/local.env. It must not be"
      echo "  committed — pushing publishes it permanently."
      FAIL=1
    fi
  done
fi

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
