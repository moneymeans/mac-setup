# Money Means — Mac Setup

End-to-end bootstrap for a new Money Means engineer's MacBook.

By the end of running both scripts you have:
- Xcode Command Line Tools, Homebrew, all team dev tools (VS Code, iTerm2, Docker Desktop, Slack, …)
- All runtimes (Node LTS via mise, .NET 10 SDK, Python 3.13)
- Common dev infrastructure (tmux, ttyd, devtunnel, jq)
- A GitHub SSH key generated and uploaded
- The Money Means repos you nominated cloned into `~/work/` (or wherever you point `MAC_SETUP_WORK_DIR`)
- Optional: a per-project bootstrap (Makefile-driven) if you set `MAC_SETUP_PROJECT`
- Git identity configured
- GPG commit signing configured — commit authorship is cryptographically verifiable, not just self-declared

Every step is **idempotent** — running either script again is safe and skips anything already done.

## Two-step flow

Setup is split into two scripts so the human-attended parts (waiting for
Xcode CLT, pasting an SSH key into GitHub) don't sit in the middle of the
long unattended install.

```
pre-setup.sh     ── ~10 min, requires you watching it ──
  ├─ Xcode Command Line Tools (waits for Apple's GUI installer)
  ├─ Pre-seed GitHub host keys into known_hosts (closes MITM TOFU window)
  ├─ Generate ed25519 SSH key (no passphrase — see "SSH key" note below)
  ├─ Copy public key to clipboard + pause for upload to GitHub
  ├─ Verify GitHub accepts the key
  └─ Set git user.name + user.email

setup.sh         ── ~20-30 min, mostly unattended ─────
  ├─ Preflight (refuses to run if pre-setup didn't complete)
  ├─ Install Homebrew + run brew bundle (apps + CLIs)
  ├─ Pick browsers (chrome / firefox / arc / brave — multi-select)
  ├─ mise + Node.js LTS
  ├─ .NET 10 SDK + CSharpier
  ├─ Claude Code CLI (native installer)
  ├─ Oh My Zsh
  ├─ Launch Docker Desktop + wait for daemon
  ├─ Clone the repos you nominate (or via MAC_SETUP_REPOS env var)
  ├─ Optional project bootstrap (MAC_SETUP_PROJECT env var)
  └─ GPG commit signing (reuses an existing key, or generates RSA 4096; prints
     the public key + tells you to paste it at github.com/settings/gpg/new)
```

## Quick start — for new starters

On a brand-new Mac, open Terminal.app and paste this one line:

```bash
curl -fsSL https://raw.githubusercontent.com/moneymeans/mac-setup/main/bootstrap.sh | bash
```

It downloads this repo to `~/mac-setup` and tells you to run two commands:

```bash
cd ~/mac-setup
./pre-setup.sh   # ~10 min, interactive: SSH key, GitHub paste, git identity
./setup.sh       # ~20-30 min, mostly unattended (one password prompt at the start)
```

When `setup.sh` asks "Repos:", you should already know which ones to enter
— **your buddy/onboarder will give you the list**. The script deliberately
doesn't suggest names.

### Already have SSH set up?

If you can already `git clone git@github.com:...`, skip the bootstrap step:

```bash
git clone git@github.com:moneymeans/mac-setup.git
cd mac-setup
./pre-setup.sh   # detects existing SSH/git config; near-instant
./setup.sh
```

### Just need to add GPG commit signing?

For engineers whose Macs are already set up and who only need to turn on
signed commits — required for our security posture so that commit
authorship can be cryptographically verified rather than self-declared
(otherwise anyone can `git config user.email someone@moneymeans.co.uk`
and impersonate a colleague):

```bash
curl -fsSL https://raw.githubusercontent.com/moneymeans/mac-setup/main/setup-gpg-signing.sh | bash
```

No clone required, fully idempotent. Reuses any existing GPG key for
your git email; only generates a new one if none exists. At the end it
prints your public key and tells you to paste it at
https://github.com/settings/gpg/new. New starters get this
automatically as part of `./setup.sh` and don't need to run it
separately.

## Buddy guide: onboarding a new starter

