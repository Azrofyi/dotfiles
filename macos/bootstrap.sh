#!/usr/bin/env bash

set -euo pipefail

# -----------------------------------------------------------------------------
# Constants
# -----------------------------------------------------------------------------

GREEN="\033[0;32m"
YELLOW="\033[1;33m"
RED="\033[0;31m"
RESET="\033[0m"

readonly GREEN
readonly YELLOW
readonly RED
readonly RESET

SCRIPT_DIR="$(
	cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &&
		pwd -P
)"
readonly SCRIPT_DIR

OMZ_DIR="${ZSH:-$HOME/.oh-my-zsh}"
readonly OMZ_DIR

# -----------------------------------------------------------------------------
# Output
# -----------------------------------------------------------------------------

log_info() {
	printf '%b\n' "${YELLOW}[*] $1${RESET}"
}

log_ok() {
	printf '%b\n' "${GREEN}[OK] $1${RESET}"
}

log_error() {
	printf '%b\n' "${RED}[ERROR] $1${RESET}" >&2
}

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

confirm() {
	local response

	printf '%b' "${YELLOW}$1 [y/N]: ${RESET}"

	if ! read -r response; then
		return 1
	fi

	[[ "$response" =~ ^[Yy]$ ]]
}

require_command() {
	local command_name="$1"

	if command -v "$command_name" >/dev/null 2>&1; then
		return
	fi

	log_error "Required command not found: $command_name"
	return 1
}

has_developer_tools() {
	xcode-select -p &>/dev/null
}

find_brew() {
	if command -v brew >/dev/null 2>&1; then
		command -v brew
		return
	fi

	if [[ -x /opt/homebrew/bin/brew ]]; then
		printf '%s\n' '/opt/homebrew/bin/brew'
		return
	fi

	if [[ -x /usr/local/bin/brew ]]; then
		printf '%s\n' '/usr/local/bin/brew'
		return
	fi

	return 1
}

activate_brew() {
	local brew_bin

	if ! brew_bin="$(find_brew)"; then
		return 1
	fi

	eval "$("$brew_bin" shellenv bash)"
}

install_git_repo() {
	local repo="$1"
	local destination="$2"

	if [[ -d "$destination/.git" ]]; then
		log_ok "Already installed: $(basename "$destination")"
		return
	fi

	if [[ -e "$destination" ]]; then
		log_error \
			"Destination already exists and is not a Git repository: $destination"
		return 1
	fi

	git clone "$repo" "$destination"
}

# -----------------------------------------------------------------------------
# Xcode Command Line Tools
# -----------------------------------------------------------------------------

install_xcode_clt() {
	if has_developer_tools; then
		log_ok "Apple developer tools already available: $(xcode-select -p)"
		return
	fi

	log_info "Requesting Xcode Command Line Tools installation..."

	if ! xcode-select --install 2>/dev/null; then
		log_info "Xcode Command Line Tools installer may already be running."
	fi

	printf '\n'
	printf '%s\n' \
		"Complete the Xcode Command Line Tools installation in the macOS dialog."

	read -r -p "Press Enter when installation is finished..."

	if ! has_developer_tools; then
		log_error "Xcode Command Line Tools are still unavailable."
		return 1
	fi

	log_ok "Xcode Command Line Tools installed."
}

# -----------------------------------------------------------------------------
# Rosetta
# -----------------------------------------------------------------------------

install_rosetta() {
	if pkgutil \
		--pkg-info=com.apple.pkg.RosettaUpdateAuto \
		&>/dev/null; then

		log_ok "Rosetta 2 already installed."
		return
	fi

	log_info "Installing Rosetta 2..."

	sudo /usr/sbin/softwareupdate \
		--install-rosetta \
		--agree-to-license

	log_ok "Rosetta 2 installed."
}

# -----------------------------------------------------------------------------
# Homebrew
# -----------------------------------------------------------------------------

install_brew() {
	local brew_bin

	if brew_bin="$(find_brew)"; then
		log_ok "Homebrew already installed: $brew_bin"
	else
		if ! has_developer_tools; then
			log_error \
				"Homebrew requires Xcode Command Line Tools or Xcode."
			return 1
		fi

		log_info "Installing Homebrew..."

		/bin/bash -c "$(
			curl -fsSL \
				https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh
		)"

		if ! brew_bin="$(find_brew)"; then
			log_error \
				"Homebrew installer completed, but brew executable was not found."
			return 1
		fi

		log_ok "Homebrew installed: $brew_bin"
	fi

	eval "$("$brew_bin" shellenv bash)"

	brew analytics off
	brew update-if-needed

	log_ok "Homebrew ready."
}

apply_brewfile() {
	local file="$1"

	if [[ ! -f "$file" ]]; then
		log_error "Brewfile not found: $file"
		return 1
	fi

	if ! activate_brew; then
		log_error "Homebrew is not available."
		return 1
	fi

	log_info "Installing Homebrew packages from $(basename "$file")..."

	brew bundle \
		--no-upgrade \
		--file="$file"

	log_ok "$(basename "$file") applied."
}

# -----------------------------------------------------------------------------
# Oh My Zsh
# -----------------------------------------------------------------------------

install_omz() {
	if [[ -d "$OMZ_DIR" ]]; then
		log_ok "Oh My Zsh already installed."
		return
	fi

	require_command git

	log_info "Installing Oh My Zsh..."

	RUNZSH=no \
		CHSH=no \
		KEEP_ZSHRC=yes \
		/bin/sh -c "$(
		curl -fsSL \
			https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh
	)"

	log_ok "Oh My Zsh installed."
}

install_zsh_plugins() {
	if [[ ! -d "$OMZ_DIR" ]]; then
		log_error \
			"Oh My Zsh is not installed. Install it before installing Zsh plugins."
		return 1
	fi

	require_command git

	local custom_dir="${ZSH_CUSTOM:-$OMZ_DIR/custom}/plugins"

	log_info "Installing Zsh plugins..."

	mkdir -p "$custom_dir"

	install_git_repo \
		'https://github.com/zsh-users/zsh-autosuggestions' \
		"$custom_dir/zsh-autosuggestions"

	install_git_repo \
		'https://github.com/zdharma-continuum/fast-syntax-highlighting.git' \
		"$custom_dir/fast-syntax-highlighting"

	install_git_repo \
		'https://github.com/Aloxaf/fzf-tab' \
		"$custom_dir/fzf-tab"

	log_ok "Zsh plugins installed."
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

main() {
	if [[ "$(uname -s)" != 'Darwin' ]]; then
		log_error "This script is intended for macOS only."
		return 1
	fi

	log_info "Setting up Mac..."

	confirm "Install Xcode Command Line Tools?" &&
		install_xcode_clt

	if [[ "$(uname -m)" == 'arm64' ]]; then
		confirm "Install Rosetta 2?" &&
			install_rosetta
	fi

	confirm "Install Homebrew?" &&
		install_brew

	confirm "Apply Brewfile $SCRIPT_DIR/Brewfile?" &&
		apply_brewfile "$SCRIPT_DIR/Brewfile"

	confirm "Install Oh My Zsh?" &&
		install_omz

	confirm "Install Zsh plugins?" &&
		install_zsh_plugins

	log_ok "Setup complete."
}

main "$@"
