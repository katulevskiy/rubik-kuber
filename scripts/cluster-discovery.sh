#!/usr/bin/env bash
set -euo pipefail

DISCOVERY_SERVICE_TYPE="${DISCOVERY_SERVICE_TYPE:-_rubik-k8s._tcp}"
DISCOVERY_SERVICE_NAME="${DISCOVERY_SERVICE_NAME:-rubik-cluster}"
DISCOVERY_CLUSTER_NAME="${DISCOVERY_CLUSTER_NAME:-${DISCOVERY_SERVICE_NAME}}"
DISCOVERY_SERVER_PORT="${DISCOVERY_SERVER_PORT:-9345}"
DISCOVERY_VERSION="${DISCOVERY_VERSION:-1}"
DISCOVERY_AVAHI_SERVICE_PATH="${DISCOVERY_AVAHI_SERVICE_PATH:-/etc/avahi/services/rubik-cluster.service}"
DISCOVERY_AVAHI_DAEMON_CONFIG_PATH="${DISCOVERY_AVAHI_DAEMON_CONFIG_PATH:-/etc/avahi/avahi-daemon.conf}"
DISCOVERY_NSSWITCH_PATH="${DISCOVERY_NSSWITCH_PATH:-/etc/nsswitch.conf}"

detect_physical_interface() {
  local iface=""

  iface=$(ip route get 1.1.1.1 2>/dev/null | awk '
    / dev / {
      for (i = 1; i <= NF; i++) {
        if ($i == "dev") {
          print $(i + 1)
          exit
        }
      }
    }
  ')

  if [[ -z "${iface}" ]]; then
    iface=$(ip route show default 2>/dev/null | awk '
      / default / {
        for (i = 1; i <= NF; i++) {
          if ($i == "dev") {
            print $(i + 1)
            exit
          }
        }
      }
    ')
  fi

  printf '%s\n' "${iface}"
}

ensure_mdns_hosts_line() {
  local hosts_line="${1:-}"

  [[ -n "${hosts_line}" ]] || return 1

  if [[ "${hosts_line}" == *"mdns4_minimal [NOTFOUND=return]"* ]] || \
     [[ "${hosts_line}" == *"mdns_minimal [NOTFOUND=return]"* ]]; then
    printf '%s\n' "${hosts_line}"
    return 0
  fi

  python3 - "${hosts_line}" <<'PY'
import sys

line = sys.argv[1]
prefix, sep, rest = line.partition(":")
if not sep:
    raise SystemExit(1)

tokens = rest.strip().split()
insert = ["mdns4_minimal", "[NOTFOUND=return]"]

if not any(token.startswith("mdns") for token in tokens):
    if "dns" in tokens:
        idx = tokens.index("dns")
        tokens[idx:idx] = insert
    elif "resolve" in tokens:
        idx = tokens.index("resolve")
        tokens[idx:idx] = insert
    else:
        tokens.extend(insert)

print(f"{prefix}:{' ' if tokens else ''}{' '.join(tokens)}")
PY
}

ensure_local_mdns_resolution() {
  local config_path="${1:-${DISCOVERY_NSSWITCH_PATH}}"
  local tmp_file=""
  local found_hosts=false
  local line=""

  [[ -n "${config_path}" ]] || return 1

  mkdir -p "$(dirname "${config_path}")"
  tmp_file="$(mktemp "$(dirname "${config_path}")/nsswitch.conf.XXXXXX")"

  if [[ -f "${config_path}" ]]; then
    while IFS= read -r line || [[ -n "${line}" ]]; do
      if [[ "${line}" == hosts:* ]]; then
        ensure_mdns_hosts_line "${line}" >> "${tmp_file}"
        found_hosts=true
      else
        printf '%s\n' "${line}" >> "${tmp_file}"
      fi
    done < "${config_path}"
  fi

  if [[ "${found_hosts}" != true ]]; then
    ensure_mdns_hosts_line "hosts: files dns" >> "${tmp_file}"
  fi

  mv "${tmp_file}" "${config_path}"
}

advertise_mode() {
  local mode="${1:-}"
  local token="${2:-}"
  local short_hostname="${3:-}"
  local txt=(
    "cluster_name=${DISCOVERY_CLUSTER_NAME}"
    "mode=${mode}"
    "server_host=${short_hostname}.local"
    "server_port=${DISCOVERY_SERVER_PORT}"
    "version=${DISCOVERY_VERSION}"
  )

  [[ -n "${mode}" ]] || return 1
  [[ -n "${short_hostname}" ]] || return 1

  case "${mode}" in
    manual|open)
      ;;
    *)
      return 1
      ;;
  esac

  if [[ "${mode}" == "open" ]]; then
    [[ -n "${token}" ]] || return 1
    txt+=("token=${token}")
  fi

  printf '%s\n' "${txt[@]}"
}

