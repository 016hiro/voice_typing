#!/bin/bash
# Stop hook: when this turn modified Swift files, mirror CI's compile + unit
# test step before letting Claude end the turn.
#
# Why: `make build` (release config, main module only) does NOT compile the
# test target. Swift 6 strict-concurrency regressions in test code therefore
# pass local build but break CI. Between v0.5.0 and v0.6.0 this gap let CI
# stay red for 5 versions before anyone noticed. The hook closes the gap so
# Claude cannot stop on a state that would be red on push.
#
# Behavior:
#   - No Swift changes in working tree → exit 0 (skip, fast)
#   - Swift changes + `make test` passes → exit 0
#   - Swift changes + `make test` fails  → exit 2 (Claude is forced to continue
#     working; stderr is fed back as a system message so Claude sees the failure)

set -uo pipefail

cd "${CLAUDE_PROJECT_DIR:-$(pwd)}"

if ! git status --porcelain 2>/dev/null | grep -qE '\.swift$'; then
    exit 0
fi

if ! make test >&2 2>&1; then
    cat >&2 <<'EOF'

BLOCKED: `make test` failed (mirrors CI's `swift test --skip E2E`).
This Swift code would break CI on main. Fix the failure above before stopping.
EOF
    exit 2
fi

exit 0
