#!/usr/bin/env bash
set -euo pipefail

BIN_NAME="cf-dns"
BIN_PATH="/usr/local/bin/${BIN_NAME}"
LOG_FILE="/var/log/cf-dns-update.log"
RC_FILE="$HOME/.bashrc"

say(){ printf "[*] %s\n" "$*"; }
ok(){ printf "[OK] %s\n" "$*"; }
err(){ printf "[ERR] %s\n" "$*" >&2; }
have(){ command -v "$1" >/dev/null 2>&1; }

remove_cron(){
  local existing; existing="$(crontab -l 2>/dev/null || true)"
  local line="0 * * * * ${BIN_PATH} update --type A >> ${LOG_FILE} 2>&1"
  if printf "%s\n" "$existing" | grep -Fq "$line"; then
    printf "%s\n" "$existing" | grep -Fvx "$line" | crontab -
    ok "Removed hourly cron job."
  else
    say "No cron job to remove."
  fi
}

remove_binary(){
  if [[ -f "$BIN_PATH" ]]; then
    if [[ ! -w "$BIN_PATH" ]] && have sudo; then sudo rm -f "$BIN_PATH"; else rm -f "$BIN_PATH"; fi
    ok "Removed ${BIN_PATH}"
  else
    say "Binary not found at ${BIN_PATH}"
  fi
}

clean_env_lines(){
  local bak="${RC_FILE}.bak.$(date +%s)"
  if [[ -f "$RC_FILE" ]]; then
    cp "$RC_FILE" "$bak"
    grep -Fv 'export CF_API_TOKEN=' "$bak" | grep -Fv 'export CF_DEFAULT_ZONE=' > "$RC_FILE"
    ok "Removed CF_API_TOKEN and CF_DEFAULT_ZONE from ${RC_FILE} (backup: ${bak})"
  else
    say "RC file ${RC_FILE} not found; skipping."
  fi
}

maybe_remove_log(){
  if [[ -f "$LOG_FILE" ]]; then
    read -r -p "Remove log file ${LOG_FILE}? [y/N] " ans
    if [[ "$ans" =~ ^[Yy]$ ]]; then
      if [[ ! -w "$LOG_FILE" ]] && have sudo; then sudo rm -f "$LOG_FILE"; else rm -f "$LOG_FILE"; fi
      ok "Removed log file."
    else
      say "Keeping log file."
    fi
  fi
}

main(){
  remove_cron
  remove_binary
  clean_env_lines
  maybe_remove_log
  ok "Uninstall complete. You may need to 'source ${RC_FILE}' or restart your shell."
}

main "$@"
