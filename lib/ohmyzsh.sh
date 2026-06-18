# shellcheck shell=bash
# Sourced from setup.sh after common.sh. Uses: info/ok/warn,
# append_block, ZSHRC.
#
# Oh My Zsh is opinionated — the prompt, the plugin loader, the update
# nag. Some people love it, some prefer their own zsh setup. So:
#   - If ~/.zshrc already sources oh-my-zsh.sh (either our sentinel
#     block OR a hand-rolled load line), do nothing. A second block
#     would duplicate the load OR fight the user's customisation.
#   - Otherwise prompt (default = yes; if you're new enough to ask, you
#     probably want it). MAC_SETUP_OMZ=yes|no skips the prompt.
#   - On install: run the upstream installer with KEEP_ZSHRC=yes so it
#     doesn't overwrite anything, then add our marker-wrapped block to
#     ~/.zshrc so the framework actually loads. KEEP_ZSHRC=yes on a
#     fresh Mac with no existing .zshrc means the installer skips
#     writing one — without our block omz would be on disk but unused.

omz_loaded_in_rc() {
  [[ -f "$ZSHRC" ]] || return 1
  grep -qE 'oh-my-zsh\.sh|ZSH=.*oh-my-zsh' "$ZSHRC"
}

if omz_loaded_in_rc; then
  ok "Oh My Zsh already loaded in $ZSHRC — leaving it alone"
  return 0 2>/dev/null || exit 0
fi

want="${MAC_SETUP_OMZ:-}"
if [[ -z "$want" ]]; then
  if [[ -t 0 ]]; then
    # `|| true` keeps `set -e` from killing setup on Ctrl-D.
    reply=""
    read -rp "Install Oh My Zsh? (theme + plugin framework for zsh) [Y/n]: " reply || true
    reply="${reply:-y}"
    if [[ "$reply" =~ ^[Yy]$ ]]; then want=yes; else want=no; fi
  else
    # Non-interactive (curl|bash, CI) and no preference set — default yes.
    want=yes
  fi
fi

if [[ "$want" != "yes" ]]; then
  info "Skipping Oh My Zsh install (set MAC_SETUP_OMZ=yes to install without prompt)"
  return 0 2>/dev/null || exit 0
fi

if [[ ! -d "$HOME/.oh-my-zsh" ]]; then
  info "Installing Oh My Zsh..."
  RUNZSH=no KEEP_ZSHRC=yes bash -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
else
  ok "Oh My Zsh framework already on disk at ~/.oh-my-zsh"
fi

# Make sure .zshrc exists before append_block tries to touch it.
[[ -f "$ZSHRC" ]] || touch "$ZSHRC"

if append_block "$ZSHRC" "oh-my-zsh" <<'OMZ_BLOCK'; then
# Oh My Zsh — theme + plugin framework
export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="robbyrussell"
plugins=(git)
source "$ZSH/oh-my-zsh.sh"
OMZ_BLOCK
  ok "Added Oh My Zsh block to $ZSHRC"
else
  ok "Oh My Zsh block already in $ZSHRC"
fi
