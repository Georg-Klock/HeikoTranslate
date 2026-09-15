#!/bin/bash
# The one edit both git-mutating scripts make: swapping CFBundleVersion in
# project.yml. Shared so the two cannot drift ("two copies would be two
# chances to drift" — deploy.sh's own words about its commit helper), and
# written WITHOUT `sed -i`: BSD sed spells in-place as `-i ''` and GNU sed
# rejects exactly that spelling, which is what kept the L0 failure-window
# suite off Linux CI (GitHub #18). The `-i.bak` middle ground would drop a
# backup file INTO the worktree, where the scripts' own dirty-tree gates
# would trip over it if a signal landed between sed and rm. A temp file
# outside the repo plus mv has neither problem, on either OS — and it makes
# the swap one atomic-ish step: a signal mid-edit leaves project.yml in its
# previous, consistent state for the traps to reason about.
set_build_number() {  # set_build_number <from> <to>
  local tmp
  tmp=$(mktemp) || return 1
  sed "s/CFBundleVersion: \"$1\"/CFBundleVersion: \"$2\"/" project.yml > "$tmp" \
    && mv "$tmp" project.yml
}

# The next build number, derived from the WHOLE history rather than from this
# branch's project.yml. GitHub #148.
#
# `project.yml` is per-branch, and this project runs several branches at once.
# Two of them deploying from the same value both mint the same next number, and
# each run is individually correct: every guard in deploy.sh and release.sh asks
# "is the number this run is installing recorded?", to which the answer is yes,
# in every colliding case. None of them can ask "has this number already been
# spent elsewhere", because project.yml on this branch cannot know. Measured:
# four commits share Build 2.4.58, three share 2.4.57 — and on 2026-09-14 a
# deploy from main minted 2.4.78 while the phone already carried 78 and 79 from
# the device branch, which is the same collision reaching a screen.
#
# So the counter's SOURCE becomes the set of numbers already committed anywhere,
# while project.yml stays the value that gets built and shipped. It keeps the
# property that matters: the number only ever goes up.
#
# Both message shapes count. deploy.sh writes "Build <marketing>.<build>
# (device)" and release.sh writes "Release <marketing>.<build>", so a scan that
# knows only one of them lets device and TestFlight builds collide with each
# other — which #148 names as a point to settle, and which matters more than
# the within-kind case because a TestFlight number reaches Apple.
highest_committed_build() {
  git log --all --format=%s 2>/dev/null \
    | sed -nE 's/^(Build|Release) [0-9]+\.[0-9]+\.([0-9]+).*/\2/p' \
    | sort -n | tail -1
}

# The current value and the history, whichever is higher, plus one. A repo with
# no build commits yet (or no git at all) falls back to project.yml, which is
# the old behaviour exactly.
next_build_number() {  # next_build_number <current>
  local current="$1" highest
  highest=$(highest_committed_build)
  if [[ -n "$highest" ]] && (( highest > current )); then
    current="$highest"
  fi
  echo $(( current + 1 ))
}
