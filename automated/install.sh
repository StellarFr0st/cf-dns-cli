#!/usr/bin/env bash
set -euo pipefail

BIN_NAME="cf-dns"
BIN_PATH="/usr/local/bin/${BIN_NAME}"
LOG_FILE="/var/log/cf-dns-update.log"
RC_FILE="$HOME/.bashrc"

GITHUB_REPO_URL="https://github.com/StellarFr0st/cf-dns-cli/raw/main/manual/cf-dns.sh"

say(){ printf "[*] %s\n" "$*"; }
ok(){ printf "[OK] %s\n" "$*"; }
err(){ printf "[ERR] %s\n" "$*" >&2; }
have(){ command -v "$1" >/dev/null 2>&1; }
confirm_default_yes(){ local a; read -r -p "$1 [Y/n] " a; [[ -z "$a" || "$a" =~ ^[Yy]$ ]]; }

require_sudo_if_needed(){
  local dir="$1"
  if [[ ! -w "$dir" ]]; then
    have sudo || { err "Need write access to $dir and no 'sudo' available."; exit 1; }
    echo "sudo"
  else
    echo ""
  fi
}

download_to(){
  local url="$1" dest="$2"
  if have wget; then
    wget -qO "$dest" "$url"
  elif have curl; then
    curl -fsSL "$url" -o "$dest"
  else
    err "Neither wget nor curl is available."; exit 1
  fi
}

append_if_missing(){
  local file="$1" line="$2"
  grep -Fqs -- "$line" "$file" 2>/dev/null || printf "%s\n" "$line" >> "$file"
}

install_cli(){
  say "Downloading Cloudflare DNS CLI from placeholder URL:"
  say "  $GITHUB_REPO_URL"
  local tmp; tmp="$(mktemp)"
  download_to "$GITHUB_REPO_URL" "$tmp"
  head -n1 "$tmp" | grep -Eq '^#!' || { err "Downloaded file doesn't look like a script."; rm -f "$tmp"; exit 1; }
  local sudo_cmd; sudo_cmd="$(require_sudo_if_needed "/usr/local/bin")"
  $sudo_cmd mv "$tmp" "$BIN_PATH"
  $sudo_cmd chmod 0755 "$BIN_PATH"
  ok "Installed ${BIN_NAME} to ${BIN_PATH}"
}

ensure_logfile(){
  local sudo_cmd; sudo_cmd="$(require_sudo_if_needed "$(dirname "$LOG_FILE")")"
  if [[ ! -f "$LOG_FILE" ]]; then
    $sudo_cmd touch "$LOG_FILE"
    $sudo_cmd chmod 600 "$LOG_FILE"
  fi
}

persist_env(){
  local token="$1" zone="$2"
  say "Persisting environment variables to: $RC_FILE"
  touch "$RC_FILE"
  append_if_missing "$RC_FILE" "export CF_API_TOKEN=\"$token\""
  append_if_missing "$RC_FILE" "export CF_DEFAULT_ZONE=\"$zone\""
  ok "Saved CF_API_TOKEN and CF_DEFAULT_ZONE to $RC_FILE"

  # Source it immediately for this session
  # shellcheck disable=SC1090
  source "$RC_FILE" || true
  ok "Sourced $RC_FILE"
}

install_cron_hourly(){
  say "Setting up hourly cron job for: ${BIN_PATH} update --type A"
  ensure_logfile
  local existing; existing="$(crontab -l 2>/dev/null || true)"
  local line="0 * * * * ${BIN_PATH} update --type A >> ${LOG_FILE} 2>&1"
  if printf "%s\n" "$existing" | grep -Fq "$line"; then
    ok "Cron job already present."
    return
  fi
  { printf "%s\n" "$existing"; printf "%s\n" "$line"; } | crontab -
  ok "Cron job installed (hourly)."
}

main(){
  install_cli

  say "Enter your Cloudflare API token (input hidden):"
  read -rs CF_API_TOKEN
  echo
  [[ -n "$CF_API_TOKEN" ]] || { err "API token cannot be empty."; exit 1; }

  read -rp "Enter your default zone (e.g., example.com): " CF_DEFAULT_ZONE
  [[ -n "$CF_DEFAULT_ZONE" ]] || { err "Zone cannot be empty."; exit 1; }

  persist_env "$CF_API_TOKEN" "$CF_DEFAULT_ZONE"

  if confirm_default_yes "Set up an hourly cron job to update all A records?"; then
    install_cron_hourly
  else
    say "Skipping cron job setup."
  fi

  ok "Done. Try:  ${BIN_PATH} list"
}

main "$@"
