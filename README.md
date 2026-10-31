# pr0xydoc

Find out which part of your proxy setup is broken, without guessing.

When a self-hosted xray/v2ray tunnel stops working, the symptom is always the
same: nothing loads. The cause is not. The server may be down, its address may
be blocked, the handshake may fail, or the traffic may be throttled a few
kilobytes in. And if you run a chain — a nearby server forwarding to a distant
one — the break can be at either end.

`pr0xydoc` walks the chain one hop at a time and tells you which hop gave out.

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
       first hop: 203.0.113.10:443  (tcp / reality)
       local proxy: 127.0.0.1:10808

2. Local client
[ OK ] xray service is running
[ OK ] local port 10808 is listening

3. Reaching the first hop
[ OK ] connected in 0.05s

4. Tunnel
[ OK ] tunnel is up, exit address: 198.51.100.7
       the first hop forwards your traffic further on

5. Throughput through the tunnel
[ OK ] downloaded 50000000 bytes in 4.6s (10.3 MB/s)

6. Your plain connection (for comparison)
       no luck via speed.cloudflare.com (0 bytes)
[ OK ] direct download works: 16078403 bytes in 0.4s (via mirror.yandex.ru)

Summary
Everything checks out.

note: Cloudflare is unreachable directly from this network — setups that hide
      behind Cloudflare will struggle here.
```

That last note is the kind of thing worth knowing before you spend an evening
rebuilding a tunnel that was never going to work on this network.

## Chains

If your client connects to one server that forwards to another, step 4 says so:
the exit address differs from the one you dial. Step 3 passing while step 4
fails already means the near end is fine and the far hop is the suspect.

To check that far hop as well, point pr0xydoc at the middle server over SSH:

```sh
./pr0xydoc.sh --via user@203.0.113.10
```

```
7. Next hop (via user@203.0.113.10)
       read-only: reading status and logs, changing nothing
[ OK ] SSH session established
[ OK ] xray is running on the remote host
       remote config: /usr/local/etc/xray/config.json
       next hop from there: 198.51.100.7:7332  (tcp / reality)
[ OK ] the remote host can reach 198.51.100.7:7332
[ OK ] remote xray log looks normal (2 error lines in 10 min)
[ OK ] the remote host itself has working outbound internet
```

Anything `ssh` understands works here, including a `Host` alias from your
`~/.ssh/config`. With a key you are not asked for anything; with a password you
are asked once, since the session is reused for every check.

For a chain you check often, write it down once:

```sh
./pr0xydoc.sh --init      # creates ~/.config/pr0xydoc/chain.conf
```

```sh
VIA="user@203.0.113.10"
REMOTE_CONFIG=""          # only if the remote config is in an unusual path
```

After that, plain `./pr0xydoc.sh` checks the whole chain.

## It suggests, you decide

pr0xydoc never restarts a service, never edits a config, and never touches
anything on the remote side. When something needs doing, it prints the command
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
| 3 | TCP reaches the first hop | it is down, the port is closed, or the address is blocked |
| 4 | a request actually travels through the tunnel | wrong credentials, the protocol is being cut, or a hop behind it is broken |
| 5 | 50 MB moves through without stalling | the session holds but transfers die — often throttling |
| 6 | the same download without the proxy | if this fails too, your own link is limited |
| 7 | the next hop, over SSH | the break is beyond the first hop |

Two patterns are worth naming, because they look like "it's just slow":

**Handshakes taking seconds instead of milliseconds** (step 3) point at packet
loss along the path rather than an outright block. The connection opens, but
retransmissions eat the time.

**Transfers stopping near 16 KB** (step 5) are not a coincidence. Some networks
let a connection open and then cut it once a little data has moved, which
leaves small requests working and everything else broken.

## Protocols

Step 3 checks TCP, step 4 checks whether a request survives the tunnel, step 5
checks whether bulk traffic survives it. None of that depends on which protocol
you run, so VLESS, VMess, Trojan, Shadowsocks and Reality are all covered, over
TCP, WebSocket, gRPC or XHTTP. The config parser reads the standard xray/v2ray
layout, including `vnext` and `servers` style outbounds.

UDP-based transports (Hysteria, TUIC, QUIC) are a gap: step 3 would need a UDP
probe. Patches welcome.

## Scope

pr0xydoc reads addresses from your own client config and tests that chain. It
takes no target as an argument, scans no ranges, and probes no port you have
not already configured yourself. Without a config there is nothing for it to
check.

It is a diagnostic tool for infrastructure you run. Please keep it that way.

## License

MIT
