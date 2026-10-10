## Why

Profiles cannot consistently select Claude/Codex models, preventing controlled model choice and making session resource estimates opaque. Selection needs a single precedence and honest recorded defaults.

## What Changes

- Add optional profile model and Codex reasoning effort plus a --model launch override.
- Record and display selected model/source without changing defaults when omitted.
- Test profile-to-wrapper-to-agent argument contracts for every supported runtime.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `launch-profiles`: Optional per-profile/per-launch model selection.

## Impact

Sources: [#51](https://github.com/JoMe92/nogging/issues/51). Estimated execution effort: 1–2 person-days.

Affects the Nogging CLI, managed agent/installer payload, tests and operational documentation as specified in design.md. No execution work, release publication, visibility change or human acceptance sign-off is authorized by this planning artifact.
