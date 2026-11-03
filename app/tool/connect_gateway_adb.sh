#!/bin/sh
# Development convenience only. The gateway runtime never depends on ADB.
set -eu

usage() {
  printf '%s\n' 'Usage: connect_gateway_adb.sh [HOST:PORT] [--usb SERIAL] [--enable]' \
    'Default: SIM_BRIDGE_GATEWAY_ADB or app/tool/.gateway-adb (one HOST:PORT line).' \
    'Without a local default, supply HOST:PORT. Example LAN address: 192.168.1.100:5555.' \
    '--usb discovers that USB phone WLAN address.' \
    '--enable explicitly enables USB adb tcpip 5555 before connecting.'
}

address=''
usb_serial=''
enable=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --usb)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      usb_serial=$2; shift 2 ;;
    --enable) enable=true; shift ;;
    --help|-h) usage; exit 0 ;;
    --*) usage >&2; exit 2 ;;
    *) [ -z "$address" ] || { usage >&2; exit 2; }; address=$1; shift ;;
  esac
done
command -v adb >/dev/null 2>&1 || { printf '%s\n' 'adb is not installed.' >&2; exit 1; }

if [ "$enable" = true ] && [ -z "$usb_serial" ]; then
  usb_serial=$(adb devices | awk 'NR > 1 && $2 == "device" && $1 !~ /:/ { print $1 }')
  case "$usb_serial" in
    ''|*'
'*) printf '%s\n' 'Choose one connected USB phone with --usb SERIAL.' >&2; exit 2 ;;
  esac
fi

if [ -n "$usb_serial" ]; then
  case "$usb_serial" in -*|*' '*|*'
'*) printf '%s\n' 'Invalid USB serial.' >&2; exit 2 ;; esac
  adb -s "$usb_serial" get-state | awk '$0 == "device" { ok = 1 } END { exit !ok }' || {
    printf '%s\n' 'USB phone is unavailable or unauthorized.' >&2; exit 1;
  }
  if [ -z "$address" ]; then
    wlan=$(adb -s "$usb_serial" shell ip -4 addr show wlan0 | awk '$1 == "inet" { split($2, p, "/"); print p[1]; exit }')
    [ -n "$wlan" ] || { printf '%s\n' 'USB phone has no wlan0 IPv4 address.' >&2; exit 1; }
    address="$wlan:5555"
  fi
fi
if [ -z "$address" ]; then
  if [ -n "${SIM_BRIDGE_GATEWAY_ADB:-}" ]; then
    address=$SIM_BRIDGE_GATEWAY_ADB
  else
    script_dir=$(CDPATH= cd "$(dirname "$0")" && pwd)
    local_config="$script_dir/.gateway-adb"
    if [ ! -f "$local_config" ]; then
      printf '%s\n' 'Supply HOST:PORT, --usb SERIAL, or a local gateway default.' >&2
      usage >&2
      exit 2
    fi
    awk 'NR != 1 { exit 1 } END { if (NR != 1) exit 1 }' "$local_config" || {
      printf '%s\n' 'Local gateway config must contain exactly one HOST:PORT line.' >&2
      exit 2
    }
    address=$(cat "$local_config")
  fi
fi
# Accept an IPv4 LAN address and a numeric TCP port only; never pass arbitrary
# user input through to an adb transport selector or shell invocation.
printf '%s\n' "$address" | awk -F: '
  NR != 1 { exit 1 }
  NF != 2 || $2 !~ /^[0-9]+$/ || $2 < 1 || $2 > 65535 { exit 1 }
  { n = split($1, a, "."); if (n != 4) exit 1;
    for (i = 1; i <= n; i++) if (a[i] !~ /^[0-9]+$/ || a[i] > 255) exit 1;
    if (!(a[1] == 10 || (a[1] == 192 && a[2] == 168) || (a[1] == 172 && a[2] >= 16 && a[2] <= 31))) exit 1;
  }' || { printf '%s\n' 'Use a private LAN IPv4 address and port, such as 192.168.1.100:5555 (example only).' >&2; exit 2; }

if [ "$enable" = true ]; then
  case "$address" in *:5555) ;; *) printf '%s\n' '--enable uses TCP port 5555.' >&2; exit 2 ;; esac
  adb -s "$usb_serial" tcpip 5555
fi
# Enabling tcpip restarts adbd, so the listener can take a moment to return.
# Retry only during this explicit invocation; no persistent polling is created.
attempt=1
ready=false
while [ "$attempt" -le 5 ]; do
  adb connect "$address" || true
  if adb -s "$address" get-state 2>/dev/null | awk '$0 == "device" { ok = 1 } END { exit !ok }'; then
    ready=true
    break
  fi
  [ "$attempt" -lt 5 ] && sleep 2
  attempt=$((attempt + 1))
done
if [ "$ready" != true ]; then
  printf '%s\n' 'Wi-Fi ADB is not ready after five attempts. Check the LAN connection and phone authorization.' >&2
  exit 1
fi
printf 'Wi-Fi ADB ready: %s\n' "$address"
