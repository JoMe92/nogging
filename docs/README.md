# Documentation

Use this index to browse Nogging's documentation on GitHub. The published
documentation site is available at <https://jome92.github.io/nogging/>.

## Getting started

| Guide | Covers |
| --- | --- |
| [Installation](installation.md) | Install Nogging into another repository and understand what it changes |
| [Compatibility](compatibility.md) | Supported operating systems, tools, versions, and agent integrations |
| [Your first change](https://jome92.github.io/nogging/first-change/) | Follow a first change from plan to review |
| [FAQ](faq.md) | Short answers to common questions about Nogging |

## Concepts

| Guide | Covers |
| --- | --- |
| [Vision and architecture](vision-and-architecture.md) | The problem Nogging solves and its architecture |
| [Operating model](operating-model.md) | Roles, lifecycle, and handoffs |
| [Worktree workflow](worktree-workflow.md) | How isolated Git worktrees keep agent changes independent |
| [Security and threat model](security-model.md) | Authority levels, protections, and security limits |
| [How Nogging compares](comparison.md) | Nogging compared with other specification and agent workflows |

## Guides

| Guide | Covers |
| --- | --- |
| [Using Nogging with Claude Code](https://jome92.github.io/nogging/using-with-claude-code/) | Run Nogging workflows from Claude Code |
| [Using Nogging with Codex](using-with-codex.md) | Run Nogging workflows from OpenAI Codex |
| [Using Nogging with Pi](using-with-pi.md) | Run Nogging workflows from Pi |
| [Using Nogging with Antigravity](using-with-antigravity.md) | Experimental Antigravity integration |
| [Running work in sessions](running-work-in-sessions.md) | Start, monitor, and steer supervised agent sessions |
| [Using Nogging with herdr](using-with-herdr.md) | Experimental herdr session backend |
| [Model selection](model-selection.md) | Choose a model and effort level for a session |
| [Agent identities](agent-identities.md) | Configure GitHub identities for agent personas |

## Operations

| Guide | Covers |
| --- | --- |
| [Troubleshooting](https://jome92.github.io/nogging/troubleshooting/) | Diagnose common installation and workflow problems |
| [Failure recovery](failure-recovery.md) | Recover from interrupted work and inspect project health |
| [Usage limits](usage-limits.md) | How Nogging detects agent usage limits and reset times |
| [Token usage](token-usage.md) | Understand token accounting across agent sessions |

## Reference

| Guide | Covers |
| --- | --- |
| [Commands](https://jome92.github.io/nogging/commands/) | Nogging command reference |
| [Configuration](https://jome92.github.io/nogging/configuration/) | Configuration keys and defaults |
| [Glossary](https://jome92.github.io/nogging/glossary/) | Terms used in Nogging documentation |
| [Architecture](architecture.md) | Detailed contracts, boundaries, and safety gates |

## Project & maintainers

| Guide | Covers |
| --- | --- |
| [Releasing Nogging](releasing.md) | Prepare and publish a release |
| [Acceptance runbook](acceptance.md) | Run the release acceptance procedure |
| [Project identity](project-identity.md) | Canonical project names, repositories, and identifiers |
| [Contributing](../CONTRIBUTING.md) | Contribution process |
| [Code of Conduct](../CODE_OF_CONDUCT.md) | Community expectations |
| [Security policy](../SECURITY.md) | Report a security issue |
| [Changelog](../CHANGELOG.md) | Release history |
| [Releases](https://github.com/JoMe92/nogging/releases) | Published releases |

## Internal

The `acceptance/` directory and `acceptance-report-template.md` contain
internal release records and templates. The public cutover checklist is
historical: the project went public with v3.0.0. These files remain in the
repository but are not part of the published documentation site.

## Assets

[`brand/`](brand/) holds the logo, banner, social card, and project diagrams.
