#!/usr/bin/env bash
# cf-dns-cli.sh
# List/Add/Update/Remove Cloudflare DNS records
# Supports: A, AAAA, CNAME, TXT, MX, NS, SRV, CAA
# Subcommands: list | add --type TYPE | update --type TYPE | remove --type TYPE
# Requirements: bash, curl, jq
set -euo pipefail

########################################
#      SILENT DEPENDENCY CHECK/INSTALL #
########################################
log(){ printf '%s %s\n' "$(date '+%d-%m-%Y %H:%M:%S')" "$*"; }
err(){ printf 'ERROR: %s\n' "$*" >&2; }

_detect_pkg_manager() {
  if command -v apt-get >/dev/null 2>&1; then echo "apt"; return; fi
  if command -v dnf      >/dev/null 2>&1; then echo "dnf"; return; fi
  if command -v yum      >/dev/null 2>&1; then echo "yum"; return; fi
  if command -v apk      >/dev/null 2>&1; then echo "apk"; return; fi
  if command -v pacman   >/dev/null 2>&1; then echo "pacman"; return; fi
  if command -v zypper   >/dev/null 2>&1; then echo "zypper"; return; fi
  if command -v brew     >/dev/null 2>&1; then echo "brew"; return; fi
  echo "unknown"
}

_install_pkgs() {
  local pm="$1"; shift
  local SUDO=""
  if [[ "$(id -u)" -ne 0 ]] && command -v sudo >/dev/null 2>&1; then SUDO="sudo"; fi
  case "$pm" in
    apt)
      ${SUDO} env DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null 2>&1 || true
      ${SUDO} env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" >/dev/null 2>&1
      ;;
    dnf)    ${SUDO} dnf -y install "$@" >/dev/null 2>&1 ;;
    yum)    ${SUDO} yum -y install "$@" >/dev/null 2>&1 ;;
    apk)    ${SUDO} apk update >/dev/null 2>&1 || true; ${SUDO} apk add --no-progress "$@" >/dev/null 2>&1 ;;
    pacman) ${SUDO} pacman -Sy --noconfirm --needed "$@" >/dev/null 2>&1 ;;
    zypper) ${SUDO} zypper -n in -y "$@" >/dev/null 2>&1 ;;
    brew)   brew update >/dev/null 2>&1 || true; brew install "$@" >/dev/null 2>&1 ;;
    *)      return 1 ;;
  esac
}

