#!/usr/bin/env bash
# pr0xydoc — diagnose your own xray/v2ray proxy chain, one layer at a time.
# https://github.com/M4DXPL01T/pr0xydoc
# MIT License

set -uo pipefail

VERSION="0.1.0"
CONFIG="${XRAY_CONFIG:-}"
SOCKS_PORT=""
SERVER_ADDR=""
SERVER_PORT=""
NETWORK=""
SECURITY=""
PROBLEMS=()
NOTES=()

# --- output helpers -------------------------------------------------------
if [ -t 1 ]; then
  R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; B=$'\033[1m'; C=$'\033[36m'; N=$'\033[0m'
else
  R=""; G=""; Y=""; B=""; C=""; N=""
fi

ok()   { printf "%s[ OK ]%s %s\n" "$G" "$N" "$1"; }
bad()  { printf "%s[FAIL]%s %s\n" "$R" "$N" "$1"; PROBLEMS+=("$1"); }
warn() { printf "%s[WARN]%s %s\n" "$Y" "$N" "$1"; PROBLEMS+=("$1"); }
info() { printf "       %s\n" "$1"; }
hint() { printf "       %s→ %s%s\n" "$C" "$1" "$N"; }
step() { printf "\n%s%s%s\n" "$B" "$1" "$N"; }

