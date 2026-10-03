# Execution log

<!-- nogg:SPEC-bipe:2026-10-02T21:24:50Z -->
- 2026-10-02T21:32:08+00:00 — SPEC-bipe closed for TASK-BSI-002 (Bead closed at 2026-10-02T21:24:50Z).
  - implementation commits: 8dae787
  - Bead note:
    commit 8dae787; added ensure_node() to scripts/bootstrap: checks existing node's major version against the compatibility baseline's 18/20/22 LTS line (satisfying -> skipped, reported); otherwise installs nvm (pinned NVM_VERSION=v0.40.1, via nvm's own official installer, only if nvm.sh not already present) then 'nvm install 22' (NODE_LTS_PIN), reporting installed/upgraded. Verified via fake-binary unit checks (not touching this host's real node/nvm): a satisfying existing node (v20) is skipped with no curl call; a non-satisfying node (v16) reaches the nvm-install curl step correctly. Full scripts/test passed (all script tests passed, exit 0).

<!-- nogg:SPEC-jaod:2026-10-02T21:28:34Z -->
- 2026-10-02T21:32:08+00:00 — SPEC-jaod closed for TASK-BSI-003 (Bead closed at 2026-10-02T21:28:34Z).
  - implementation commits: fe81c97
  - Bead note:
    commit fe81c97; added ensure_npm_global() (generic: checks installed binary's version against the pin, skips if equal, else npm install -g pkg@pin) and wired it for @anthropic-ai/claude-code@2.1.260, @openai/codex@0.148.0, @fission-ai/openspec@1.11.0; added --with-pi flag + ensure_node_floor_for_pi() (raises Node to >=22 via nvm first, since Pi needs >=22.19) + @earendil-works/pi-coding-agent@0.85.0, gated behind that flag only. Verified via fake-binary unit checks (no real npm/network touched): satisfying version skips with no npm call; non-satisfying version triggers the correct 'npm install -g pkg@pin' call; full --with-pi run exercises node-floor-skip + all four npm_global checks end-to-end, exit 0. Full scripts/test passed (all script tests passed, exit 0).

<!-- nogg:SPEC-tso4:2026-10-02T21:31:37Z -->
- 2026-10-02T21:32:08+00:00 — SPEC-tso4 closed for TASK-BSI-004 (Bead closed at 2026-10-02T21:31:37Z).
  - implementation commits: 600fb9e
  - Bead note:
    commit 600fb9e; added ensure_dolt() and ensure_bd() to scripts/bootstrap, each checking the installed binary's version against the pin (dolt 2.3.x, bd 1.2.x) and skipping if satisfied. Verified against this host's real bd 1.2.2 / dolt 2.3.1 (both correctly report skipped, no curl call) and, with faked non-satisfying versions, that the correct pinned-tag curl command is reached for each (no real network call made). Full scripts/test passed (all script tests passed, exit 0).
    
    DISCOVERY: this task also asks to 'verify both pinned-tag install script URLs resolve... recheck at implementation time.' This sandboxed worktree has no outbound network access at all (confirmed: even curl to example.com is denied by the session's permission layer), so I could not recheck either URL live. Implemented exactly the two URLs proposal.md recorded as confirmed-reachable during planning (dolt's exact-tag path; bd's main-branch raw path, passing the pin via a VERSION env var since bd has no per-tag install path). This still needs a live recheck on a real run/clean machine per TASK-BSI-009's own caveat about this sandbox lacking a throwaway VM -- not blocking this task, but worth confirming before the pinned bootstrap one-liner is advertised publicly.

<!-- nogg:SPEC-ex73:2026-10-02T21:21:43Z -->
- 2026-10-02T21:32:09+00:00 — SPEC-ex73 closed for TASK-BSI-001 (Bead closed at 2026-10-02T21:21:43Z).
  - implementation commits: 1228ac3
  - Bead note:
    commit 1228ac3; scripts/bootstrap created with the platform gate as its first and only action (checks /etc/os-release ID/ID_LIKE and uname -m against Debian/Ubuntu-family + x86_64/aarch64, exits 1 with the exact supported-platform statement on mismatch, installs nothing). Verified: bash -n and dash -n both accept it (POSIX-compatible); --help works; check_platform accepts this real host; and, via the NOGGING_BOOTSTRAP_OS_RELEASE/NOGGING_BOOTSTRAP_UNAME_M test-only override hooks, verified it correctly rejects a synthetic unsupported distro (fedora) and a synthetic unsupported arch (riscv64) without installing anything. Full scripts/test passed (all script tests passed, exit 0).