discover_cluster_records() {
  command -v avahi-browse >/dev/null 2>&1 || return 1
  avahi-browse -rtkp "${DISCOVERY_SERVICE_TYPE}" 2>/dev/null
}

discovery_record_identity() {
  local record="${1:-}"
  local service_name=""
  local service_type=""
  local domain=""
  local server_host=""
  local server_port=""
  local txt_key=""

  [[ -n "${record}" ]] || return 1

  service_name="$(printf '%s\n' "${record}" | awk -F';' '$1 == "=" { print $4; exit }')"
  service_type="$(printf '%s\n' "${record}" | awk -F';' '$1 == "=" { print $5; exit }')"
  domain="$(printf '%s\n' "${record}" | awk -F';' '$1 == "=" { print $6; exit }')"
  server_host="$(printf '%s\n' "${record}" | awk -F';' '$1 == "=" { print $7; exit }')"
  server_port="$(printf '%s\n' "${record}" | awk -F';' '$1 == "=" { print $10; exit }')"
  txt_key="$(
    normalize_discovery_txt_entries "${record}" 2>/dev/null \
      | LC_ALL=C sort \
      | paste -sd'|' -
  )"

  [[ -n "${service_name}" && -n "${service_type}" && -n "${domain}" && -n "${server_host}" && -n "${server_port}" ]] || return 1
  printf '%s\n' "${service_name};${service_type};${domain};${server_host};${server_port};${txt_key}"
}

unique_discovery_records() {
  local records="${1:-}"
  local record=""
  local identity=""
  declare -A seen=()

  [[ -n "${records}" ]] || return 1

  while IFS= read -r record; do
    [[ -n "${record}" ]] || continue
    [[ "${record%%;*}" == "=" ]] || continue
    identity="$(discovery_record_identity "${record}" || true)"
    [[ -n "${identity}" ]] || continue
    if [[ -z "${seen[${identity}]+x}" ]]; then
      printf '%s\n' "${record}"
      seen["${identity}"]=1
    fi
  done <<< "${records}"
}

