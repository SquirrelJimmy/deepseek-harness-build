# Minimal default zsh configuration for the container's node user.
# Keep this dependency-free: no Oh My Zsh, Starship, or host-specific paths.
# Mount your own file over /home/node/.zshrc to customize it.

HISTFILE="$HOME/.zsh_history"
HISTSIZE=10000
SAVEHIST=10000
setopt HIST_IGNORE_DUPS SHARE_HISTORY

autoload -Uz compinit
compinit -i

unsetopt BEEP

export EDITOR=vim

PROMPT='%n@%m %~ %# '
