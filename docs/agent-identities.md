# Agent identities

This guide is for the Product Owner configuring a separate GitHub App for each
Nogging persona. Tier 1 uses the persona's Git author name and email from
`.nogging/config.json`; Tier 2 adds an optional App identity and installation
credentials. You can adopt Tier 2 for individual personas and leave the others
on Tier 1 by omitting their `github_app` blocks.

This guide covers registration and host preparation. Tier-2 credential minting
and worktree wiring are separate implementation tasks; this documentation alone
does not enable App authentication. Confirm that your installed version supports
`scripts/nogg credential-helper <slug>` before activating a configuration.

## Register one App per persona

1. Choose an exact persona key from `.nogging/config.json`'s `personas` roster,
   such as `lead`, `planner`, or `backend-engineer`. Keep that key as the local
   slug. Choose a unique GitHub App name, for example `your-org-nogging-lead`;
   the GitHub App slug may differ from the local persona key.
2. In the owning GitHub account or organization's **Settings → Developer
   settings → GitHub Apps**, select **New GitHub App**. Use the persona's chosen
   App name and your project homepage URL. Register under the repository-owning
   account where possible.
3. Disable active webhooks for this credential-only use. User authorization,
   device flow, and an OAuth callback are unnecessary for installation tokens.
4. Under repository permissions, grant **Contents: Read and write** and
   **Pull requests: Read and write**. Leave other optional permissions unset;
   GitHub includes read-only Metadata access. These are the minimum permissions
   for this Nogging setup; do not add administration or organization permissions.
5. Choose **Only on this account** for an App confined to its owning account.
   Use **Any account** only when installation elsewhere is needed. Create the
   App and record its numeric **App ID** from its settings, separately from its
   Client ID and installation ID.

GitHub's [registration procedure](https://docs.github.com/en/apps/creating-github-apps/registering-a-github-app/registering-a-github-app)
explains account ownership, registration fields, and permission selection.

## Generate and store the private key

Open the App's settings and generate a private key under **Credentials → Key
pairs → New key** (older interfaces label this **Private keys → Generate a
private key**). GitHub downloads a PEM file. Follow its
[private-key guidance](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/managing-private-keys-for-github-apps)
for generation, verification, and rotation.

Place the downloaded file on the delivery host, owned by the OS user running
Nogging sessions. For the `lead` persona, use:

```bash
install -d -m 700 "$HOME/.config/nogging/bot-identities"
install -m 600 /path/to/downloaded-app-key.pem "$HOME/.config/nogging/bot-identities/lead.pem"
```

Substitute the downloaded file path and exact persona slug. Transfer the file
securely if registration happened on a different machine. The required location
is `~/.config/nogging/bot-identities/<slug>.pem`, outside every repository and
worktree. Never commit the key, print its contents, paste it into a Bead or
session log, or pass its contents on a command line. Remove unnecessary download
copies after confirming secure storage. To rotate, generate and deploy a new
key, verify authentication, then revoke the old key in GitHub.

## Install on the target repository

In the App's settings, select **Install App**, choose the repository-owning
account, then **Only select repositories** and the target repository. Review
permissions and install. An organization may require an owner to approve this.
Repeat for each persona App; registration alone does not grant repository
access. See GitHub's [installation procedure](https://docs.github.com/en/apps/using-github-apps/installing-your-own-github-app).

Record the installation ID from the installed App's configuration URL if your
credential-helper version requires it. It identifies this account installation,
not the App itself.

## Configure the persona

The App ID and private-key path belong in the chosen persona's optional
`github_app` block inside `.nogging/config.json`. Retain the persona's existing
`name` and `email`, and preserve every other roster entry. The following is an
illustrative fragment for `personas.lead`, with a fictitious App ID:

```json
{
  "name": "Nogging Lead",
  "email": "lead@nogging.bot",
  "github_app": {
    "app_id": 123456,
    "private_key_path": "/home/DELIVERY_USER/.config/nogging/bot-identities/lead.pem"
  }
}
```

The credential helper accepts `app_id` and `private_key_path`. If the path is
omitted, it uses `~/.config/nogging/bot-identities/<slug>.pem`; a leading `~`
is expanded. It discovers the installation through the checkout's GitHub
`origin` repository, so no installation ID is required. Only public identifiers
and paths belong in the config, never the PEM contents or an access token.

`scripts/nogg credential-helper <slug> get` reads Git's credential request
from standard input. It supports HTTPS credentials for `github.com` and
requires an HTTPS or `git@github.com:` origin. OpenSSL must be available for
RS256 signing. Tokens are requested for the origin repository only and remain
in memory; `store` and `erase` consume input without persisting anything.
Failures return non-zero with no credential output. When wiring the helper
manually, clear inherited credential helpers first so Git cannot continue to
an ambient personal credential after a failure.

Once Tier 2 is implemented, allocate a fresh persona worktree through Nogging so
its identity and credential helper are scoped to that worktree. App installation
tokens authenticate HTTPS remotes, not SSH. Avoid changing a shared remote in a
way that disrupts other worktrees. Git author attribution and push authentication
are separate: setting `user.email` alone does not authenticate as the App.

The intended helper mints short-lived installation tokens without storing them;
missing keys or failed exchanges must fail closed without personal-credential
fallback. Do not run the helper directly into a terminal or log because its
successful credential-protocol output contains a token. Verify through an
authorized Git operation once the helper and worktree integration are available.