Before they arrive, decide:
1. Which repos they need cloned. They'll get prompted; share the list.
2. Whether they need a project-specific bootstrap. If so, share the env
   vars:
   ```bash
   MAC_SETUP_REPOS="<repo-list>" \
   MAC_SETUP_PROJECT="<repo-with-Makefile>" \
   MAC_SETUP_PROJECT_CONFIG="<dotfile-name>" \
   MAC_SETUP_PROJECT_TMUX="<tmux-session>" \
   MAC_SETUP_PROJECT_NEEDS_DOCKER=1 \
   ./setup.sh
   ```
   `MAC_SETUP_PROJECT_*` are all optional — set only what applies. See
   `lib/project_bootstrap.sh` for what each does.

## Important caveats

- **`setup.sh` asks for your macOS password once at the start**, then
  keeps the `sudo` timestamp alive in the background. This reduces — but
  doesn't always eliminate — password prompts during `brew bundle`.
  Microsoft Teams' PKG installer in particular runs its own sudo and may
  prompt regardless. Expect 1–2 prompts on a truly fresh machine and
  stay at the keyboard for the brew bundle stage.
- **Don't run `setup.sh` twice in parallel.** It appends blocks to
  `~/.zshrc` / `~/.zprofile` without file locking; concurrent runs can
  produce duplicate or interleaved blocks.
- **The SSH key is generated without a passphrase.** This is a deliberate
  trade-off: an unencrypted key on a personal MacBook is acceptable risk
  for the convenience of unattended automation. If you want a passphrase,
  run `ssh-keygen` yourself before invoking `pre-setup.sh`. The script
  detects an existing key and reuses it.
- **Oh My Zsh and your default shell.** macOS already defaults to `zsh` so
  Oh My Zsh just adds the framework on top (it sources from `~/.zshrc`).
  New terminals pick it up after restart — no `chsh` needed.

## What you still need to do by hand

`setup.sh` prints these in its final "Next steps" block, but for the record:

| Step | Why we can't automate |
|---|---|
| Switch from Terminal.app to iTerm2 | iTerm2 is the team standard; new shells pick up Oh My Zsh + your PATH changes |
| Sign in to Slack, Notion, Teams, your browsers, VS Code | Identity-bound; we don't have your credentials |
| Open Docker Desktop the first time | macOS keychain prompt + first-run setup |
| Edit any per-project config file the bootstrap copied for you | Default values from the example, you fill in real ones |

## Re-running

Both scripts short-circuit on a fully-configured machine. Useful patterns:

```bash
./setup.sh                                       # full refresh — re-runs brew bundle, etc.
./setup.sh --no-clone                            # tooling refresh only (no repo prompt)
MAC_SETUP_WORK_DIR="$HOME/code" ./setup.sh       # clone repos somewhere other than ~/work
MAC_SETUP_REPOS="<repo>" ./setup.sh              # unattended re-clone
MAC_SETUP_REPOS="none" ./setup.sh                # explicit "no repos this time"
MAC_SETUP_BROWSERS="chrome firefox" ./setup.sh   # pre-pick browsers
MAC_SETUP_BROWSERS="none" ./setup.sh             # skip the browser step
./setup.sh --help                                # see all flags
```

If you re-run `pre-setup.sh` after the initial run, it detects the existing
SSH key, the existing git config, and that GitHub already accepts the key,
and exits in seconds.

`setup.sh` prints a yellow `Setup finished with WARNINGS` banner if any
step warned (e.g. brew bundle couldn't install a cask, `make install`
failed). The green `Setup complete!` banner only appears when every stage
ran cleanly — don't trust silent success.

## What gets installed

**CLI tools** (via Homebrew): `git`, `gh`, `mise`, `azure-cli`, `tmux`, `ttyd`, `jq`, `python@3.13`
**Apps** (via Homebrew Cask): iTerm2, VS Code, Docker Desktop, Notion, Slack, Teams, Itsycal, Rectangle, VLC, DevTunnel
**Browsers** (interactive multi-select via `lib/browsers.sh`): Chrome, Firefox, Arc, Brave
**Runtimes**: Node.js LTS (via mise), .NET 10 SDK (via dotnet-install.sh)
**Dev tooling**: CSharpier (`dotnet tool install -g`), Claude Code (native installer), Oh My Zsh

The full list lives in [`Brewfile`](./Brewfile) and the `lib/*.sh` modules.

### Version-manager choice

