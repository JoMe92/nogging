## ADDED Requirements

### Requirement: The orchestrator hands over a dashboard link only on request

The orchestrator prompt (`.nogging/launch-prompts/orchestrator.md`) and `/orchestrate` SHALL state
that the Orchestration Agent runs `./scripts/nogg dashboard pair` only when the Product Owner asks for
the dashboard link in the conversation, sends the link once to the Product Owner and to nobody else,
and never writes it into a Bead, a commit, a file or another session. They SHALL state that it never
reads the dashboard secret, never builds or sends a `#token=` link, never runs `nogg dashboard service
enable` or `service run`, never starts, enables or restarts the dashboard unit through `systemctl`,
never writes the dashboard consent or unit, and never starts a network bind, and that when no
service runs it gives the Product Owner the one terminal command. They SHALL state that it runs `nogg dashboard service disable` when the Product Owner asks for the
dashboard to be switched off, and `nogg dashboard --rotate-token` when the Product Owner reports a
link that was already used from another address.

#### Scenario: The Product Owner asks for the dashboard

- **WHEN** the Product Owner asks the Orchestration Agent for the dashboard on the phone
- **THEN** the prompt directs it to run `./scripts/nogg dashboard pair` and send the printed link

#### Scenario: No service is enabled

- **WHEN** `pair` reports that no dashboard service runs
- **THEN** the prompt directs the Orchestration Agent to give the Product Owner the
  `nogg dashboard service enable --bind <address>` command for a terminal, and not to start a bind
  itself

#### Scenario: No link without a request

- **WHEN** nobody has asked for the dashboard link
- **THEN** the prompt forbids minting one

#### Scenario: The token stays on the host

- **WHEN** the Orchestration Agent could reach the dashboard secret file
- **THEN** the prompt forbids reading it and forbids sending a `#token=` link