ensure_dependencies() {
  local needed=(curl jq) missing=()
  for c in "${needed[@]}"; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
  if ((${#missing[@]}==0)); then echo "All dependencies found."; return 0; fi
  local pm; pm="$(_detect_pkg_manager)"
  if [[ "$pm" == "unknown" ]]; then
    err "Missing: ${missing[*]} — no supported package manager found."; exit 1
  fi
  if _install_pkgs "$pm" "${missing[@]}"; then
    local still=(); for c in "${missing[@]}"; do command -v "$c" >/dev/null 2>&1 || still+=("$c"); done
    if ((${#still[@]}==0)); then echo "Installed dependencies: ${missing[*]}"; return 0; fi
    err "Failed to install: ${still[*]} (via $pm)."; exit 1
  else
    err "Failed to install: ${missing[*]} (via $pm)."; exit 1
  fi
}

ensure_dependencies

########################################
#               DEFAULTS               #
########################################
ZONE_NAME="${CF_DEFAULT_ZONE:-example.com}"
PROXIED_DEFAULT=false
TTL_DEFAULT=300                 # 1 = Auto
MX_PRIORITY_DEFAULT=10
SRV_PRIORITY_DEFAULT=10
SRV_WEIGHT_DEFAULT=5
SRV_PORT_DEFAULT=443
CAA_FLAG_DEFAULT=0              # 0 or 128
CAA_TAG_DEFAULT="issue"         # issue | issuewild | iodef

########################################
#               AUTH/API               #
########################################
: "${CF_API_TOKEN:?Set CF_API_TOKEN environment variable with your Cloudflare API token}"
CF_API="https://api.cloudflare.com/client/v4"
HDR_AUTH=("Authorization: Bearer ${CF_API_TOKEN}" "Content-Type: application/json")

cf_get(){  curl -fsS -H "${HDR_AUTH[0]}" -H "${HDR_AUTH[1]}" "$@"; }
cf_send(){ local m="$1" u="$2" d="${3:-}"; shift 3 || true
           curl -fsS -X "$m" -H "${HDR_AUTH[0]}" -H "${HDR_AUTH[1]}" ${d:+--data "$d"} "$u" "$@"; }

########################################
#               HELP                   #
########################################
usage(){
cat <<'EOF'
Usage:
  cloudflare-dns-cli.sh <subcommand> [options] [...]

Subcommands:
  list                          List records (all types or filter with --type)
  add     --type TYPE  ARGS...  Create a record of TYPE
  update  --type TYPE  ARGS...  Update record(s) of TYPE (idempotent)
  remove  --type TYPE  NAMES... Remove record(s) of TYPE

Common options:
  -z, --zone ZONE               Zone (default from CF_DEFAULT_ZONE or script)
  --type TYPE                   A, AAAA, CNAME, TXT, MX, NS, SRV, CAA
  --ttl SECONDS                 TTL (default 300; 1 = Auto)
  --proxied true|false          (A/AAAA/CNAME) default false
  --force                       Skip confirmation on remove
  -h, --help                    Show this help

Type-specific args:
  A:      add/update: NAMES... [--ip IPv4] (auto-detects if omitted)
          update with NO NAMES updates **all A** in the zone
  AAAA:   add/update: NAMES... [--ip6 IPv6] (auto-detects if omitted)
          update with NO NAMES updates **all AAAA** in the zone
  CNAME:  add/update: NAME TARGET            (repeat pairs)
  TXT:    add/update: NAME VALUE             (repeat pairs; quote VALUE)
  MX:     add/update: NAME EXCHANGE [--priority N]  (repeat pairs)
  NS:     add/update: NAME HOST              (repeat pairs)
  SRV:    add/update: NAME --service _svc --proto _tcp|_udp --target HOST
                 [--priority N] [--weight N] [--port N]
  CAA:    add/update: NAME --caa-flag 0|128 --caa-tag issue|issuewild|iodef --caa-value VALUE
EOF
}

########################################
#               UTILS                  #
########################################
get_ipv4(){
  local ip
  for u in "https://api.ipify.org" "https://ipv4.icanhazip.com" "https://ifconfig.me/ip"; do
    ip="$(curl -fsS "$u" || true)"
    ip="$(printf '%s' "$ip" | tr -d '\r\n[:space:]')"   # trim
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && { echo "$ip"; return 0; }
  done; return 1
}
get_ipv6(){
  local ip
  for u in "https://api64.ipify.org" "https://ipv6.icanhazip.com"; do
    ip="$(curl -fsS "$u" || true)"
    ip="$(printf '%s' "$ip" | tr -d '\r\n[:space:]')"   # trim
    [[ "$ip" =~ ^([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}$ ]] && { echo "$ip"; return 0; }
  done; return 1
}
get_zone_id(){ local name="$1"; cf_get "${CF_API}/zones?name=${name}" | jq -r '.result[0].id // empty'; }
fqdn_of(){
  local name="$1" zone="$2"
  if [[ "$name" == "@" ]]; then echo "$zone"; return 0; fi
  [[ "$name" == *"."* ]] && { echo "$name"; return 0; }
  echo "${name}.${zone}"
}
get_dns_record(){ # first match
  local zid="$1" type="$2" fqdn="$3"
  cf_get "${CF_API}/zones/${zid}/dns_records?type=${type}&name=$(printf %s "$fqdn" | sed 's/%/%25/g')" \
    | jq -c '.result[0] // empty'
}
list_records(){
  local zid="$1" type="${2:-}" page=1 per=100 out="[]"
  while :; do
    local url="${CF_API}/zones/${zid}/dns_records?page=${page}&per_page=${per}"
    [[ -n "$type" ]] && url="${url}&type=${type}"
    local resp; resp="$(cf_get "$url")"
    local chunk; chunk="$(jq '.result' <<<"$resp")"
    out="$(jq -s 'add' <(printf '%s' "$out") <(printf '%s' "$chunk"))"
    local total; total="$(jq -r '.result_info.total_pages' <<<"$resp")"
    (( page >= total )) && break; ((page++))
  done; printf '%s' "$out"
}

########################################
#        Verification helpers          #
########################################
assert_record_field(){
  local zid="$1" id="$2" field="$3" expect="$4"
  local got; got="$(cf_get "${CF_API}/zones/${zid}/dns_records/${id}" | jq -r --arg f "$field" '.result[$f] // empty')"
  [[ "$got" == "$expect" ]] || { err "Verification failed: ${field}='${got}', expected '${expect}'"; exit 1; }
}
assert_record_data_field(){
  local zid="$1" id="$2" field="$3" expect="$4"
  local got; got="$(cf_get "${CF_API}/zones/${zid}/dns_records/${id}" | jq -r --arg f "$field" '.result.data[$f] // empty')"
  [[ "$got" == "$expect" ]] || { err "Verification failed: data.${field}='${got}', expected '${expect}'"; exit 1; }
}
assert_record_absent(){
  local zid="$1" id="$2"
  if cf_get "${CF_API}/zones/${zid}/dns_records/${id}" >/dev/null 2>&1; then
    err "Verification failed: record ${id} still exists"; exit 1
  fi
}

########################################
#   Generic create/patch/delete        #
########################################
_create_record(){
  local zid="$1" type="$2" name="$3" content="$4" proxied="${5:-false}" ttl="${6:-$TTL_DEFAULT}" priority="${7:-$MX_PRIORITY_DEFAULT}" extra="${8:-}"
  local body
  case "$type" in
    A|AAAA|CNAME)
      body="$(jq -cn --arg type "$type" --arg name "$name" --arg content "$content" --argjson proxied "$proxied" --argjson ttl "$ttl" \
                   '{type:$type,name:$name,content:$content,proxied:$proxied,ttl:$ttl}')" ;;
    TXT|NS|MX)
      if [[ "$type" == "MX" ]]; then
        body="$(jq -cn --arg name "$name" --arg content "$content" --argjson ttl "$ttl" --argjson p "$priority" \
                     '{type:"MX",name:$name,content:$content,priority:$p,ttl:$ttl}')" 
      else
        body="$(jq -cn --arg type "$type" --arg name "$name" --arg content "$content" --argjson ttl "$ttl" \
                     '{type:$type,name:$name,content:$content,ttl:$ttl}')"
      fi ;;
    SRV|CAA)
      body="$(jq -cn --arg type "$type" --arg name "$name" --argjson ttl "$ttl" --argjson data "$extra" \
                   '{type:$type,name:$name,ttl:$ttl,data:$data}')" ;;
    *) err "Unsupported type for create: $type"; exit 2 ;;
  esac
  cf_send POST "${CF_API}/zones/${zid}/dns_records" "$body"
}
_patch_record(){
  local zid="$1" id="$2" type="$3" name="$4" content="$5" proxied="${6:-false}" ttl="${7:-$TTL_DEFAULT}" priority="${8:-$MX_PRIORITY_DEFAULT}" extra="${9:-}"
  local body
  case "$type" in
    A|AAAA|CNAME)
      body="$(jq -cn --arg type "$type" --arg name "$name" --arg content "$content" --argjson proxied "$proxied" --argjson ttl "$ttl" \
                   '{type:$type,name:$name,content:$content,proxied:$proxied,ttl:$ttl}')" ;;
    TXT|NS|MX)
      if [[ "$type" == "MX" ]]; then
        body="$(jq -cn --arg name "$name" --arg content "$content" --argjson ttl "$ttl" --argjson p "$priority" \
                     '{type:"MX",name:$name,content:$content,priority:$p,ttl:$ttl}')" 
      else
        body="$(jq -cn --arg type "$type" --arg name "$name" --arg content "$content" --argjson ttl "$ttl" \
                     '{type:$type,name:$name,content:$content,ttl:$ttl}')"
      fi ;;
    SRV|CAA)
      body="$(jq -cn --arg type "$type" --arg name "$name" --argjson ttl "$ttl" --argjson data "$extra" \
                   '{type:$type,name:$name,ttl:$ttl,data:$data}')" ;;
    *) err "Unsupported type for update: $type"; exit 2 ;;
  esac
  cf_send PATCH "${CF_API}/zones/${zid}/dns_records/${id}" "$body"
}
_delete_record(){ local zid="$1" id="$2"; cf_send DELETE "${CF_API}/zones/${zid}/dns_records/${id}"; }

