# pr0xydoc

Find out which part of your proxy setup is broken, without guessing.

When a self-hosted xray/v2ray tunnel stops working, the symptom is always the
same: nothing loads. The cause is not. The server may be down, its address may
be blocked, the handshake may fail, or the traffic may be throttled a few
kilobytes in. `pr0xydoc` walks the chain one layer at a time and tells you
which layer gave out.

```
                  ___                   _
      ____  _____/ _ \__  ____  ______ _| |___   ___
     / __ \/ ___/ / / / |/_/ / / / __ `/ / __ \ / __|
    / /_/ / /  / /_/ />  </ /_/ / /_/ / / /_/ // /__
   / .___/_/   \____/_/|_|\__, /\__,_/_/\____/ \___|
  /_/                    /____/   d o c t o r
```

## Example

```
1. Client configuration
[ OK ] config: /usr/local/etc/xray/config.json
       server:    203.0.113.10:443
       transport: tcp / reality
       local proxy: 127.0.0.1:10808

2. Local client
[ OK ] xray service is running
[ OK ] local port 10808 is listening

3. Reaching your server
[ OK ] connected in 0.05s

4. Tunnel
[ OK ] tunnel is up, exit address: 198.51.100.7
       traffic exits elsewhere — your server forwards it further on

5. Throughput through the tunnel
[ OK ] downloaded 50000000 bytes in 5.1s (9.4 MB/s)

6. Your plain connection (for comparison)
[ OK ] direct download works: 16078403 bytes in 0.4s (via mirror.yandex.ru)

Summary
Everything checks out.
```

## Install

```sh
curl -O https://raw.githubusercontent.com/M4DXPL01T/pr0xydoc/main/pr0xydoc.sh
chmod +x pr0xydoc.sh
./pr0xydoc.sh
```

Needs `bash`, `curl` and `python3` — all present on a normal Linux install.
Run it on the machine that holds your client config: a desktop, a VPS, or a
phone through Termux. macOS and WSL work too; the service check is skipped
where there is no `systemd`.

If your config lives somewhere unusual:

```sh
./pr0xydoc.sh -c /path/to/config.json
```

## What each step means

| Step | Checks | A failure means |
|------|--------|-----------------|
| 1 | the client config parses, and what it points at | the config is missing or malformed |
| 2 | the client runs and its local port listens | the client crashed or never started |
| 3 | TCP reaches your server's address and port | the server is down, the port is closed, or the address is blocked |
| 4 | a request actually travels through the tunnel | wrong credentials, the protocol is being cut, or a hop behind your server is broken |
| 5 | 50 MB moves through without stalling | the session holds but transfers die — often throttling |
| 6 | the same download without the proxy | if this fails too, your own link is limited, not the proxy |

Step 3 taking several seconds instead of milliseconds is worth noting on its
own: slow handshakes point at packet loss along the path rather than an
outright block.

Step 5 stopping near 16 KB is a specific pattern, not a coincidence. Some
networks allow a connection to open and then cut it once a little data has
moved, which leaves small requests working and everything else broken.

## Multi-hop setups

If your client connects to one server that forwards traffic to another, step 4
tells you the exit address differs from the one you dial. That already narrows
things down: when step 3 passes and step 4 fails, the near end is fine and the
far hop is the suspect.

What `pr0xydoc` does not do is log into that far hop for you. Checking it means
running the same tests from the middle server over SSH — planned, not built.

## Scope

`pr0xydoc` reads addresses from your own client config and tests that chain.
It takes no target as an argument, scans no ranges, and probes no port you have
not already configured yourself. Without a config there is nothing for it to
check.

It is a diagnostic tool for infrastructure you run. Please keep it that way.

## License

MIT
