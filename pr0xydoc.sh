#!/usr/bin/env bash
# pr0xydoc — diagnose your own proxy chain, one hop at a time.
# https://github.com/M4DXPL01T/pr0xydoc
# MIT License

set -uo pipefail

VERSION="0.4.0"
CONFIG="${XRAY_CONFIG:-}"
CHAIN_CONF="${PR0XYDOC_CONF:-$HOME/.config/pr0xydoc/chain.conf}"
VIA_LIST=()
QUIET=0
KIND=""
SOCKS_PORT=""
SERVER_ADDR=""
SERVER_PORT=""
NETWORK=""
SECURITY=""
IS_UDP=0
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

  -c, --config PATH    client config (xray/v2ray json, hysteria2 yaml, tuic json)
      --via USER@HOST  check the next hop over SSH; repeat for longer chains,
                       in order, from the nearest server outward
      --init           write a starter chain config and exit
  -q, --quiet          no banner
  -h, --help           this help

Examples:
  pr0xydoc.sh
  pr0xydoc.sh --via root@bridge.example
  pr0xydoc.sh --via root@bridge.example --via root@exit.example

Hops after the first are reached through the ones before them, so only the
first server needs to be reachable from where you are sitting.

Everything on the remote side is read-only: pr0xydoc reads status and logs,
it never restarts a service or edits a file. When something needs changing,
it prints the command and leaves it to you.
EOF
  exit 0
}