########################################
#      Type-specific wrappers (+verify)
########################################
create_simple(){
  local zid="$1" type="$2" name="$3" content="$4" prox="$5" ttl="$6" prio="${7:-$MX_PRIORITY_DEFAULT}"
  local r ok id
  r="$(_create_record "$zid" "$type" "$name" "$content" "$prox" "$ttl" "$prio")"
  ok="$(jq -r '.success' <<<"$r")"; [[ "$ok" == "true" ]] || { err "Create $type failed: $(jq -c '.' <<<"$r")"; exit 1; }
  id="$(jq -r '.result.id' <<<"$r")"
  if [[ "$type" == "MX" ]]; then
    assert_record_field "$zid" "$id" "content" "$content"; assert_record_field "$zid" "$id" "priority" "$prio"
  else
    assert_record_field "$zid" "$id" "content" "$content"
  fi
  log "Created: $type ${name} → ${content}$( [[ "$type" == "MX" ]] && printf ' (priority=%s)' "$prio" ) (ttl=${ttl})"
}
patch_simple(){
  local zid="$1" id="$2" type="$3" name="$4" content="$5" prox="$6" ttl="$7" prio="${8:-$MX_PRIORITY_DEFAULT}"
  local r ok
  r="$(_patch_record "$zid" "$id" "$type" "$name" "$content" "$prox" "$ttl" "$prio")"
  ok="$(jq -r '.success' <<<"$r")"; [[ "$ok" == "true" ]] || { err "Update $type failed: $(jq -c '.' <<<"$r")"; exit 1; }
  if [[ "$type" == "MX" ]]; then
    assert_record_field "$zid" "$id" "content" "$content"; assert_record_field "$zid" "$id" "priority" "$prio"
  else
    assert_record_field "$zid" "$id" "content" "$content"
  fi
  log "Updated: $type ${name} → ${content}$( [[ "$type" == "MX" ]] && printf ' (priority=%s)' "$prio" ) (ttl=${ttl})"
}
create_srv(){
  local zid="$1" name="$2" svc="$3" proto="$4" target="$5" prio="$6" weight="$7" port="$8" ttl="$9"
  local data; data="$(jq -cn --arg s "$svc" --arg p "$proto" --arg n "$name" --arg t "$target" \
                         --argjson pr "$prio" --argjson w "$weight" --argjson po "$port" \
                         '{service:$s,proto:$p,name:$n,priority:$pr,weight:$w,port:$po,target:$t}')"
  local r ok id
  r="$(_create_record "$zid" "SRV" "$name" "" "false" "$ttl" "0" "$data")"
  ok="$(jq -r '.success' <<<"$r")"; [[ "$ok" == "true" ]] || { err "Create SRV failed: $(jq -c '.' <<<"$r")"; exit 1; }
  id="$(jq -r '.result.id' <<<"$r")"
  assert_record_data_field "$zid" "$id" "service" "$svc"
  assert_record_data_field "$zid" "$id" "proto" "$proto"
  assert_record_data_field "$zid" "$id" "target" "$target"
  log "Created: SRV ${svc}.${proto}.${name} → ${target}:${port} prio=${prio} weight=${weight} (ttl=${ttl})"
}
patch_srv(){
  local zid="$1" id="$2" name="$3" svc="$4" proto="$5" target="$6" prio="$7" weight="$8" port="$9" ttl="${10}"
  local data; data="$(jq -cn --arg s "$svc" --arg p "$proto" --arg n "$name" --arg t "$target" \
                         --argjson pr "$prio" --argjson w "$weight" --argjson po "$port" \
                         '{service:$s,proto:$p,name:$n,priority:$pr,weight:$w,port:$po,target:$t}')"
  local r ok
  r="$(_patch_record "$zid" "$id" "SRV" "$name" "" "false" "$ttl" "0" "$data")"
  ok="$(jq -r '.success' <<<"$r")"; [[ "$ok" == "true" ]] || { err "Update SRV failed: $(jq -c '.' <<<"$r")"; exit 1; }
  assert_record_data_field "$zid" "$id" "target" "$target"
  log "Updated: SRV ${svc}.${proto}.${name} → ${target}:${port} prio=${prio} weight=${weight} (ttl=${ttl})"
}
create_caa(){
  local zid="$1" name="$2" flag="$3" tag="$4" value="$5" ttl="$6"
  local data; data="$(jq -cn --argjson f "$flag" --arg tag "$tag" --arg v "$value" '{flags:$f,tag:$tag,value:$v}')"
  local r ok id
  r="$(_create_record "$zid" "CAA" "$name" "" "false" "$ttl" "0" "$data")"
  ok="$(jq -r '.success' <<<"$r")"; [[ "$ok" == "true" ]] || { err "Create CAA failed: $(jq -c '.' <<<"$r")"; exit 1; }
  id="$(jq -r '.result.id' <<<"$r")"
  assert_record_data_field "$zid" "$id" "tag" "$tag"
  assert_record_data_field "$zid" "$id" "value" "$value"
  log "Created: CAA ${name} ${flag} ${tag} \"${value}\" (ttl=${ttl})"
}
patch_caa(){
  local zid="$1" id="$2" name="$3" flag="$4" tag="$5" value="$6" ttl="$7"
  local data; data="$(jq -cn --argjson f "$flag" --arg tag "$tag" --arg v "$value" '{flags:$f,tag:$tag,value:$v}')"
  local r ok
  r="$(_patch_record "$zid" "$id" "CAA" "$name" "" "false" "$ttl" "0" "$data")"
  ok="$(jq -r '.success' <<<"$r")"; [[ "$ok" == "true" ]] || { err "Update CAA failed: $(jq -c '.' <<<"$r")"; exit 1; }
  assert_record_data_field "$zid" "$id" "value" "$value"
  log "Updated: CAA ${name} ${flag} ${tag} \"${value}\" (ttl=${ttl})"
}
delete_record(){
  local zid="$1" id="$2" desc="$3"
  local r ok; r="$(_delete_record "$zid" "$id")"
  ok="$(jq -r '.success' <<<"$r")"; [[ "$ok" == "true" ]] || { err "Delete failed: $(jq -c '.' <<<"$r")"; exit 1; }
  assert_record_absent "$zid" "$id"; log "Removed: ${desc}"
}

