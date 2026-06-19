#!/bin/bash
set -eux -o pipefail

# First-boot-only (#177). Lima's user-phase provisioning, re-run on every
# boot; skip the network install and the rc-file writes once done. The
# marker is user-owned — this phase runs as the Lima user and /etc/vergil
# is root-owned — and is stamped LAST so a partial run (uv installed but
# rc files not yet written) re-runs on the next boot.
if [ -f "$HOME/.vergil/provisioned.uv" ]; then exit 0; fi

# Install uv (Python package manager)
curl -LsSf https://astral.sh/uv/install.sh | sh
export PATH="$HOME/.local/bin:$PATH"
uv --version

# Minimal zsh configuration
cat > "$HOME/.zshrc" << 'ZSHRC'
export PATH="$HOME/.local/bin:$PATH"

# Belt-and-suspenders for interactive shells (issues #85, #110). The
# authoritative disable is /etc/claude-code/managed-settings.json —
# Claude Code is usually spawned with no shell at all, so this export
# never reaches it on that path.
export DISABLE_AUTOUPDATER=1

autoload -Uz compinit && compinit

# Generic, least-surprise interactive defaults (issue #171). Only
# conventional settings a normal zsh user would expect — no idiosyncratic
# or behavior-changing options. These affect interactive human sessions
# only; agents run shell-less or via non-interactive bash and never source
# this file. No ~/.zshrc.local override hook: the VM has no mechanism to
# provision such a file, so a dangling `source` line would only invite
# manual editing of VM contents. A personal-customization story is deferred
# until there is a real host-side provisioning mechanism to pair with it.

# --- Interactive papercuts ---
# IGNORE_EOF: Ctrl-D no longer drops the shell mid-session; type `exit` to
#   leave. zsh's option is all-or-nothing (no bash-style press-N-times
#   count). INTERACTIVE_COMMENTS: honor `#` on the command line so pasting a
#   command with a trailing `# comment` runs instead of erroring. BEEP: kill
#   the terminal bell.
setopt IGNORE_EOF
setopt INTERACTIVE_COMMENTS
unsetopt BEEP

# --- History ---
setopt HIST_IGNORE_DUPS
setopt SHARE_HISTORY
setopt EXTENDED_HISTORY        # timestamp each entry
setopt HIST_IGNORE_SPACE      # leading-space commands stay out of history
setopt HIST_REDUCE_BLANKS     # normalize whitespace before saving
setopt HIST_FIND_NO_DUPS      # history search skips repeats
HISTFILE="$HOME/.zsh_history"
HISTSIZE=50000
SAVEHIST=50000

# --- Navigation ---
# cd maintains a directory stack; invisible unless you reach for `cd -<TAB>`.
setopt AUTO_PUSHD PUSHD_IGNORE_DUPS PUSHD_SILENT

# --- Completion ---
setopt COMPLETE_IN_WORD
zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}'   # case-insensitive
zstyle ':completion:*' list-colors "${(s.:.)LS_COLORS}"     # colored menu

# --- Globbing & misc ---
setopt EXTENDED_GLOB
export LESS=-R
alias ls='ls --color=auto'    # benign: adds color, changes no semantics

# --- Keybinding correctness over SSH/tmux ---
# Home / End / Delete / Ctrl-Left / Ctrl-Right are frequently broken under
# SSH and tmux. Bind the common escape sequences explicitly; this fixes
# broken keys rather than changing behavior.
bindkey '^[[H'    beginning-of-line       # Home
bindkey '^[[F'    end-of-line             # End
bindkey '^[[1~'   beginning-of-line       # Home (rxvt/linux console)
bindkey '^[[4~'   end-of-line             # End  (rxvt/linux console)
bindkey '^[[3~'   delete-char             # Delete
bindkey '^[[1;5C' forward-word            # Ctrl-Right
bindkey '^[[1;5D' backward-word           # Ctrl-Left

# Prompt: identity-colored role + working dir on two lines (issue #153).
# Only the role token is colored, so "which agent am I" is a pre-attentive
# glance. Identity comes from VRG_IDENTITY_MODE (set in ~/.zshenv before
# this runs); it never changes within a VM, so we bake the value/color at
# init rather than re-evaluating per prompt. The path stays literal (%~
# shows a tilde only when genuinely in $HOME).
case "${VRG_IDENTITY_MODE:-}" in
  user)  _vrg_role='user';        _vrg_role_c='%F{green}' ;;
  audit) _vrg_role='audit';       _vrg_role_c='%F{214}'   ;;  # amber
  admin) _vrg_role='admin';       _vrg_role_c='%F{red}'   ;;  # future
  *)     _vrg_role='no-identity'; _vrg_role_c='%F{red}'   ;;  # uncredentialed
esac
PROMPT="[role=${_vrg_role_c}${_vrg_role}%f %~]"$'\n'"$ "
ZSHRC

# Identity-mode export for zsh (issue #148). VRG_IDENTITY_MODE is the
# fast Layer-1 signal that the identity-aware wrappers (vrg-git, vrg-gh,
# vrg-submit-pr) and skill preflights read; the durable source of truth
# is ~/.config/vergil/identity-mode, written per-VM at credential-
# injection time. Export it from ~/.zshenv, NOT ~/.bashrc: this VM's
# shell is zsh (chsh above), which never sources ~/.bashrc, and ~/.zshenv
# is the one zsh hook sourced for EVERY invocation — interactive,
# non-interactive, login, and non-login — so a `zsh -c` command sees the
# same value an interactive session does. The file-presence guard makes
# the line a no-op until the mode file is injected, so it is safe to bake
# into the uncredentialed image. The truly shell-less path (Claude Code
# spawned directly by sshd, SHLVL=0) sources no rc at all; there identity
# must come from the resolver's mode-file fallback
# (vergil_tooling.lib.identity_mode.current_mode()), never this env var.
cat > "$HOME/.zshenv" << 'ZSHENV'
[ -f ~/.config/vergil/identity-mode ] && export VRG_IDENTITY_MODE="$(cat ~/.config/vergil/identity-mode)"
ZSHENV

# First-boot completion marker for this user-phase step (#177), stamped
# LAST so a partial run re-runs next boot.
mkdir -p "$HOME/.vergil"
touch "$HOME/.vergil/provisioned.uv"
