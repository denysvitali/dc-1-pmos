# dc1-backend

The DC-1 UI's control plane: one static Go binary that the Flutter shell talks
to over a Unix domain socket. Onboarding only — the installer's download,
verify and write path stays shell (`installer/src/`).

## Build (canonical)

```sh
cd ui/backend
GOOS=linux GOARCH=arm64 CGO_ENABLED=0 \
    go build -trimpath -ldflags "-s -w" -o dc1-backend ./cmd/dc1-backend
```

`CGO_ENABLED=0` is required: the result must be a static, musl-safe binary
with no `INTERP` and no dynamic section.

## Checks

```sh
cd ui/backend
gofmt -l .            # must print nothing
CGO_ENABLED=0 go build ./...
CGO_ENABLED=0 go vet ./...
CGO_ENABLED=0 go test ./...
```

No test shells out to a real `nmcli` or `cryptpw`, and none touches `/etc`:
every external command goes through `internal/cmdrunner.Runner`, which the
tests replace with a fake, and every filesystem write is rooted at a
`t.TempDir()`.

## Run

```sh
dc1-backend [-socket /run/dc1-ui.sock] [-root /]
```

`-root` exists for tests; production is `/`. A stale socket left by a crashed
instance is removed at start-up; a socket that is still being served is not
stolen. The socket is created mode 0600.

## API

All endpoints are on the Unix socket. **The backend never binds TCP** — the
USB host (172.16.42.1) and any joined Wi-Fi network must not reach onboarding;
a test asserts both the listener type and the absence of any TCP bind in the
module.

| Method | Path | Body | Reply |
| --- | --- | --- | --- |
| `GET` | `/status` | — | `{"provisioned":bool}` |
| `GET` | `/wifi/scan` | — | `[{"ssid":"…","signal":72}, …]`, strongest first |
| `POST` | `/wifi/connect` | `{"ssid","psk"}` | `{"status":"connected","ssid":"…"}` |
| `POST` | `/onboard` | `{"user","password","hostname","timezone"[,"ssid","psk"]}` | `{"status":"provisioned"\|"already-provisioned",…}` |
| `POST` | `/finish` | — | `{"status":"rebooting"}`; 409 until provisioned |
| `GET` | `/events` | — | NDJSON stream: `{"ts","state","detail"}` per line |

Errors are `{"error":"…"}` with a 4xx/5xx status and never quote a credential.
`/events` opens with the current state (`IDLE` if nothing has happened yet) so
a UI that attaches late is not left blank; states reuse the installer's
uppercase vocabulary (`internal/events`).

## Secrets

- The password reaches `cryptpw -m sha512 -P 0` on **stdin**, never on an
  argv, exactly as `installer/src/tui.sh:71-75` does it.
- The Wi-Fi passphrase never reaches an argv either. `/wifi/connect` writes the
  same mode-0600 NetworkManager keyfile that `installer/src/provision.sh`
  writes, at the same fixed path
  (`/etc/NetworkManager/system-connections/wifi.nmconnection`), then runs
  `nmcli connection reload` + `nmcli connection up uuid <uuid>`.
  `nmcli device wifi connect SSID password PSK` is rejected: it puts the
  passphrase on an argv *and* would create a second profile competing with the
  one provision.sh writes.
- Credentials live in `secret.Secret` (`[]byte`), are zeroed after use, and
  cannot be formatted or marshalled: they render as `[redacted]`.

## Onboarding rules

Mirrored from `installer/src/tui.sh` (see `internal/validate`). All length caps
here are **byte** caps, which is *not* what the shell counts: busybox ash's
`${#var}` is locale-dependent and, measured on Alpine's busybox 1.37.0-r14,
counts **codepoints** under a UTF-8 locale (musl's default with `LANG`/`LC_ALL`
unset) and bytes only under `LC_ALL=C`. Bytes are counted here because bytes
are what consumes these values — 802.11 gives an SSID 32 octets, NetworkManager
measures the WPA passphrase in bytes, `/etc/passwd` and `/etc/hostname` are
byte-oriented. For the ASCII-only charsets below (username, hostname, timezone)
the counts coincide, so every layer agrees; for the unrestricted SSID and PSK,
counting bytes is the stricter rule and can only reject what the shell would
have taken.

- username: not `root`/`nobody`; `[a-z_]` or `[a-z_][a-z0-9_-]*`; ≤32
- hostname: no trailing `-`; `[a-z0-9]` or `[a-z0-9][a-z0-9-]*`; ≤63
- timezone: non-empty, no `..`, no leading/trailing `/`, `[A-Za-z0-9_+/-]`
  only, and the zoneinfo file must exist
- SSID ≤32 and no newline; PSK 8..63; both set or both empty

Applying repeats `provision.sh`'s steps (user rename/create, `/etc/hostname` +
`/etc/hosts`, relative `/etc/localtime` symlink, NetworkManager keyfile) and is
gated by the marker `/var/lib/dc1-installer/provisioned` (0644): if it exists,
`/onboard` reports `already-provisioned` and changes nothing. Without that gate
a second submission would *rename* the first user rather than create a new one
(`installer/src/provision.sh:168-187`).