########################################
#             SUBCOMMANDS              #
########################################
cmd_list(){
  local zone="$1" type="${2:-}"
  local zid; zid="$(get_zone_id "$zone")"; [[ -n "$zid" ]] || { err "Zone not found: $zone"; exit 1; }
  local arr; arr="$(list_records "$zid" "$type")"
  if [[ "$(jq 'length' <<<"$arr")" -eq 0 ]]; then
    [[ -n "$type" ]] && echo "No ${type} records in ${zone}." || echo "No DNS records in ${zone}."
    return 0
  fi
  printf '%-6s %-40s %-38s %-7s %-6s %s\n' "TYPE" "NAME" "CONTENT/DETAIL" "PROXY" "TTL" "ID"
  printf '%s\n' "-----------------------------------------------------------------------------------------------------------------------------------"
  jq -r '.[]
    | [ .type,
        .name,
        ( .content // (.data | tostring) ),
        ( if .proxied == null then "-" else (.proxied|tostring) end ),
        (.ttl|tostring),
        .id
      ]
    | @tsv' <<<"$arr" \
  | while IFS=$'\t' read -r typ name content prox ttl id; do
      printf '%-6s %-40s %-38s %-7s %-6s %s\n' "$typ" "$name" "$content" "$prox" "$ttl" "$id"
    done
}

cmd_add(){
  local type="$1" zone="$2" ttl="$3" prox="$4" ip="$5" ip6="$6" prio="$7" srv_service="$8" srv_proto="$9" srv_target="${10}" srv_priority="${11}" srv_weight="${12}" srv_port="${13}" caa_flag="${14}" caa_tag="${15}" caa_value="${16}"
  shift 16 || true
  local zid; zid="$(get_zone_id "$zone")"; [[ -n "$zid" ]] || { err "Zone not found: $zone"; exit 1; }
  case "$type" in
    A)
      [[ -n "$ip" ]] || ip="$(get_ipv4)" || { err "Could not detect public IPv4."; exit 1; }
      (( $# )) || { err "add A: specify at least one NAME"; exit 2; }
      for n in "$@"; do local fq="$(fqdn_of "$n" "$zone")"; [[ -z "$(get_dns_record "$zid" A "$fq")" ]] || { err "add A: $fq exists"; continue; }; create_simple "$zid" "A" "$fq" "$ip" "$prox" "$ttl"; done
      ;;
    AAAA)
      [[ -n "$ip6" ]] || ip6="$(get_ipv6)" || { err "Could not detect public IPv6; pass --ip6"; exit 1; }
      (( $# )) || { err "add AAAA: specify at least one NAME"; exit 2; }
      for n in "$@"; do local fq="$(fqdn_of "$n" "$zone")"; [[ -z "$(get_dns_record "$zid" AAAA "$fq")" ]] || { err "add AAAA: $fq exists"; continue; }; create_simple "$zid" "AAAA" "$fq" "$ip6" "$prox" "$ttl"; done
      ;;
    CNAME)
      (( $# >= 2 && ($# % 2 == 0) )) || { err "add CNAME: usage NAME TARGET [NAME TARGET ...]"; exit 2; }
      while (( $# )); do local name="$1"; shift; local target="$1"; shift; local fq="$(fqdn_of "$name" "$zone")"
        [[ -z "$(get_dns_record "$zid" CNAME "$fq")" ]] || { err "add CNAME: $fq exists"; continue; }
        create_simple "$zid" "CNAME" "$fq" "$target" "$prox" "$ttl"
      done
      ;;
    TXT)
      (( $# >= 2 && ($# % 2 == 0) )) || { err "add TXT: usage NAME VALUE [NAME VALUE ...]"; exit 2; }
      while (( $# )); do local name="$1"; shift; local val="$1"; shift; local fq="$(fqdn_of "$name" "$zone")"
        [[ -z "$(get_dns_record "$zid" TXT "$fq")" ]] || { err "add TXT: $fq exists"; continue; }
        create_simple "$zid" "TXT" "$fq" "$val" "false" "$ttl"
      done
      ;;
    MX)
      (( $# >= 2 && ($# % 2 == 0) )) || { err "add MX: usage NAME EXCHANGE [NAME EXCHANGE ...]"; exit 2; }
      while (( $# )); do local name="$1"; shift; local exch="$1"; shift; local fq="$(fqdn_of "$name" "$zone")"
        [[ -z "$(get_dns_record "$zid" MX "$fq")" ]] || { err "add MX: $fq exists"; continue; }
        create_simple "$zid" "MX" "$fq" "$exch" "false" "$ttl" "$prio"
      done
      ;;
    NS)
      (( $# >= 2 && ($# % 2 == 0) )) || { err "add NS: usage NAME HOST [NAME HOST ...]"; exit 2; }
      while (( $# )); do local name="$1"; shift; local host="$1"; shift; local fq="$(fqdn_of "$name" "$zone")"
        [[ -z "$(get_dns_record "$zid" NS "$fq")" ]] || { err "add NS: $fq exists"; continue; }
        create_simple "$zid" "NS" "$fq" "$host" "false" "$ttl"
      done
      ;;
    SRV)
      [[ -n "$srv_service" && -n "$srv_proto" && -n "$srv_target" ]] || { err "add SRV: require --service, --proto, --target"; exit 2; }
      (( $# >= 1 )) || { err "add SRV: specify at least one NAME"; exit 2; }
      local pr="${srv_priority:-$SRV_PRIORITY_DEFAULT}" we="${srv_weight:-$SRV_WEIGHT_DEFAULT}" po="${srv_port:-$SRV_PORT_DEFAULT}"
      for n in "$@"; do local fq="$(fqdn_of "$n" "$zone")"; [[ -z "$(get_dns_record "$zid" SRV "$fq")" ]] || { err "add SRV: $fq exists"; continue; }
        create_srv "$zid" "$fq" "$srv_service" "$srv_proto" "$srv_target" "$pr" "$we" "$po" "$ttl"
      done
      ;;
    CAA)
      [[ -n "$caa_tag" && -n "$caa_value" ]] || { err "add CAA: require --caa-tag and --caa-value"; exit 2; }
      local fl="${caa_flag:-$CAA_FLAG_DEFAULT}"
      (( $# >= 1 )) || { err "add CAA: specify at least one NAME"; exit 2; }
      for n in "$@"; do local fq="$(fqdn_of "$n" "$zone")"; [[ -z "$(get_dns_record "$zid" CAA "$fq")" ]] || { err "add CAA: $fq exists"; continue; }
        create_caa "$zid" "$fq" "$fl" "$caa_tag" "$caa_value" "$ttl"
      done
      ;;
    *) err "Unsupported TYPE for add: $type"; exit 2 ;;
  esac
}

cmd_update(){
  local type="$1" zone="$2" ttl="$3" prox="$4" ip="$5" ip6="$6" prio="$7" srv_service="$8" srv_proto="$9" srv_target="${10}" srv_priority="${11}" srv_weight="${12}" srv_port="${13}" caa_flag="${14}" caa_tag="${15}" caa_value="${16}"
  shift 16 || true
  local zid; zid="$(get_zone_id "$zone")"; [[ -n "$zid" ]] || { err "Zone not found: $zone"; exit 1; }

  case "$type" in
    A|AAAA)
      # Desired target IP (auto-detect if not provided), trim whitespace
      local desired=""
      if [[ "$type" == "A" ]]; then
        desired="${ip:-}"; [[ -n "$desired" ]] || desired="$(get_ipv4)" || { err "Could not detect public IPv4."; exit 1; }
      else
        desired="${ip6:-}"; [[ -n "$desired" ]] || desired="$(get_ipv6)" || { err "Could not detect public IPv6; pass --ip6"; exit 1; }
      fi
      desired="$(printf '%s' "$desired" | tr -d '\r\n[:space:]')"

      if (( $# )); then
        # targeted updates (idempotent)
        local changed=0 skipped=0
        for n in "$@"; do
          local fq rec id cur_content cur_prox cur_ttl
          fq="$(fqdn_of "$n" "$zone")"
          rec="$(get_dns_record "$zid" "$type" "$fq")"; [[ -n "$rec" ]] || { err "update $type: $fq not found"; continue; }
          id="$(jq -r '.id' <<<"$rec")"
          cur_content="$(jq -r '.content // empty' <<<"$rec")"
          cur_prox="$(jq -r 'if .proxied==null then "false" else (.proxied|tostring) end' <<<"$rec")"
          cur_ttl="$(jq -r '.ttl // empty' <<<"$rec")"
          local want_prox="${prox:-$cur_prox}"
          local want_ttl="${ttl:-$cur_ttl}"
          if [[ "$cur_content" == "$desired" && "$cur_prox" == "$want_prox" && "$cur_ttl" == "$want_ttl" ]]; then
            log "No change: $type ${fq} already ${desired} (proxied=${cur_prox} ttl=${cur_ttl})"
            ((skipped++)); continue
          fi
          patch_simple "$zid" "$id" "$type" "$fq" "$desired" "$want_prox" "$want_ttl"
          ((changed++))
        done
        log "Summary ($type): changed=${changed} skipped=${skipped} target=${desired}"
      else
        # BULK update (avoid subshell counters; compute plan with jq)
        local resp total to_update_ids changed_planned skipped
        resp="$(cf_get "${CF_API}/zones/${zid}/dns_records?type=${type}&page=1&per_page=1000")"
        total="$(jq -r '.result | length' <<<"$resp")"

        if [[ -z "${prox:-}" && -z "${ttl:-}" ]]; then
          to_update_ids="$(jq -r --arg want "$desired" '
            .result | map(select(.content != $want)) | .[].id
          ' <<<"$resp")"
        else
          to_update_ids="$(jq -r --arg want "$desired" --arg prox_in "${prox:-}" --arg ttl_in "${ttl:-}" '
            .result
            | map(select(
                (.content != $want)
                or ( ($prox_in != "") and ((.proxied|tostring) != $prox_in) )
                or ( ($ttl_in  != "") and ((.ttl|tostring)   != $ttl_in ) )
              ))
            | .[].id
          ' <<<"$resp")"
        fi

        changed_planned="$(printf '%s\n' "$to_update_ids" | grep -c . || true)"
        skipped=$(( total - changed_planned ))

        while read -r id; do
          [[ -n "$id" ]] || continue
          local rec name cur_prox cur_ttl want_prox want_ttl
          rec="$(jq -c --arg id "$id" '.result[] | select(.id == $id)' <<<"$resp")"
          name="$(jq -r '.name' <<<"$rec")"
          cur_prox="$(jq -r 'if .proxied==null then "false" else (.proxied|tostring) end' <<<"$rec")"
          cur_ttl="$(jq -r '.ttl|tostring' <<<"$rec")"
          want_prox="${prox:-$cur_prox}"
          want_ttl="${ttl:-$cur_ttl}"
          patch_simple "$zid" "$id" "$type" "$name" "$desired" "$want_prox" "$want_ttl"
        done <<<"$to_update_ids"

        log "Bulk ${type} update complete: changed=${changed_planned} skipped=${skipped} target=${desired}"
      fi
      ;;
    CNAME)
      (( $# >= 2 && ($# % 2 == 0) )) || { err "update CNAME: NAME TARGET [NAME TARGET ...]"; exit 2; }
      while (( $# )); do
        local name="$1"; shift; local target="$1"; shift
        local fq rec id cur_prox cur_ttl cur_content
        fq="$(fqdn_of "$name" "$zone")"; rec="$(get_dns_record "$zid" CNAME "$fq")"
        [[ -n "$rec" ]] || { err "update CNAME: $fq not found"; continue; }
        id="$(jq -r '.id' <<<"$rec")"
        cur_prox="$(jq -r 'if .proxied==null then "false" else (.proxied|tostring) end' <<<"$rec")"
        cur_ttl="$(jq -r '.ttl // empty' <<<"$rec")"
        cur_content="$(jq -r '.content // empty' <<<"$rec")"
        local want_prox="${prox:-$cur_prox}"
        local want_ttl="${ttl:-$cur_ttl}"
        if [[ "$cur_content" == "$target" && "$cur_prox" == "$want_prox" && "$cur_ttl" == "$want_ttl" ]]; then
          log "No change: CNAME ${fq} already ${target} (proxied=${cur_prox} ttl=${cur_ttl})"
          continue
        fi
        patch_simple "$zid" "$id" "CNAME" "$fq" "$target" "$want_prox" "$want_ttl"
      done
      ;;
    TXT)
      (( $# >= 2 && ($# % 2 == 0) )) || { err "update TXT: NAME VALUE [NAME VALUE ...]"; exit 2; }
      while (( $# )); do
        local name="$1"; shift; local val="$1"; shift
        local fq rec id cur_ttl cur_content
        fq="$(fqdn_of "$name" "$zone")"; rec="$(get_dns_record "$zid" TXT "$fq")"
        [[ -n "$rec" ]] || { err "update TXT: $fq not found"; continue; }
        id="$(jq -r '.id' <<<"$rec")"
        cur_ttl="$(jq -r '.ttl // empty' <<<"$rec")"
        cur_content="$(jq -r '.content // empty' <<<"$rec")"
        local want_ttl="${ttl:-$cur_ttl}"
        if [[ "$cur_content" == "$val" && "$cur_ttl" == "$want_ttl" ]]; then
          log "No change: TXT ${fq} already has desired value"
          continue
        fi
        patch_simple "$zid" "$id" "TXT" "$fq" "$val" "false" "$want_ttl"
      done
      ;;
    MX)
      (( $# >= 2 && ($# % 2 == 0) )) || { err "update MX: NAME EXCHANGE [NAME EXCHANGE ...]"; exit 2; }
      local pr="${prio:-$MX_PRIORITY_DEFAULT}"
      while (( $# )); do
        local name="$1"; shift; local exch="$1"; shift
        local fq rec id cur_ttl cur_content cur_prio
        fq="$(fqdn_of "$name" "$zone")"; rec="$(get_dns_record "$zid" MX "$fq")"
        [[ -n "$rec" ]] || { err "update MX: $fq not found"; continue; }
        id="$(jq -r '.id' <<<"$rec")"
        cur_ttl="$(jq -r '.ttl // empty' <<<"$rec")"
        cur_content="$(jq -r '.content // empty' <<<"$rec")"
        cur_prio="$(jq -r '.priority // empty' <<<"$rec")"
        local want_ttl="${ttl:-$cur_ttl}"
        local want_prio="$pr"
        if [[ "$cur_content" == "$exch" && "$cur_prio" == "$want_prio" && "$cur_ttl" == "$want_ttl" ]]; then
          log "No change: MX ${fq} already ${exch} (priority=${cur_prio} ttl=${cur_ttl})"
          continue
        fi
        patch_simple "$zid" "$id" "MX" "$fq" "$exch" "false" "$want_ttl" "$want_prio"
      done
      ;;
    NS)
      (( $# >= 2 && ($# % 2 == 0) )) || { err "update NS: NAME HOST [NAME HOST ...]"; exit 2; }
      while (( $# )); do
        local name="$1"; shift; local host="$1"; shift
        local fq rec id cur_ttl cur_content
        fq="$(fqdn_of "$name" "$zone")"; rec="$(get_dns_record "$zid" NS "$fq")"
        [[ -n "$rec" ]] || { err "update NS: $fq not found"; continue; }
        id="$(jq -r '.id' <<<"$rec")"
        cur_ttl="$(jq -r '.ttl // empty' <<<"$rec")"
        cur_content="$(jq -r '.content // empty' <<<"$rec")"
        local want_ttl="${ttl:-$cur_ttl}"
        if [[ "$cur_content" == "$host" && "$cur_ttl" == "$want_ttl" ]]; then
          log "No change: NS ${fq} already ${host} (ttl=${cur_ttl})"
          continue
        fi
        patch_simple "$zid" "$id" "NS" "$fq" "$host" "false" "$want_ttl"
      done
      ;;
    SRV)
      [[ -n "$srv_service" && -n "$srv_proto" && -n "$srv_target" ]] || { err "update SRV: require --service, --proto, --target"; exit 2; }
      local pr="${srv_priority:-$SRV_PRIORITY_DEFAULT}" we="${srv_weight:-$SRV_WEIGHT_DEFAULT}" po="${srv_port:-$SRV_PORT_DEFAULT}"
      (( $# >= 1 )) || { err "update SRV: specify at least one NAME"; exit 2; }
      for n in "$@"; do
        local fq rec id cur_ttl ds_service ds_proto ds_target ds_prio ds_weight ds_port
        fq="$(fqdn_of "$n" "$zone")"; rec="$(get_dns_record "$zid" SRV "$fq")"
        [[ -n "$rec" ]] || { err "update SRV: $fq not found"; continue; }
        id="$(jq -r '.id' <<<"$rec")"
        cur_ttl="$(jq -r '.ttl // empty' <<<"$rec")"
        ds_service="$(jq -r '.data.service // empty' <<<"$rec")"
        ds_proto="$(jq -r '.data.proto // empty' <<<"$rec")"
        ds_target="$(jq -r '.data.target // empty' <<<"$rec")"
        ds_prio="$(jq -r '.data.priority // empty' <<<"$rec")"
        ds_weight="$(jq -r '.data.weight // empty' <<<"$rec")"
        ds_port="$(jq -r '.data.port // empty' <<<"$rec")"
        local want_ttl="${ttl:-$cur_ttl}"
        if [[ "$ds_service" == "$srv_service" && "$ds_proto" == "$srv_proto" && "$ds_target" == "$srv_target" && "$ds_prio" == "$pr" && "$ds_weight" == "$we" && "$ds_port" == "$po" && "$cur_ttl" == "$want_ttl" ]]; then
          log "No change: SRV ${srv_service}.${srv_proto}.${fq} already target=${srv_target} prio=${pr} weight=${we} port=${po} (ttl=${cur_ttl})"
          continue
        fi
        patch_srv "$zid" "$id" "$fq" "$srv_service" "$srv_proto" "$srv_target" "$pr" "$we" "$po" "$want_ttl"
      done
      ;;
    CAA)
      [[ -n "$caa_tag" && -n "$caa_value" ]] || { err "update CAA: require --caa-tag and --caa-value"; exit 2; }
      local fl="${caa_flag:-$CAA_FLAG_DEFAULT}"
      (( $# >= 1 )) || { err "update CAA: specify at least one NAME"; exit 2; }
      for n in "$@"; do
        local fq rec id cur_ttl ds_flags ds_tag ds_value
        fq="$(fqdn_of "$n" "$zone")"; rec="$(get_dns_record "$zid" CAA "$fq")"
        [[ -n "$rec" ]] || { err "update CAA: $fq not found"; continue; }
        id="$(jq -r '.id' <<<"$rec")"
        cur_ttl="$(jq -r '.ttl // empty' <<<"$rec")"
        ds_flags="$(jq -r '.data.flags // empty' <<<"$rec")"
        ds_tag="$(jq -r '.data.tag // empty' <<<"$rec")"
        ds_value="$(jq -r '.data.value // empty' <<<"$rec")"
        local want_ttl="${ttl:-$cur_ttl}"
        if [[ "$ds_flags" == "$fl" && "$ds_tag" == "$caa_tag" && "$ds_value" == "$caa_value" && "$cur_ttl" == "$want_ttl" ]]; then
          log "No change: CAA ${fq} already ${fl} ${caa_tag} ${caa_value} (ttl=${cur_ttl})"
          continue
        fi
        patch_caa "$zid" "$id" "$fq" "$fl" "$caa_tag" "$caa_value" "$want_ttl"
      done
      ;;
    *) err "Unsupported TYPE for update: $type"; exit 2 ;;
  esac
}

cmd_remove(){
  local type="$1" zone="$2" force="$3"
  shift 3 || true
  (( $# )) || { err "remove: specify at least one NAME"; exit 2; }
  local zid; zid="$(get_zone_id "$zone")"; [[ -n "$zid" ]] || { err "Zone not found: $zone"; exit 1; }
  for n in "$@"; do
    local fq rec id; fq="$(fqdn_of "$n" "$zone")"; rec="$(get_dns_record "$zid" "$type" "$fq")"
    if [[ -n "$rec" ]]; then
      id="$(jq -r '.id' <<<"$rec")"
      if [[ "$force" != "true" ]]; then read -r -p "Remove ${type} ${fq}? [y/N] " ans; [[ "$ans" =~ ^[Yy]$ ]] || { echo "Skipped ${fq}."; continue; }; fi
      delete_record "$zid" "$id" "${type} ${fq}"
    else
      err "remove: ${fq} not found (${type})"
    fi
  done
}

########################################
#       ARG PARSER / DISPATCH          #
########################################
main(){
  local sub="${1:-}"; shift || true
  [[ -z "${sub:-}" || "$sub" == "-h" || "$sub" == "--help" ]] && { usage; exit 0; }

  local zone="$ZONE_NAME" type="" ttl="" prox="" force="false"
  local ip="" ip6="" priority="" srv_service="" srv_proto="" srv_target="" srv_priority="" srv_weight="" srv_port=""
  local caa_flag="" caa_tag="" caa_value=""

  while (( $# )); do
    case "$1" in
      -z|--zone)    zone="$2"; shift 2 ;;
      --type)       type="$2"; shift 2 ;;
      --ttl)        ttl="$2"; shift 2 ;;
      --proxied)    prox="$2"; shift 2 ;;
      --force)      force="true"; shift ;;
      --ip)         ip="$2"; shift 2 ;;
      --ip6)        ip6="$2"; shift 2 ;;
      --priority)   priority="$2"; shift 2 ;;
      --service)    srv_service="$2"; shift 2 ;;
      --proto)      srv_proto="$2"; shift 2 ;;
      --target)     srv_target="$2"; shift 2 ;;
      --srv-priority) srv_priority="$2"; shift 2 ;;
      --weight)     srv_weight="$2"; shift 2 ;;
      --port)       srv_port="$2"; shift 2 ;;
      --caa-flag)   caa_flag="$2"; shift 2 ;;
      --caa-tag)    caa_tag="$2"; shift 2 ;;
      --caa-value)  caa_value="$2"; shift 2 ;;
      --)           shift; break ;;
      -h|--help)    usage; exit 0 ;;
      -*)           err "Unknown option: $1"; usage; exit 2 ;;
      *)            break ;;
    esac
  done

  case "${prox:-}" in true|false|"") ;; *) err "--proxied must be true or false"; exit 2 ;; esac
  if [[ -n "${ttl:-}" && ! "$ttl" =~ ^[0-9]+$ ]]; then err "--ttl must be integer seconds"; exit 2; fi
  for n in priority srv_priority srv_weight srv_port caa_flag; do
    v="${!n:-}"; [[ -z "$v" || "$v" =~ ^[0-9]+$ ]] || { err "--$n must be an integer"; exit 2; }
  done

  local ttlv="${ttl:-$TTL_DEFAULT}"
  local proxv="${prox:-$PROXIED_DEFAULT}"
  local mxprio="${priority:-$MX_PRIORITY_DEFAULT}"
  local srvprio="${srv_priority:-$SRV_PRIORITY_DEFAULT}"
  local srvw="${srv_weight:-$SRV_WEIGHT_DEFAULT}"
  local srvp="${srv_port:-$SRV_PORT_DEFAULT}"

  case "$sub" in
    list)   cmd_list "$zone" "$type" ;;
    add)    [[ -n "$type" ]] || { err "add: --type TYPE is required"; exit 2; }
            cmd_add "$type" "$zone" "$ttlv" "$proxv" "$ip" "$ip6" "$mxprio" "$srv_service" "$srv_proto" "$srv_target" "$srvprio" "$srvw" "$srvp" "$caa_flag" "$caa_tag" "$caa_value" "$@" ;;
    update) [[ -n "$type" ]] || { err "update: --type TYPE is required"; exit 2; }
            cmd_update "$type" "$zone" "$ttlv" "$prox" "$ip" "$ip6" "$mxprio" "$srv_service" "$srv_proto" "$srv_target" "$srvprio" "$srvw" "$srvp" "$caa_flag" "$caa_tag" "$caa_value" "$@" ;;
    remove) [[ -n "$type" ]] || { err "remove: --type TYPE is required"; exit 2; }
            cmd_remove "$type" "$zone" "$force" "$@" ;;
    *)      err "Unknown subcommand: $sub"; usage; exit 2 ;;
  esac
}

main "$@"
