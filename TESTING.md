# Testing on a fresh user account

A quick verification path before the new starters arrive. Run this on a
throwaway macOS user so your own dev account isn't affected.

## Setup

1. **System Settings → Users & Groups → Add Account**
   - Type: Standard (or Admin if you want full sudo testing)
   - Name: `Test Starter`, account: `teststarter`
2. **Log out** of your dev account; **log in** as `teststarter`
3. Open **Terminal.app** (not iTerm — iTerm isn't installed yet)

## Checklist

### bootstrap.sh

- [ ] Paste:
  ```bash
  curl -fsSL https://raw.githubusercontent.com/moneymeans/mac-setup/main/bootstrap.sh | bash
  ```
- [ ] Output ends with "Now run these two commands…"
- [ ] `~/mac-setup` contains `pre-setup.sh`, `setup.sh`, `Brewfile`, `lib/`, `README.md`

### pre-setup.sh

```bash
cd ~/mac-setup
./pre-setup.sh
```

- [ ] **Stage 1 Xcode CLT** — GUI dialog opens (this user is fresh, no CLT yet). Script polls until install completes. ~5-10 min.
- [ ] **Stage 2 SSH key** — Enter test email. Key generated at `~/.ssh/id_ed25519`. Known_hosts pre-seeded with GitHub keys.
- [ ] **Stage 3 GitHub upload** — Pubkey shown + copied to clipboard. **Either**: paste it to https://github.com/settings/ssh/new with a clear title (e.g. "Test Starter Mac — DELETE AFTER"), or Ctrl-C out and clean up later.
- [ ] **Stage 4 git identity** — Asks for name + email if not set.
- [ ] Green "Pre-setup complete!" banner.

### setup.sh

```bash
./setup.sh
```

- [ ] **Welcome banner** — green banner appears, lists 12 stages, asks "Press Enter to continue".
- [ ] **Preflight** — passes (assuming you completed pre-setup) OR refuses with clear message (if you skipped the GitHub paste).
- [ ] **Sudo prewarm** — one password prompt. Type the test user's password.
- [ ] **brew bundle** — runs through Homebrew install + ~17 casks/formulae. **Stay at the keyboard**: Docker Desktop and Microsoft Teams may still prompt for password despite the prewarm (macOS quirk).
- [ ] **Browsers** — multi-select arrow-key widget. ↑/↓ moves cursor, space toggles, enter confirms. Pick `chrome` for a quick test.
- [ ] **mise + Node** — installs LTS Node, writes activation block to `.zshrc`.
- [ ] **.NET 10 + CSharpier** — installs under `~/.dotnet`.
- [ ] **Claude Code** — native installer drops `~/.local/bin/claude`.
- [ ] **Oh My Zsh** — installs (won't be visible until you restart the shell).
- [ ] **Itsycal config** — clock format set, hide icon, weekday highlight, added to Login Items.
- [ ] **macOS defaults**: check System Settings after:
  - Keyboard → Key repeat rate maxed to "Fast", initial delay maxed to "Short"
  - Network → Firewall enabled with stealth mode
  - Screen lock → "Require password immediately after sleep"
  - Finder → file extensions visible, path bar visible
- [ ] **Docker Desktop** — auto-launches, script waits for daemon.
- [ ] **Repos prompt** — press Enter to skip (this exercises the no-input path). Stage says "No repos specified — skipping clone step".
- [ ] **Project bootstrap** — `MAC_SETUP_PROJECT` not set, so this stage no-ops silently.
- [ ] **CLI auth** — guided prompts for gh, az, claude. Type `n` to skip each.
- [ ] **Summary banner** — green "Setup complete!" if no warnings, yellow "Setup finished with WARNINGS" if anything warned.
- [ ] **Next steps** lists: switch to iTerm2, sign in to apps, complete Docker first-run, etc.

### Re-run check (idempotency)

```bash
./setup.sh --no-clone
```

- [ ] Should be a near-instant no-op. Every stage prints "already" messages. No long-running installs.

## Cleanup

1. Delete the test SSH key from GitHub: https://github.com/settings/keys
2. Log out of `teststarter`, log back into your dev account
3. System Settings → Users & Groups → delete `teststarter` (choose "Delete the home folder")
4. Optional: `rm ~/.claude-sessions-devtunnel-ok` if you also touched that during testing

## Known things that won't be perfect

- **Docker Desktop / Microsoft Teams prompts**: macOS-level, can't be fully suppressed even with sudo prewarm
- **The first Keychain prompt for devtunnel during project_bootstrap** (only if MAC_SETUP_PROJECT is set): see claude-herder PR #115
- **`make install` in project_bootstrap** assumes the project's Makefile is well-behaved — generic helper, project owns its own correctness

## What "passing" means

The test passes if:
- A fresh user with no prior setup can run the gist one-liner, follow on-screen instructions, and end up with a working dev environment in ~30-45 min
- Re-running `setup.sh` is a no-op (no unnecessary work, no Keychain prompts beyond Docker's one)
- The final banner is green (no warnings)
