# Design

## Decision 1: the floor is a project-local extension, not a config flag

Pi has no `--sandbox`/execpolicy equivalent, so the SpecForge command floor
(`sudo`, `rm -rf`/`rm -fr`, `dd`, `mkfs*`, `shutdown`, `reboot`, `systemctl`,
`chown`, `curl`, `wget`, `git push --force*`, `git reset --hard`,
`git clean -fdx`, `git filter-branch`) and the `openspec/` write boundary are
enforced by a project-local extension, `.pi/extensions/specforge-guard.ts`,
listening on the `tool_call` event:

```ts
pi.on("tool_call", async (event, ctx) => {
  if (event.toolName === "<shell-tool>" && matchesFloor(event.input.command)) {
    return { block: true, reason: "SpecForge floor: <matched pattern>" };
  }
  if (isWriteTool(event.toolName) && underOpenspec(event.input) && !boundaryOpen()) {
    return { block: true, reason: "openspec/ is read-only outside a planning session" };
  }
});
```

The exact tool names for shell execution and file write/edit are Pi's own
built-in tool names, not yet confirmed against a real install from this
planning session (pi.dev's docs were fetched, not run) — TASK-PIA-001 must
verify these against an actually-installed `pi` CLI before the extension is
written, exactly as `codex-onboarding` verified the execpolicy grammar
hands-on before shipping `.codex/rules/specforge.rules` (that verification
caught `decision="deny"` being rejected — expect Pi to have its own
surprises).

Rejected alternative: require every Pi session to run inside a container.
Real isolation, but a new infra dependency (docker/podman) this repo does not
otherwise need, and it does not fit the existing `session launch` model
(direct process in tmux). Left as an operator option, not something SpecForge
manages.

## Decision 2: no false parity — Pi's `restricted` is floor-only

`agent-neutral-launch`'s existing requirement says `restricted` "SHALL deny
outbound network access" — true for Codex, not achievable for Pi without a
container. Rather than silently weakening that requirement's meaning, Pi gets
its own clause: `restricted` for Pi enforces the command floor and the
`openspec/` write boundary and nothing else; no network or filesystem
isolation exists. This is stated in `doctor`, in `AGENTS.md` *Tool notes*, and
in `docs/using-with-pi.md`, not left as an inferred gap.

## Decision 3: per-run trust, never a standing `defaultProjectTrust: always`

A non-interactive Pi launch must pass `--approve` for that run so the guard
extension actually loads (project-local extensions load only after trust).
`session launch --agent pi` SHALL pass `--approve` itself and SHALL NOT set
`defaultProjectTrust: always` in any shipped config — that would trust every
future project silently, machine-wide, forever, which is a materially larger
grant than "this one supervised session may run".

## Decision 4: prompts need no symlink helper

Pi reads `.pi/prompts/*.md` directly from the repository (confirmed from
`pi.dev` docs: paths in `.pi/settings.json` resolve relative to `.pi`, and
project-local prompts are one of the two supported locations). Unlike Codex
(`codex-followups` / SPEC-51d), no `pi-prompts-link`-style helper or `doctor`
NOTE about unlinked prompts is needed.

## Decision 5: specialists stay out-of-process

Pi has no in-process subagent mechanism (extensions inject context; they are
not a Task-tool equivalent). A Pi specialist run is therefore
`session launch --agent pi --role specialist:<type> --bead <id>`, exactly the
existing Codex pattern in `AGENTS.md` *Tool notes*.
