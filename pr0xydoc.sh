#!/usr/bin/env bash
# pr0xydoc — diagnose your own xray/v2ray proxy chain, one hop at a time.
# https://github.com/M4DXPL01T/pr0xydoc
# MIT License

set -uo pipefail

VERSION="0.2.0"
CONFIG="${XRAY_CONFIG:-}"
CHAIN_CONF="${PR0XYDOC_CONF:-$HOME/.config/pr0xydoc/chain.conf}"
VIA=""
QUIET=0
SOCKS_PORT=""
SERVER_ADDR=""
SERVER_PORT=""
NETWORK=""
SECURITY=""
PROBLEMS=()
NOTES=()
ADVICE=()

# --- output ---------------------------------------------------------------
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
fix()  { printf "       %s$ %s%s\n" "$C" "$1" "$N"; ADVICE+=("$1"); }
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

  -c, --config PATH    your xray/v2ray client config
      --via USER@HOST  also check the next hop, over SSH
      --init           write a starter chain config and exit
  -q, --quiet          no banner
  -h, --help           this help

Chain config (optional, for a setup you check often):
  $CHAIN_CONF

Everything on the remote side is read-only: pr0xydoc reads status and logs,
it never restarts a service or edits a file. When something needs changing,
it prints the command and leaves it to you.
EOF
  exit 0
}

write_init() {
  mkdir -p "$(dirname "$CHAIN_CONF")"
  if [ -e "$CHAIN_CONF" ]; then
    echo "already exists: $CHAIN_CONF"; exit 1
  fi
  cat > "$CHAIN_CONF" <<'EOF'
# pr0xydoc chain config
# Only needed if you want to check hops beyond the first one.

# SSH target of the server your client connects to.
# Anything ssh understands works, including a Host alias from ~/.ssh/config.
VIA=""

# Where that server's own xray config lives, if it is not in a standard path.
REMOTE_CONFIG=""
EOF
  echo "written: $CHAIN_CONF"
  exit 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    -c|--config) CONFIG="${2:-}"; shift 2 ;;
    --via)       VIA="${2:-}"; shift 2 ;;
    --init)      write_init ;;
    -q|--quiet)  QUIET=1; shift ;;
    -h|--help)   usage ;;
    *) echo "unknown option: $1"; exit 1 ;;
  esac
done

for dep in curl python3; do
  command -v "$dep" >/dev/null 2>&1 || { echo "missing dependency: $dep"; exit 1; }
done

REMOTE_CONFIG=""
if [ -r "$CHAIN_CONF" ]; then
  # shellcheck disable=SC1090
  . "$CHAIN_CONF"
  [ -z "$VIA" ] && VIA="${VIA:-}"
fi

# --- helpers --------------------------------------------------------------
SSH_CTL="/tmp/pr0xydoc-ssh-$$"
SSH_OPTS=(-o ControlMaster=auto -o "ControlPath=$SSH_CTL" -o ControlPersist=120
          -o ConnectTimeout=10 -o BatchMode=no)
cleanup() {
  [ -n "$VIA" ] && ssh -o "ControlPath=$SSH_CTL" -O exit "$VIA" 2>/dev/null
}
trap cleanup EXIT

rsh() { ssh "${SSH_OPTS[@]}" "$VIA" "$@" 2>/dev/null; }

now_ms() { python3 -c 'import time;print(int(time.time()*1000))'; }
gt() { python3 -c "import sys;print(1 if float(sys.argv[1])>float(sys.argv[2]) else 0)" "$1" "$2"; }

tcp_check() {
  local h=$1 p=$2 t=${3:-8} s e
  s=$(now_ms)
  if timeout "$t" bash -c "exec 3<>/dev/tcp/$h/$p" 2>/dev/null; then
    e=$(now_ms); python3 -c "print(f'{($e-$s)/1000:.2f}')"
  else
    echo FAIL
  fi
}

direct_curl() {
  env -u http_proxy -u https_proxy -u all_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
      curl --noproxy '*' "$@"
}

PARSE_PY='
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    print("ERR - - - - -"); sys.exit(0)
socks = "-"
for i in d.get("inbounds", []):
    if i.get("protocol") in ("socks", "mixed", "http"):
        socks = str(i.get("port", "-")); break
addr = port = net = sec = "-"
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
'

find_config() {
  [ -n "$CONFIG" ] && return
  for p in /usr/local/etc/xray/config.json /etc/xray/config.json \
           /usr/local/etc/v2ray/config.json /etc/v2ray/config.json \
           "$HOME/.config/xray/config.json" ./config.json; do
    [ -r "$p" ] && { CONFIG="$p"; return; }
  done
}

# --- run ------------------------------------------------------------------
[ "$QUIET" -eq 0 ] && banner