- **Node** → managed by [mise](https://mise.jdx.dev/). Reads `.mise.toml` per repo. (Volta is unmaintained as of 2026; its own maintainers point to mise.)
- **Python** → installed via Homebrew. Bootstrap projects can create venvs against this stable Python install — keeping it on brew prevents the venv from breaking if anyone fiddles with mise-managed Python versions.
- **.NET** → installed via Microsoft's `dotnet-install.sh` under `~/.dotnet` (no sudo, per-user, automation-friendly).

## Structure

```
bootstrap.sh           tiny downloader — curl|bash entry point for new starters
pre-setup.sh           self-contained; no lib/ — runs on a totally bare Mac
setup.sh               entry point — flags, preflight, orchestration, curl|bash staging
setup-gpg-signing.sh   standalone curl|bash entry point for existing engineers
                       who only need to add GPG commit signing
Brewfile               declarative cask + formula list
lib/
  common.sh              shared helpers: logging, have, append_block, ask,
                         section, multi_select, github_ssh_ok, SETUP_HAD_WARNINGS
  preflight.sh           refuses setup.sh if pre-setup outputs are missing
  sudo.sh                pre-warms sudo and keeps it alive for cask installs
  homebrew.sh            installs brew + runs `brew bundle`
  browsers.sh            interactive multi-select: chrome / firefox / arc / brave
  node.sh                mise + Node LTS + shell wiring
  dotnet.sh              .NET 10 SDK + CSharpier + shell wiring
  claude.sh              Claude Code native installer
  ohmyzsh.sh             Oh My Zsh
  itsycal.sh             configures Itsycal's menu-bar clock format
  macos_defaults.sh      keyboard, Finder, firewall, screen-lock defaults
  docker.sh              launches Docker Desktop and waits for the daemon
  repos.sh               interactive (or env-driven) clone of moneymeans/<repo>
  project_bootstrap.sh   generic per-project bootstrap driven by MAC_SETUP_PROJECT
  auth_clis.sh           guided gh / az / claude browser OAuth (skippable per-CLI)
  gpg_signing.sh         GPG commit signing — gnupg + pinentry-mac, key reuse-or-
                         generate, git config, gpg-agent.conf, GPG_TTY in shell rc
```

`setup.sh` works two ways:
- **Local clone** — sources `lib/*.sh` from disk.
- **Remote `curl | bash`** — stages `lib/` + `Brewfile` into a tempdir from `raw.githubusercontent.com` (cleaned up on exit).

## Editing

1. Clone, edit the relevant module or the Brewfile.
2. Test locally: `./setup.sh` — every module short-circuits on an already-configured machine.
3. `bash -n` every shell file before committing.
4. PR. Keep modules idempotent. **Never** hardcode an internal repo name.

### Adding a new tool

- **Brew package or cask?** Add to `Brewfile`. Done.
- **A runtime, npm-global, or curl-installer?** Add a small `lib/<thing>.sh`, source it from `setup.sh`, and add the path to `LIB_FILES` in `setup.sh` so `curl|bash` stages it.

### Adding per-project bootstrap

`lib/project_bootstrap.sh` already handles the generic shape (run `make install`, copy a config file, create a tmux session, gate on docker). If your project fits that shape, the buddy just sets `MAC_SETUP_PROJECT` + the optional helpers — no code change to mac-setup.

If your project needs something genuinely different (a non-Makefile installer, multi-stage setup, etc.), don't bake the project name into this repo. Instead: put the bootstrap script inside that project's own repo, document it in its README, and tell starters to run it after `setup.sh`.

### Helpers worth knowing

Defined in `lib/common.sh`:

| Helper | Use |
|---|---|
| `info / ok / warn / err` | Colored log lines. `warn` flips `SETUP_HAD_WARNINGS` so the final banner is honest. |
| `section "title"` | Prints a banner. |
| `have <cmd>` | True if `<cmd>` is on PATH. |
| `append_block <file> <name>` | Idempotently appends a `# >>> mac-setup: <name> >>>`-sentinel-wrapped block. Re-runs never duplicate. |
| `ask "prompt" VAR [default]` | Read into VAR, re-prompts on empty. |
| `multi_select "title" "key:default" "key2" ...` | Arrow-key checkbox menu. Result lands in `multi_select_result` array. |
| `github_ssh_ok` | True if `ssh git@github.com` succeeds (with 2 retries / 3s backoff). |