normalize_discovery_txt_entries() {
  local record="${1:-}"
  local txt_payload=""

  [[ -n "${record}" ]] || return 1

  txt_payload="$(printf '%s\n' "${record}" | awk -F';' '
    {
      for (i = 10; i <= NF; i++) {
        if (length($i) == 0) {
          continue
        }
        if (length(out)) {
          out = out ";" $i
        } else {
          out = $i
        }
      }
    }
    END {
      print out
    }
  ')"

  [[ -n "${txt_payload}" ]] || return 1
  printf '%s\n' "${txt_payload}" | awk '
    {
      line = $0
      found_quoted = 0

      while (match(line, /"[^"]*"/)) {
        field = substr(line, RSTART + 1, RLENGTH - 2)
        if (length(field)) {
          print field
        }
        line = substr(line, RSTART + RLENGTH)
        found_quoted = 1
      }

      if (found_quoted) {
        next
      }

      n = split($0, fields, ";")
      for (i = 1; i <= n; i++) {
        field = fields[i]
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", field)
        gsub(/^"/, "", field)
        gsub(/"$/, "", field)
        if (length(field)) {
          print field
        }
      }
    }
  '
}

extract_discovery_record_field() {
  local record="${1:-}"
  local field_name="${2:-}"

  [[ -n "${record}" && -n "${field_name}" ]] || return 1

  normalize_discovery_txt_entries "${record}" | awk -F'=' -v key="${field_name}" '
    $1 == key {
      value = substr($0, length(key) + 2)
      print value
      exit
    }
  '
}

discover_single_cluster() {
  local records unique_records resolved_count

  records="$(discover_cluster_records)"
  [[ -n "${records}" ]] || return 1

  unique_records="$(unique_discovery_records "${records}" || true)"
  [[ -n "${unique_records}" ]] || return 1

  resolved_count="$(printf '%s\n' "${unique_records}" | awk 'NF { count++ } END { print count + 0 }')"
  [[ "${resolved_count}" -eq 1 ]] || return 1

  printf '%s\n' "${unique_records}" | awk 'NF { print; exit }'
}

render_avahi_daemon_config() {
  local iface="${1:-}"

  [[ -n "${iface}" ]] || return 1

  printf '%s\n' '[server]'
  printf 'allow-interfaces=%s\n' "${iface}"
}

ensure_avahi_physical_interface_binding() {
  local config_path="${1:-${DISCOVERY_AVAHI_DAEMON_CONFIG_PATH}}"
  local iface="${2:-}"
  local tmp_file=""

  [[ -n "${config_path}" ]] || return 1

  if [[ -z "${iface}" ]]; then
    iface="$(detect_physical_interface)"
  fi
  [[ -n "${iface}" ]] || return 1

  mkdir -p "$(dirname "${config_path}")"

  if [[ ! -f "${config_path}" ]]; then
    render_avahi_daemon_config "${iface}" > "${config_path}"
    return 0
  fi

  tmp_file="$(mktemp "$(dirname "${config_path}")/avahi-daemon.conf.XXXXXX")"
  python3 - "${config_path}" "${iface}" > "${tmp_file}" <<'PY'
from pathlib import Path
import sys

config_path = Path(sys.argv[1])
iface = sys.argv[2]
lines = config_path.read_text().splitlines()

out = []
in_server = False
server_seen = False
allow_written = False

for line in lines:
    stripped = line.strip()
    if stripped.startswith("[") and stripped.endswith("]"):
        if in_server and not allow_written:
            out.append(f"allow-interfaces={iface}")
            allow_written = True
        in_server = stripped == "[server]"
        if in_server:
            server_seen = True
            allow_written = False
        out.append(line)
        continue

    if in_server and stripped.startswith("allow-interfaces="):
        if not allow_written:
            out.append(f"allow-interfaces={iface}")
            allow_written = True
        continue

    out.append(line)

if in_server and not allow_written:
    out.append(f"allow-interfaces={iface}")

if not server_seen:
    if out and out[-1] != "":
        out.append("")
    out.append("[server]")
    out.append(f"allow-interfaces={iface}")

print("\n".join(out) + "\n")
PY
  mv "${tmp_file}" "${config_path}"
}

xml_escape() {
  local value="${1:-}"
  value="${value//&/&amp;}"
  value="${value//</&lt;}"
  value="${value//>/&gt;}"
  printf '%s' "${value}"
}

render_advertisement_payload() {
  local mode="${1:-}"
  local token="${2:-}"
  local short_hostname="${3:-}"
  local txt_output=""
  local txt_records=()
  local record

  txt_output="$(advertise_mode "${mode}" "${token}" "${short_hostname}")" || return 1
  [[ -n "${txt_output}" ]] || return 1
  mapfile -t txt_records <<< "${txt_output}"

  printf '%s\n' '<?xml version="1.0" standalone="no"?>'
  printf '%s\n' '<!DOCTYPE service-group SYSTEM "avahi-service.dtd">'
  printf '%s\n' '<service-group>'
  printf '  <name replace-wildcards="yes">%s</name>\n' "$(xml_escape "${DISCOVERY_SERVICE_NAME}")"
  printf '%s\n' '  <service>'
  printf '    <type>%s</type>\n' "$(xml_escape "${DISCOVERY_SERVICE_TYPE}")"
  printf '    <port>%s</port>\n' "$(xml_escape "${DISCOVERY_SERVER_PORT}")"

  for record in "${txt_records[@]}"; do
    printf '    <txt-record>%s</txt-record>\n' "$(xml_escape "${record}")"
  done

  printf '%s\n' '  </service>'
  printf '%s\n' '</service-group>'
}

advertise_service() {
  local mode="${DISCOVERY_ADVERTISE_MODE:-manual}"
  local token="${DISCOVERY_ADVERTISE_TOKEN:-}"
  local short_hostname="${DISCOVERY_ADVERTISE_HOSTNAME:-$(hostname -s 2>/dev/null || hostname)}"
  local output_path="${DISCOVERY_AVAHI_SERVICE_PATH}"
  local output_dir tmp_output

  output_dir="$(dirname "${output_path}")"
  mkdir -p "${output_dir}"
  tmp_output="$(mktemp "${output_dir}/rubik-cluster.XXXXXX")"

  if ! render_advertisement_payload "${mode}" "${token}" "${short_hostname}" > "${tmp_output}"; then
    rm -f "${tmp_output}"
    return 1
  fi

  chmod 644 "${tmp_output}"
  mv "${tmp_output}" "${output_path}"
  printf '%s\n' "${output_path}"
}

main() {
  local command="${1:-}"

  case "${command}" in
    advertise-service)
      advertise_service
      ;;
    "")
      ;;
    *)
      printf 'Usage: %s advertise-service\n' "${0##*/}" >&2
      return 64
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