step "1. Client configuration"
find_config
if [ -z "$CONFIG" ]; then
  bad "no xray/v2ray client config found"
  hint "pass it explicitly"
  fix "pr0xydoc.sh -c /path/to/config.json"
  exit 1
fi
ok "config: $CONFIG"
read -r st SOCKS_PORT SERVER_ADDR SERVER_PORT NETWORK SECURITY \
  <<<"$(python3 -c "$PARSE_PY" "$CONFIG")"
if [ "$st" != "OK" ] || [ "$SERVER_ADDR" = "-" ]; then
  bad "config unreadable, or it has no proxy outbound"
  exit 1
fi
info "first hop: $SERVER_ADDR:$SERVER_PORT  ($NETWORK / $SECURITY)"
[ "$SOCKS_PORT" != "-" ] && info "local proxy: 127.0.0.1:$SOCKS_PORT"

step "2. Local client"
if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet xray 2>/dev/null; then
  ok "xray service is running"
elif pgrep -x xray >/dev/null 2>&1 || pgrep -x v2ray >/dev/null 2>&1; then
  ok "client process is running"
else
  bad "no running xray/v2ray process"
  fix "sudo systemctl start xray"
fi
if [ "$SOCKS_PORT" != "-" ]; then
  if ss -ltn 2>/dev/null | grep -q ":$SOCKS_PORT " || netstat -ltn 2>/dev/null | grep -q ":$SOCKS_PORT "; then
    ok "local port $SOCKS_PORT is listening"
  else
    bad "local port $SOCKS_PORT is not listening"
    fix "journalctl -u xray -n 50 --no-pager"
  fi
fi

step "3. Reaching the first hop"
t=$(tcp_check "$SERVER_ADDR" "$SERVER_PORT" 8)
if [ "$t" = "FAIL" ]; then
  bad "$SERVER_ADDR:$SERVER_PORT is unreachable"
  info "the server is down, the port is closed, or the address is blocked"
  hint "try the same port from another network to tell those apart"
else
  if [ "$(gt "$t" 3)" = "1" ]; then
    warn "connected, but it took ${t}s"
    info "slow handshakes point at packet loss on the path"
  else
    ok "connected in ${t}s"
  fi
fi

step "4. Tunnel"
TUNNEL_IP=""
if [ "$SOCKS_PORT" = "-" ]; then
  info "no local socks/http inbound, skipping"