write_init() {
  mkdir -p "$(dirname "$CHAIN_CONF")"
  [ -e "$CHAIN_CONF" ] && { echo "already exists: $CHAIN_CONF"; exit 1; }
  cat > "$CHAIN_CONF" <<'EOF'
# pr0xydoc chain config
# Only needed if you want to check hops beyond the first one.

# SSH targets, nearest first. One per hop you want checked.
# Anything ssh understands works, including Host aliases from ~/.ssh/config.
VIA="root@bridge.example"
# VIA2="root@exit.example"
# VIA3=""

# Where a hop's own config lives, if it is not in a standard path.
REMOTE_CONFIG=""
EOF
  echo "written: $CHAIN_CONF"
  exit 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    -c|--config) CONFIG="${2:-}"; shift 2 ;;
    --via)       VIA_LIST+=("${2:-}"); shift 2 ;;
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
VIA=""; VIA2=""; VIA3=""
if [ -r "$CHAIN_CONF" ]; then
  # shellcheck disable=SC1090
  . "$CHAIN_CONF"
  if [ ${#VIA_LIST[@]} -eq 0 ]; then
    [ -n "$VIA" ]  && VIA_LIST+=("$VIA")
    [ -n "$VIA2" ] && VIA_LIST+=("$VIA2")
    [ -n "$VIA3" ] && VIA_LIST+=("$VIA3")
  fi
fi

# --- ssh ------------------------------------------------------------------
SSH_BASE=(-o ControlMaster=auto -o ControlPersist=120 -o ConnectTimeout=12 -o BatchMode=no)

# ssh to hop index $1 (0-based), tunnelling through every hop before it
rsh_at() {
  local idx=$1; shift
  local target="${VIA_LIST[$idx]}"
  local -a opts=("${SSH_BASE[@]}" -o "ControlPath=/tmp/pr0xydoc-$$-$idx")
  if [ "$idx" -gt 0 ]; then
    local prev=$((idx-1))
    opts+=(-o "ProxyCommand=ssh -o ControlPath=/tmp/pr0xydoc-$$-$prev -W %h:%p ${VIA_LIST[$prev]}")
  fi
  ssh "${opts[@]}" "$target" "$@" 2>/dev/null
}

cleanup() {
  local i
  for ((i=0; i<${#VIA_LIST[@]}; i++)); do
    ssh -o "ControlPath=/tmp/pr0xydoc-$$-$i" -O exit "${VIA_LIST[$i]}" 2>/dev/null
  done
}
trap cleanup EXIT

# --- helpers --------------------------------------------------------------
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

udp_probe() {
  python3 - "$1" "$2" <<'PY'
import socket, sys, os, time
host, port = sys.argv[1], int(sys.argv[2])
try:
    infos = socket.getaddrinfo(host, port, type=socket.SOCK_DGRAM)
except Exception:
    print("DNSFAIL 0"); sys.exit(0)
fam, _, _, _, addr = infos[0]
s = socket.socket(fam, socket.SOCK_DGRAM); s.settimeout(3.0)
pkt = bytes([0xC0]) + b"\x00\x00\x00\x01" + bytes([8]) + os.urandom(8) + bytes([0]) + os.urandom(16)
t0 = time.time()
try:
    s.sendto(pkt, addr); s.recvfrom(2048)
    print(f"REPLY {time.time()-t0:.2f}")
except socket.timeout:
    print("SILENT 3.00")
except OSError:
    print("REFUSED %.2f" % (time.time()-t0))
finally:
    s.close()
PY
}

direct_curl() {
  env -u http_proxy -u https_proxy -u all_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
      curl --noproxy '*' "$@"
}

PARSE_PY='
import json, sys, re
path = sys.argv[1]
raw = open(path, "r", errors="replace").read()
def out(kind, socks, addr, port, net, sec, udp):
    print(kind, socks or "-", addr or "-", port or "-", net or "-", sec or "-", udp)
    sys.exit(0)
try:
    d = json.loads(raw)
except Exception:
    d = None
if isinstance(d, dict):
    if "relay" in d and isinstance(d["relay"], dict):
        srv = str(d["relay"].get("server", ""))
        m = re.match(r"\[?([^\]]+)\]?:(\d+)$", srv)
        addr, port = (m.group(1), m.group(2)) if m else ("", "")
        loc = str(d.get("local", {}).get("server", ""))
        lm = re.search(r":(\d+)$", loc)
        out("tuic", lm.group(1) if lm else "", addr, port, "quic", "tls", 1)
    if "outbounds" in d or "inbounds" in d:
        socks = ""
        for i in d.get("inbounds", []):
            if i.get("protocol") in ("socks", "mixed", "http"):
                socks = str(i.get("port", "")); break
        addr = port = net = sec = ""
        for o in d.get("outbounds", []):
            if o.get("protocol") in ("freedom", "blackhole", "dns"):
                continue
            s = o.get("settings", {}) or {}
            v = s.get("vnext") or s.get("servers")
            if v and isinstance(v, list) and v:
                addr = v[0].get("address", "")
                port = str(v[0].get("port", ""))
                st = o.get("streamSettings", {}) or {}
                net = st.get("network", "tcp")
                sec = st.get("security", "none")
                break
        udp = 1 if net in ("quic", "kcp", "mkcp", "hysteria") else 0
        out("xray", socks, addr, port, net, sec, udp)
if re.search(r"^\s*server\s*:", raw, re.M):
    addr = port = ""
    m = re.search(r"^\s*server\s*:\s*[\"\x27]?([^\"\x27\s#]+)", raw, re.M)
    if m:
        srv = re.sub(r"^(hysteria2?|hy2)://", "", m.group(1)).split("/")[0]
        mm = re.match(r"\[?([^\]]+?)\]?:(\d+)$", srv)
        addr, port = (mm.group(1), mm.group(2)) if mm else (srv, "443")
    socks = ""
    sm = re.search(r"socks5\s*:\s*\n(?:\s+.*\n)*?\s+listen\s*:\s*[\"\x27]?[^:\s]*:(\d+)", raw, re.M)
    if sm: socks = sm.group(1)
    else:
        hm = re.search(r"http\s*:\s*\n(?:\s+.*\n)*?\s+listen\s*:\s*[\"\x27]?[^:\s]*:(\d+)", raw, re.M)
        if hm: socks = hm.group(1)
    if addr:
        out("hysteria2", socks, addr, port, "quic", "tls", 1)
print("ERR - - - - - 0")
'

find_config() {
  [ -n "$CONFIG" ] && return
  for p in /usr/local/etc/xray/config.json /etc/xray/config.json \
           /usr/local/etc/v2ray/config.json /etc/v2ray/config.json \
           "$HOME/.config/xray/config.json" \
           /etc/hysteria/config.yaml /etc/hysteria/client.yaml \
           "$HOME/.config/hysteria/config.yaml" \
           /etc/tuic/config.json "$HOME/.config/tuic/config.json" \
           ./config.json ./config.yaml; do
    [ -r "$p" ] && { CONFIG="$p"; return; }
  done
}

# --- run ------------------------------------------------------------------
[ "$QUIET" -eq 0 ] && banner

step "1. Client configuration"
find_config
if [ -z "$CONFIG" ]; then
  bad "no client config found"
  fix "pr0xydoc.sh -c /path/to/config.json"
  exit 1
fi
ok "config: $CONFIG"
read -r KIND SOCKS_PORT SERVER_ADDR SERVER_PORT NETWORK SECURITY IS_UDP \
  <<<"$(python3 -c "$PARSE_PY" "$CONFIG")"
if [ "$KIND" = "ERR" ] || [ "$SERVER_ADDR" = "-" ]; then
  bad "could not read a server out of this config"
  hint "supported: xray/v2ray json, hysteria2 yaml, tuic json"
  exit 1
fi
info "client:    $KIND"
info "first hop: $SERVER_ADDR:$SERVER_PORT  ($NETWORK / $SECURITY)"
[ "$SOCKS_PORT" != "-" ] && info "local proxy: 127.0.0.1:$SOCKS_PORT"

step "2. Local client"
RUNNING=0
for proc in xray v2ray hysteria hysteria-linux-amd64 tuic-client sing-box; do
  pgrep -x "$proc" >/dev/null 2>&1 && { ok "process '$proc' is running"; RUNNING=1; break; }
done
if [ "$RUNNING" -eq 0 ] && command -v systemctl >/dev/null 2>&1; then
  for svc in xray v2ray hysteria-client tuic sing-box; do
    systemctl is-active --quiet "$svc" 2>/dev/null && { ok "service '$svc' is running"; RUNNING=1; break; }
  done
fi
[ "$RUNNING" -eq 0 ] && { bad "no running proxy client found"; fix "sudo systemctl start xray"; }
if [ "$SOCKS_PORT" != "-" ]; then
  if ss -ltn 2>/dev/null | grep -q ":$SOCKS_PORT " || netstat -ltn 2>/dev/null | grep -q ":$SOCKS_PORT "; then
    ok "local port $SOCKS_PORT is listening"
  else
    bad "local port $SOCKS_PORT is not listening"
    fix "journalctl -u xray -n 50 --no-pager"
  fi
fi

step "3. Reaching the first hop"
if [ "$IS_UDP" = "1" ]; then
  info "this transport runs over UDP, so there is no handshake to time"
  read -r res rtt <<<"$(udp_probe "$SERVER_ADDR" "$SERVER_PORT")"
  case "$res" in
    REPLY)   ok "$SERVER_ADDR:$SERVER_PORT answered a UDP probe in ${rtt}s" ;;
    REFUSED) bad "$SERVER_ADDR:$SERVER_PORT refused the packet"
             info "the host is up but nothing is listening on that UDP port" ;;
    DNSFAIL) bad "cannot resolve $SERVER_ADDR" ;;
    *)       warn "no answer from $SERVER_ADDR:$SERVER_PORT"
             info "UDP silence is ambiguous: open, filtered, or ignoring strangers"
             hint "most QUIC servers stay quiet for anything but a valid client" ;;
  esac
else
  t=$(tcp_check "$SERVER_ADDR" "$SERVER_PORT" 8)
  if [ "$t" = "FAIL" ]; then
    bad "$SERVER_ADDR:$SERVER_PORT is unreachable"
    info "the server is down, the port is closed, or the address is blocked"
    hint "try the same port from another network to tell those apart"
  elif [ "$(gt "$t" 3)" = "1" ]; then
    warn "connected, but it took ${t}s"
    info "slow handshakes point at packet loss on the path"
  else
    ok "connected in ${t}s"
  fi
fi

step "4. Tunnel"
TUNNEL_IP=""
if [ "$SOCKS_PORT" = "-" ]; then
  info "no local socks/http listener in the config, skipping"
  [ "$KIND" = "hysteria2" ] && hint "in tun mode there is no socks port — check your IP in a browser instead"
else
  PROXY="socks5h://127.0.0.1:$SOCKS_PORT"
  TUNNEL_IP=$(curl -s -x "$PROXY" --max-time 25 https://ifconfig.me 2>/dev/null \
            || curl -s -x "$PROXY" --max-time 25 https://api.ipify.org 2>/dev/null)
  if [ -n "$TUNNEL_IP" ]; then
    ok "tunnel is up, exit address: $TUNNEL_IP"
    if [ "$TUNNEL_IP" != "$SERVER_ADDR" ]; then
      info "the first hop forwards your traffic further on"
      [ ${#VIA_LIST[@]} -eq 0 ] && hint "check that next hop too:  pr0xydoc.sh --via user@$SERVER_ADDR"
    else
      info "traffic exits at the server you connect to"
    fi
  else
    bad "tunnel does not carry traffic"
    info "the first hop answers, but the session never completes"
    hint "wrong credentials, a blocked protocol, or a broken hop behind it"
    [ "$IS_UDP" = "1" ] && hint "some networks drop UDP wholesale — a TCP-based setup would tell you"
    [ ${#VIA_LIST[@]} -eq 0 ] && hint "to see past the first hop:  pr0xydoc.sh --via user@$SERVER_ADDR"
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
FAILED_HOSTS=()
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
    FAILED_HOSTS+=("$host")
  fi
done
if [ "$BASELINE_OK" -eq 0 ]; then
  warn "every direct test failed — the limit is on your own link, not the proxy"
elif [ ${#FAILED_HOSTS[@]} -gt 0 ]; then
  NOTES+=("unreachable directly from this network: ${FAILED_HOSTS[*]} — worth knowing if your setup relies on one of them")
fi

# --- remote hops ----------------------------------------------------------
if [ ${#VIA_LIST[@]} -gt 0 ]; then
  for ((i=0; i<${#VIA_LIST[@]}; i++)); do
    hop="${VIA_LIST[$i]}"
    n=$((i+7))
    if [ "$i" -eq 0 ]; then
      step "$n. Hop 1 — $hop"
    else
      step "$n. Hop $((i+1)) — $hop  (reached through hop $i)"
    fi
    info "read-only: reading status and logs, changing nothing"
    if ! rsh_at "$i" true; then
      bad "cannot reach $hop over SSH"
      [ "$i" -gt 0 ] && info "the jump goes through the earlier hops, so one of them may be the problem"
      hint "check the address, the user, and your key or password"
      break
    fi
    ok "SSH session established"

    RSVC=""
    for svc in xray v2ray hysteria-server sing-box tuic-server; do
      if rsh_at "$i" "systemctl is-active --quiet $svc" || rsh_at "$i" "pgrep -x $svc >/dev/null"; then
        RSVC="$svc"; break
      fi
    done
    if [ -n "$RSVC" ]; then
      ok "'$RSVC' is running here"
    else
      bad "no proxy server process found on $hop"
      fix "ssh $hop 'systemctl status xray --no-pager'"
    fi

    RCONF="$REMOTE_CONFIG"
    if [ -z "$RCONF" ]; then
      RCONF=$(rsh_at "$i" "for p in /usr/local/etc/xray/config.json /etc/xray/config.json /usr/local/x-ui/bin/config.json /etc/hysteria/config.yaml; do [ -r \$p ] && echo \$p && break; done")
    fi
    NEXT_ADDR=""; NEXT_PORT=""
    if [ -z "$RCONF" ]; then
      info "no config found in the usual places"
      hint "set REMOTE_CONFIG in $CHAIN_CONF if it lives elsewhere"
    else
      info "config: $RCONF"
      rout=$(rsh_at "$i" "python3 -c '$(echo "$PARSE_PY" | sed "s/'/'\\\\''/g")' $RCONF" 2>/dev/null)
      read -r rkind rsocks raddr rport rnet rsec rudp <<<"${rout:-ERR - - - - - 0}"
      if [ "$rkind" != "ERR" ] && [ "$raddr" != "-" ]; then
        NEXT_ADDR="$raddr"; NEXT_PORT="$rport"
        info "forwards to: $raddr:$rport  ($rnet / $rsec)"
        if [ "$rudp" = "1" ]; then
          info "that link is UDP-based; a remote probe would be inconclusive, skipping"
        else
          rt=$(rsh_at "$i" "timeout 8 bash -c 'exec 3<>/dev/tcp/$raddr/$rport' && echo OPEN || echo FAIL")
          if [ "$rt" = "OPEN" ]; then
            ok "this hop can reach $raddr:$rport"
          else
            bad "this hop cannot reach $raddr:$rport"
            info "the break in your chain is right here"
            hint "the next server is down, or its address is blocked from this network"
          fi
        fi
      else
        info "no onward proxy outbound here — this is the exit"
      fi
    fi

    errs=$(rsh_at "$i" "journalctl --since '10 min ago' --no-pager -u xray -u hysteria-server -u sing-box 2>/dev/null | grep -icE 'error|failed|refused|timeout'")
    if [ -n "$errs" ] && [ "$errs" -gt 10 ] 2>/dev/null; then
      warn "$errs error lines in the log here (last 10 min)"
      fix "ssh $hop \"journalctl -u xray --since '10 min ago' --no-pager | grep -iE 'error|failed'\""
    else
      ok "log looks normal (${errs:-0} error lines in 10 min)"
    fi

    rspeed=$(rsh_at "$i" "curl -o /dev/null --max-time 25 -s -w '%{size_download}' https://speed.cloudflare.com/__down?bytes=10000000")
    if [ -n "$rspeed" ] && [ "$rspeed" -ge 1000000 ] 2>/dev/null; then
      ok "this hop has working outbound internet"
    else
      warn "this hop struggles to download directly (${rspeed:-0} bytes)"
      info "its own uplink is limited, which caps everything behind it"
    fi

    # suggest going one further, if there is a next hop and we have no target for it
    if [ -n "$NEXT_ADDR" ] && [ $((i+1)) -ge ${#VIA_LIST[@]} ]; then
      hint "to continue past this hop, add:  --via user@$NEXT_ADDR"
    fi
  done
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
[ ${#VIA_LIST[@]} -gt 0 ] && echo "  a hop cannot reach the next → that is where the chain breaks"
[ "$IS_UDP" = "1" ] && { echo; echo "On UDP transports step 3 is a hint, not a verdict. Step 4 is what counts."; }
