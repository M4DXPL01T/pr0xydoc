# pr0xydoc

Find out which part of your proxy setup is broken, without guessing.

When a self-hosted tunnel stops working, the symptom is always the same:
nothing loads. The cause is not. The server may be down, its address may be
blocked, the handshake may fail, or the traffic may be throttled a few
kilobytes in. And if you run a chain — one server forwarding to another — the
break can be anywhere along it.

`pr0xydoc` walks the chain hop by hop and tells you where it gave out.

```
                  ___                   _
      ____  _____/ _ \__  ____  ______ _| |___   ___
     / __ \/ ___/ / / / |/_/ / / / __ `/ / __ \ / __|
    / /_/ / /  / /_/ />  </ /_/ / /_/ / / /_/ // /__
   / .___/_/   \____/_/|_|\__, /\__,_/_/\____/ \___|
  /_/                    /____/   d o c t o r
```

## Quick start

```sh
curl -O https://raw.githubusercontent.com/M4DXPL01T/pr0xydoc/main/pr0xydoc.sh
chmod +x pr0xydoc.sh
./pr0xydoc.sh
```

No setup. It finds your client config, reads the addresses out of it, and
starts checking. Needs `bash`, `curl` and `python3`.

Run it on the machine that holds the config: a desktop, a VPS, or a phone
through Termux. macOS and WSL work too; the service check is skipped where
there is no `systemd`.

## Example

```
1. Client configuration
[ OK ] config: /usr/local/etc/xray/config.json
       client:    xray
       first hop: 203.0.113.10:443  (tcp / reality)
       local proxy: 127.0.0.1:10808

2. Local client
[ OK ] process 'xray' is running
[ OK ] local port 10808 is listening

3. Reaching the first hop
[ OK ] connected in 0.05s

4. Tunnel
[ OK ] tunnel is up, exit address: 198.51.100.7
       the first hop forwards your traffic further on

5. Throughput through the tunnel
[ OK ] downloaded 50000000 bytes in 4.6s (10.4 MB/s)

6. Your plain connection (for comparison)
[ OK ] direct download works: 16053216 bytes in 0.4s (via mirror.yandex.ru)

Summary
Everything checks out.
```

## Chains

If your client connects to one server that forwards to another, step 4 says
so: the exit address differs from the one you dial. That alone narrows things
down — when step 3 passes and step 4 fails, the near end is fine and something
further out is not.

To check those hops too, name them in order:

```sh
./pr0xydoc.sh --via root@bridge.example
./pr0xydoc.sh --via root@bridge.example --via root@exit.example
```

```
7. Hop 1 — root@bridge.example
[ OK ] SSH session established
[ OK ] 'xray' is running here
       forwards to: 198.51.100.7:7332  (tcp / reality)
[ OK ] this hop can reach 198.51.100.7:7332
[ OK ] log looks normal (3 error lines in 10 min)
[ OK ] this hop has working outbound internet

8. Hop 2 — root@exit.example  (reached through hop 1)
[ OK ] SSH session established
[ OK ] 'xray' is running here
       no onward proxy outbound here — this is the exit
```

Each hop is reached **through the ones before it**, so only the first server
has to be reachable from where you are sitting. If your exit server is blocked
from your own network — which is often exactly why the bridge exists — pr0xydoc
still gets there.

Anything `ssh` understands works, including `Host` aliases from your
`~/.ssh/config`. With keys you are asked for nothing; with passwords, once per
hop.

For a chain you check often, write it down once:

```sh
./pr0xydoc.sh --init      # creates ~/.config/pr0xydoc/chain.conf
```

```sh
VIA="root@bridge.example"
VIA2="root@exit.example"
```

After that, plain `./pr0xydoc.sh` walks the whole chain.

## It suggests, you decide

pr0xydoc never restarts a service, never edits a config, and never writes
anything on a remote host. When something needs doing, it prints the command
and stops:

```
Suggested commands (run them yourself, then re-run pr0xydoc):
  $ sudo systemctl start xray
```

You run it, you re-run pr0xydoc, and the step that failed should now pass. A
diagnostic tool that changes things behind your back is a tool you cannot trust
while you are already debugging.

## What each step means

| Step | Checks | A failure means |
|------|--------|-----------------|
| 1 | the client config parses, and what it points at | the config is missing or malformed |
| 2 | the client runs and its local port listens | the client crashed or never started |
| 3 | the first hop answers on its address and port | it is down, the port is closed, or the address is blocked |
| 4 | a request actually travels through the tunnel | wrong credentials, the protocol is being cut, or a hop behind it is broken |
| 5 | 50 MB moves through without stalling | the session holds but transfers die — often throttling |
| 6 | the same download without the proxy | if this fails too, your own link is limited |
| 7+ | each further hop, over SSH | the chain breaks at the hop that cannot reach the next |

Two patterns are worth naming, because both look like "it's just slow":

**Handshakes taking seconds instead of milliseconds** (step 3) point at packet
loss along the path rather than an outright block. The connection opens, but
retransmissions eat the time.

**Transfers stopping near 16 KB** (step 5) are not a coincidence. Some networks
let a connection open and then cut it once a little data has moved, which
leaves small requests working and everything else broken.

## Protocols

Step 3 checks that the server answers, step 4 checks whether a request survives
the tunnel, step 5 checks whether bulk traffic survives it. None of that
depends on which protocol you run.

| Client | Read from | Notes |
|--------|-----------|-------|
| xray / v2ray | `config.json` | VLESS, VMess, Trojan, Shadowsocks over TCP, WS, gRPC, XHTTP, Reality |
| hysteria2 | `config.yaml` | QUIC/UDP |
| tuic | `config.json` | QUIC/UDP |

On UDP transports step 3 sends a QUIC-shaped probe instead of opening a
connection. Treat the result as a hint rather than a verdict: a QUIC server
that stays silent for a stranger looks exactly like a filtered port. Step 4 is
what settles it.

## Scope

pr0xydoc reads addresses from your own config and tests that chain. It takes no
target as an argument, scans no ranges, and probes no port you have not already
configured yourself. Without a config there is nothing for it to check.

It is a diagnostic tool for infrastructure you run. Please keep it that way.

## License

MIT