else
  PROXY="socks5h://127.0.0.1:$SOCKS_PORT"
  TUNNEL_IP=$(curl -s -x "$PROXY" --max-time 25 https://ifconfig.me 2>/dev/null \
            || curl -s -x "$PROXY" --max-time 25 https://api.ipify.org 2>/dev/null)
  if [ -n "$TUNNEL_IP" ]; then
    ok "tunnel is up, exit address: $TUNNEL_IP"
    if [ "$TUNNEL_IP" != "$SERVER_ADDR" ]; then
      info "the first hop forwards your traffic further on"
      [ -z "$VIA" ] && hint "check that next hop too:  pr0xydoc.sh --via user@$SERVER_ADDR"
    fi
  else
    bad "tunnel does not carry traffic"
    info "the first hop answers, but the session never completes"
    hint "wrong credentials, a blocked protocol, or a broken hop behind it"
    [ -z "$VIA" ] && hint "to see past the first hop:  pr0xydoc.sh --via user@$SERVER_ADDR"
  fi
fi

step "5. Throughput through the tunnel"
if [ -n "$TUNNEL_IP" ]; then
  r=$(curl -x "$PROXY" -o /dev/null --max-time 60 -s -w "%{size_download} %{time_total}" \
      "https://speed.cloudflare.com/__down?bytes=50000000" 2>/dev/null)
  sz=${r%% *}; tm=${r##* }; sz=${sz:-0}; tm=${tm:-0}
  if [ "$sz" -lt 1000000 ]; then
    bad "transfer stalled: ${sz} bytes in ${tm}s"
    if [ "$sz" -gt 8000 ] && [ "$sz" -lt 200000 ]; then
      info "stopping near 16 KB per connection is a known throttling pattern"
      hint "small payloads pass, real traffic dies — try another transport or entry point"
    fi
  else
    mb=$(python3 -c "print(f'{$sz/1048576/max($tm,0.001):.1f}')")
    ok "downloaded ${sz} bytes in ${tm}s (${mb} MB/s)"
    [ "$(gt 1 "$mb")" = "1" ] && warn "under 1 MB/s — the path is degraded"
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
  dsz=${d%% *}; dtm=${d##* }; dsz=${dsz:-0}
  host=$(echo "$url" | awk -F/ '{print $3}')
  if [ "$dsz" -ge 1000000 ]; then
    ok "direct download works: ${dsz} bytes in ${dtm}s (via $host)"
    BASELINE_OK=1; break
  else
    info "no luck via $host (${dsz} bytes)"
    [ "$host" = "speed.cloudflare.com" ] && \
      NOTES+=("Cloudflare is unreachable directly from this network — setups that hide behind Cloudflare will struggle here.")
  fi
done
[ "$BASELINE_OK" -eq 0 ] && warn "every direct test failed — the limit is on your own link, not the proxy"

# --- remote side ----------------------------------------------------------
if [ -n "$VIA" ]; then
  step "7. Next hop (via $VIA)"
  info "read-only: reading status and logs, changing nothing"
  if ! rsh true; then
    bad "cannot reach $VIA over SSH"
    hint "check the address, the user, and your key or password"
  else
    ok "SSH session established"

    if rsh "systemctl is-active --quiet xray" ; then
      ok "xray is running on the remote host"
    elif rsh "pgrep -x xray >/dev/null"; then
      ok "xray process found on the remote host"
    else
      bad "xray is not running on the remote host"
      fix "ssh $VIA 'systemctl status xray --no-pager'"
    fi

    RCONF="$REMOTE_CONFIG"
    if [ -z "$RCONF" ]; then
      RCONF=$(rsh "for p in /usr/local/etc/xray/config.json /etc/xray/config.json /usr/local/x-ui/bin/config.json; do [ -r \$p ] && echo \$p && break; done")
    fi
    if [ -z "$RCONF" ]; then
      info "no remote config found in the usual places"
      hint "set REMOTE_CONFIG in $CHAIN_CONF if it lives elsewhere"
    else
      info "remote config: $RCONF"
      rout=$(rsh "python3 -c '$(echo "$PARSE_PY" | sed "s/'/'\\\\''/g")' $RCONF" 2>/dev/null)
      read -r rst rsocks raddr rport rnet rsec <<<"${rout:-ERR - - - - -}"
      if [ "$rst" = "OK" ] && [ "$raddr" != "-" ]; then
        info "next hop from there: $raddr:$rport  ($rnet / $rsec)"
        rt=$(rsh "timeout 8 bash -c 'exec 3<>/dev/tcp/$raddr/$rport' && echo OPEN || echo FAIL")
        if [ "$rt" = "OPEN" ]; then
          ok "the remote host can reach $raddr:$rport"
        else
          bad "the remote host cannot reach $raddr:$rport"
          info "this is the broken link in your chain"
          hint "the far server is down, or its address is blocked from that network"
        fi
      else
        info "that host has no onward proxy outbound — it is the exit"
      fi
    fi

    errs=$(rsh "journalctl -u xray --since '10 min ago' --no-pager 2>/dev/null | grep -icE 'error|failed|refused|timeout'")
    if [ -n "$errs" ] && [ "$errs" -gt 10 ] 2>/dev/null; then
      warn "$errs error lines in the remote xray log (last 10 min)"
      fix "ssh $VIA \"journalctl -u xray --since '10 min ago' --no-pager | grep -iE 'error|failed'\""
    else
      ok "remote xray log looks normal ($errs error lines in 10 min)"
    fi

    rspeed=$(rsh "curl -o /dev/null --max-time 25 -s -w '%{size_download}' https://speed.cloudflare.com/__down?bytes=10000000")
    if [ -n "$rspeed" ] && [ "$rspeed" -ge 1000000 ] 2>/dev/null; then
      ok "the remote host itself has working outbound internet"
    else
      warn "the remote host struggles to download directly (${rspeed:-0} bytes)"
      info "its own uplink is limited, which caps everything behind it"
    fi
  fi
fi

# --- summary --------------------------------------------------------------
step "Summary"
if [ ${#PROBLEMS[@]} -eq 0 ]; then
  printf "%sEverything checks out.%s\n" "$G" "$N"
else
  printf "%s%d issue(s):%s\n" "$R" "${#PROBLEMS[@]}" "$N"
  for p in "${PROBLEMS[@]}"; do echo "  - $p"; done
fi
if [ ${#ADVICE[@]} -gt 0 ]; then
  echo
  echo "Suggested commands (run them yourself, then re-run pr0xydoc):"
  for a in "${ADVICE[@]}"; do echo "  $ $a"; done
fi
if [ ${#NOTES[@]} -gt 0 ]; then
  echo
  for n in "${NOTES[@]}"; do echo "note: $n"; done
fi
echo
echo "Reading the result:"
echo "  step 3 fails            → the first hop is gone or blocked"
echo "  step 3 ok, step 4 fails → it answers, but the session dies"
echo "  step 4 ok, step 5 bad   → traffic flows, then gets cut mid-transfer"
echo "  step 6 bad too          → your own link is limited, not the proxy"
[ -n "$VIA" ] && echo "  step 7 fails            → the break is beyond the first hop"
