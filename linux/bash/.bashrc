[[ $- != *i* ]] && return

# History
HISTSIZE=10000
HISTFILESIZE=20000
HISTCONTROL=ignoreboth:erasedups
HISTTIMEFORMAT='%F %H:%M '

shopt -s histappend
shopt -s cmdhist
shopt -s lithist

PROMPT_COMMAND='history -a; history -n'

# Shell behavior
shopt -s checkwinsize

alias ll='ls -lah'
alias la='ls -A'
alias l='ls -CF'

alias ..='cd ..'
alias ...='cd ../..'

reload() {
	source ~/.bashrc
}

whichcmd() {
	[[ $# -gt 0 ]] || {
		echo "Usage: whichcmd <command>"
		return 1
	}

	type -a -- "$1"
}
