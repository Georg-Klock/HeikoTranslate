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