banner() {
cat <<'EOF'
                  ___                   _
      ____  _____/ _ \__  ____  ______ _| |___   ___
     / __ \/ ___/ / / / |/_/ / / / __ `/ / __ \ / __|
    / /_/ / /  / /_/ />  </ /_/ / /_/ / / /_/ // /__
   / .___/_/   \____/_/|_|\__, /\__,_/_/\____/ \___|
  /_/                    /____/   d o c t o r
EOF
printf "  %sproxy chain diagnostics  v%s%s\n\n" "$C" "$VERSION" "$N"
}

usage() {
  banner
  cat <<EOF
Usage: pr0xydoc.sh [options]

  -c, --config PATH   path to your xray/v2ray client config
  -q, --quiet         no banner
  -h, --help          this help

Environment:
  XRAY_CONFIG         same as --config

pr0xydoc reads the addresses from YOUR OWN client config and checks that
chain only. It does not scan arbitrary hosts.
EOF
  exit 0
}

QUIET=0
while [ $# -gt 0 ]; do
  case "$1" in
    -c|--config) CONFIG="${2:-}"; shift 2 ;;
    -q|--quiet)  QUIET=1; shift ;;
    -h|--help)   usage ;;
    *) echo "unknown option: $1"; exit 1 ;;
  esac
done

for dep in curl python3; do
  command -v "$dep" >/dev/null 2>&1 || { echo "missing dependency: $dep"; exit 1; }
done
HAVE_BC=0; command -v bc >/dev/null 2>&1 && HAVE_BC=1

# --- config ---------------------------------------------------------------
find_config() {
  [ -n "$CONFIG" ] && return
  for p in /usr/local/etc/xray/config.json \
           /etc/xray/config.json \
           /usr/local/etc/v2ray/config.json \
           /etc/v2ray/config.json \
           "$HOME/.config/xray/config.json" \
           "$HOME/.config/v2ray/config.json" \
           ./config.json; do
    [ -r "$p" ] && { CONFIG="$p"; return; }
  done
}

parse_config() {
  local out
  out=$(python3 - "$CONFIG" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print("ERR - - - - -"); sys.exit(0)

socks = "-"
for i in d.get("inbounds", []):
    if i.get("protocol") in ("socks", "mixed", "http"):
        socks = str(i.get("port", "-")); break

addr = port = "-"; net = sec = "-"
for o in d.get("outbounds", []):
    if o.get("protocol") in ("freedom", "blackhole", "dns"):
        continue
    s = o.get("settings", {})
    v = s.get("vnext") or s.get("servers")
    if v and isinstance(v, list) and v:
        addr = v[0].get("address", "-")
        port = str(v[0].get("port", "-"))
        st = o.get("streamSettings", {}) or {}
        net = st.get("network", "tcp")
        sec = st.get("security", "none")
        break

print("OK", socks, addr, port, net, sec)
PY
)
  read -r status SOCKS_PORT SERVER_ADDR SERVER_PORT NETWORK SECURITY <<<"$out"
  [ "$status" = "OK" ] && [ "$SERVER_ADDR" != "-" ]
}

now_ms() { python3 -c 'import time;print(int(time.time()*1000))'; }

tcp_check() {  # host port timeout -> seconds | FAIL
  local h=$1 p=$2 t=${3:-8} s e
  s=$(now_ms)
  if timeout "$t" bash -c "exec 3<>/dev/tcp/$h/$p" 2>/dev/null; then
    e=$(now_ms)
    python3 -c "print(f'{($e-$s)/1000:.2f}')"
  else
    echo FAIL
  fi
}

direct_curl() {  # curl that ignores any system proxy
  env -u http_proxy -u https_proxy -u all_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
      curl --noproxy '*' "$@"
}

gt() { python3 -c "import sys;print(1 if float(sys.argv[1])>float(sys.argv[2]) else 0)" "$1" "$2"; }

# --- run ------------------------------------------------------------------
[ "$QUIET" -eq 0 ] && banner

step "1. Client configuration"
find_config
if [ -z "$CONFIG" ]; then
  bad "no xray/v2ray client config found"
  hint "pass it explicitly:  pr0xydoc.sh -c /path/to/config.json"
  exit 1
fi
ok "config: $CONFIG"
if ! parse_config; then
  bad "config unreadable, or no proxy outbound in it"
  hint "this tool expects a CLIENT config with an outbound server"
  exit 1
fi
info "server:    $SERVER_ADDR:$SERVER_PORT"
info "transport: $NETWORK / $SECURITY"
[ "$SOCKS_PORT" != "-" ] && info "local proxy: 127.0.0.1:$SOCKS_PORT"

step "2. Local client"
if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet xray 2>/dev/null; then
  ok "xray service is running"
elif pgrep -x xray >/dev/null 2>&1 || pgrep -x v2ray >/dev/null 2>&1; then
  ok "client process is running"
else
  bad "no running xray/v2ray process"
  hint "start it:  sudo systemctl start xray"
fi

if [ "$SOCKS_PORT" != "-" ]; then
  if ss -ltn 2>/dev/null | grep -q ":$SOCKS_PORT " || netstat -ltn 2>/dev/null | grep -q ":$SOCKS_PORT "; then
    ok "local port $SOCKS_PORT is listening"
  else
    bad "local port $SOCKS_PORT is not listening"
    hint "check the client log:  journalctl -u xray -n 50"
  fi
fi

step "3. Reaching your server"
t=$(tcp_check "$SERVER_ADDR" "$SERVER_PORT" 8)
if [ "$t" = "FAIL" ]; then
  bad "$SERVER_ADDR:$SERVER_PORT is unreachable"
  info "the server is down, the port is closed, or the address is blocked"
  hint "try the same port from another network to tell them apart"
else
  if [ "$(gt "$t" 3)" = "1" ]; then
    warn "connected, but it took ${t}s"
    info "slow handshakes like this usually mean packet loss on the path"
  else
    ok "connected in ${t}s"
  fi
fi

step "4. Tunnel"
TUNNEL_IP=""
if [ "$SOCKS_PORT" = "-" ]; then
  info "no local socks/http inbound in the config, skipping"
else
  PROXY="socks5h://127.0.0.1:$SOCKS_PORT"
  TUNNEL_IP=$(curl -s -x "$PROXY" --max-time 25 https://ifconfig.me 2>/dev/null \
            || curl -s -x "$PROXY" --max-time 25 https://api.ipify.org 2>/dev/null)
  if [ -n "$TUNNEL_IP" ]; then
    ok "tunnel is up, exit address: $TUNNEL_IP"
    if [ "$TUNNEL_IP" = "$SERVER_ADDR" ]; then
      info "traffic exits at the server you connect to"
    else
      info "traffic exits elsewhere — your server forwards it further on"
    fi
  else
    bad "tunnel does not carry traffic"
    info "the server is reachable but the session never completes"
    hint "wrong key/uuid, blocked protocol, or a broken hop behind the server"
    hint "server side:  journalctl -u xray -n 50"
  fi
fi

step "5. Throughput through the tunnel"
if [ -n "$TUNNEL_IP" ]; then
  r=$(curl -x "$PROXY" -o /dev/null --max-time 60 -s \
      -w "%{size_download} %{time_total}" \
      "https://speed.cloudflare.com/__down?bytes=50000000" 2>/dev/null)
  sz=${r%% *}; tm=${r##* }
  sz=${sz:-0}; tm=${tm:-0}
  if [ "$sz" -lt 1000000 ]; then
    bad "transfer stalled: ${sz} bytes in ${tm}s"
    if [ "$sz" -gt 8000 ] && [ "$sz" -lt 200000 ]; then
      info "stopping near 16 KB per connection is a known throttling pattern"
      hint "small payloads pass, real traffic dies — try another transport or entry point"
    fi
  else
    mb=$(python3 -c "print(f'{$sz/1048576/max($tm,0.001):.1f}')")
    ok "downloaded ${sz} bytes in ${tm}s (${mb} MB/s)"
    [ "$(gt 1 "$mb")" = "1" ] && warn "throughput under 1 MB/s — the path is degraded"
  fi
else
  info "skipped: no working tunnel"
fi

step "6. Your plain connection (for comparison)"
BASELINE_OK=0
for url in "https://speed.cloudflare.com/__down?bytes=10000000" \
           "https://mirror.hetzner.com/debian/archive/ls-lR.gz" \
           "https://mirror.yandex.ru/debian/ls-lR.gz"; do
  d=$(direct_curl -o /dev/null --max-time 20 -s -w "%{size_download} %{time_total}" "$url" 2>/dev/null)
  dsz=${d%% *}; dtm=${d##* }
  dsz=${dsz:-0}
  host=$(echo "$url" | awk -F/ '{print $3}')
  if [ "$dsz" -ge 1000000 ]; then
    ok "direct download works: ${dsz} bytes in ${dtm}s (via $host)"
    BASELINE_OK=1
    break
  else
    info "no luck via $host (${dsz} bytes)"
    [ "$host" = "speed.cloudflare.com" ] && NOTES+=("Cloudflare is not reachable directly from this network — tunnels that hide behind Cloudflare will struggle here.")
  fi
done
[ "$BASELINE_OK" -eq 0 ] && warn "every direct test failed — the limitation is on your own link, not in the proxy"

step "Summary"
if [ ${#PROBLEMS[@]} -eq 0 ]; then
  printf "%sEverything checks out.%s\n" "$G" "$N"
else
  printf "%s%d issue(s):%s\n" "$R" "${#PROBLEMS[@]}" "$N"
  for p in "${PROBLEMS[@]}"; do echo "  - $p"; done
fi
if [ ${#NOTES[@]} -gt 0 ]; then
  echo
  for n in "${NOTES[@]}"; do echo "note: $n"; done
fi
echo
echo "Reading the result:"
echo "  step 3 fails            → the entry point itself is gone or blocked"
echo "  step 3 ok, step 4 fails → the entry point answers but the session dies"
echo "  step 4 ok, step 5 bad   → traffic flows but gets cut mid-transfer"
echo "  step 6 bad too          → your own link is limited, not the proxy"
