# Piped-Backend (Sonare)

This is Sonare's fork of Piped's backend; the Sonare API (`sonare-backend`) is its only
client. Run it with `./installPiped.sh` once and `./runPiped.sh up`: the API listens on
127.0.0.1:8090 and piped-proxy on 127.0.0.1:8091. For a backend on another host, see
[Tailscale Funnel](#serving-a-backend-hosted-elsewhere-tailscale-funnel).

**[HOSTING.md](HOSTING.md)** is the step-by-step guide: first-time setup, start, stop and
update, publishing for Render, moving to another device, and troubleshooting.

## When YouTube breaks something

`./runPiped.sh check` runs `scripts/checkPiped.sh`, which searches for a song, opens an album, extracts
its streams and reads audio past the first megabyte. That covers the usual failures: extractor
changes (empty search or albums), bot detection (no audio-only formats, "not a bot" errors) and
stream URLs that 403 after ~1 MB.

- **Extractor:** `./runPiped.sh bump` moves NewPipeExtractor to the newest commit on its `dev`
  branch (or `./runPiped.sh bump <commit>`), rebuilds, checks, and rolls back to the backed-up
  image if the check fails. If `.env` pins `PIPED_EXTRACTOR_COMMIT` it updates that too, so
  the next `up` doesn't put the old one back. Commit `build.gradle` afterwards.
- **Bot detection:** `./runPiped.sh bump --bg-helper` does the same for the bg-helper image:
  pins its newest digest, checks, and restores the old pin on failure. Commit
  `docker-compose.yml` afterwards.

The first build of a new extractor commit waits on JitPack, which can fail the first time
while it compiles; run the bump again.

## Settings (.env)

`.env` (copied from `.env.example` by `./installPiped.sh`) holds the deploy settings.
`./runPiped.sh up` and `./installPiped.sh` copy them into the Piped files through
`scripts/syncEnvConfig.sh`; an empty value leaves the file as it is.

- `PIPED_PROXY_URL`: the piped-proxy base Piped rewrites media URLs to (`PROXY_PART` in
  `config.properties`). Change it when the proxy moves off localhost.
- `PIPED_EXTRACTOR_COMMIT`: the NewPipeExtractor commit in `build.gradle`; a new one rebuilds
  the image.
- `PIPED_KEY`, `COMPOSE_PROFILES`: for Tailscale Funnel, below. `./funnel.sh up` sets them.

## Serving a backend hosted elsewhere (Tailscale Funnel)

The production backend runs on Render, but Piped stays on this machine so YouTube sees a home
IP. `./funnel.sh` publishes it without opening a port or needing sudo:

```
Render backend --https--> <machine>.<tailnet>.ts.net       --Funnel--> gate :8092 --> piped
               --https--> <machine>.<tailnet>.ts.net:8443  --Funnel--> gate :8093 --> piped-proxy
```

1. `./funnel.sh install` (once): downloads Tailscale into `~/.local/share/sonare-tailscale`,
   runs `tailscaled` in userspace-networking mode as the user service
   `sonare-tailscaled.service`, and signs the machine in as `sonare-piped` (open the link it
   prints; a free Tailscale account is enough). For Funnel to stay up after you log out:
   `loginctl enable-linger $USER`.
2. `./funnel.sh up`: generates `PIPED_KEY`, sets `COMPOSE_PROFILES=funnel` (starts the `gate`
   container) and `PIPED_PROXY_URL=https://<machine>.<tailnet>.ts.net:8443`, restarts Piped, and
   turns Funnel on for both ports. The first time, Tailscale asks you to allow HTTPS and Funnel
   for the tailnet. It ends by checking each relay address from the internet side (403 without
   the key, 200 with it), and starts the `sonare-funnel-check` timer, below.
3. On the backend, set `PIPED_API_URL=https://<machine>.<tailnet>.ts.net` (and the admin page's
   Piped URL, if one is saved) and `PIPED_KEY` to the same value as here. The backend sends it as
   `X-Sonare-Key`, only to that host.

The gate (`gate/default.conf.template`, nginx) refuses any request without the key, and anything
but GET/HEAD; Funnel addresses show up in public certificate logs, so the key is what keeps
other people off your IP. Every web play is relayed by the backend from piped-proxy, so it uses
this machine's upload bandwidth. While Funnel is on, stream URLs point at the Funnel address; a
`sonare-backend` on this machine keeps `PIPED_API_URL=http://localhost:8090` and adds
`PIPED_LOCAL_PROXY_URL=http://localhost:8091`, so its relay fetches them locally. `./funnel.sh down` makes Piped local-only
again; `./funnel.sh status` shows where things stand.

### When one relay address goes dead

The Funnel name resolves to more than one Tailscale relay address, and each client uses
whichever one it gets. One can lose its link to this machine while the others work. Clients
sent there get ECONNRESET, which the backend reports as `UPSTREAM_UNAVAILABLE ... (ECONNRESET)`,
yet a check from here can still pass. Restarting `sonare-tailscaled` makes it reconnect to the
relays, which fixes it.

`./funnel.sh check` checks every address separately and restarts `sonare-tailscaled` if one
gets no answer while the gate answers locally. It retries a dead address for 30 s first and
restarts at most once every 30 minutes. `./funnel.sh up` installs the `sonare-funnel-check`
user timer, which runs it every 5 minutes (`journalctl --user -u sonare-funnel-check`).
`./funnel.sh down` removes it. `./funnel.sh status` lists each address's answers.

### On Windows

`.\funnel.ps1` takes the same commands as `funnel.sh`, with a few differences:

- `install` installs the regular Tailscale app with winget, which runs as a Windows service and
  puts the whole machine on the tailnet (Windows has no userspace mode). It signs in as
  `sonare-piped` with `--unattended`, so Funnel stays up after you sign out of Windows. A
  machine that is already signed in keeps its name, which then goes in `PIPED_API_URL`.
- Instead of the systemd timer, `up` registers the `sonare-funnel-check` scheduled task. It runs
  `.\funnel.ps1 check` every 5 minutes while you're signed in to Windows. It logs to
  `%LOCALAPPDATA%\sonare-tailscale\funnel-check.log`.
- Restarting the Tailscale service needs an elevated prompt, and the task isn't elevated. So
  `check` falls back to `tailscale down` and `tailscale up`, which should reconnect to the
  relays the same way. The Windows path hasn't been tried on a real Windows machine yet.
- `.\updatePiped.ps1` and `.\update.ps1 prod` go through `.\funnel.ps1 up` once Funnel is
  set up, like the `.sh` scripts.

## Moving Piped to another device

Any Linux machine with Docker (compose v2), systemd, curl, python3 and openssl works, on x86_64
or arm64. So does Windows 10/11 with Docker Desktop, using the `.ps1` scripts (see [On
Windows](#on-windows)). A Raspberry Pi 4/5 is enough: the stack runs in about 400 MB, but
building the Piped image wants 2 GB or more. It needs a home connection, not a VPS, because
YouTube blocks datacenter IPs. Every web play is relayed from it, so its upload speed matters.

1. On the old machine: `./funnel.sh down`, then remove the `sonare-piped` machine from the
   [Tailscale admin console](https://login.tailscale.com/admin/machines). Otherwise the new
   machine gets `sonare-piped-1` and a different address.
2. On the new machine: clone this repo and copy `.env` and `config.properties` from the old
   one. Keep the same `PIPED_KEY` and `PIPED_DB_PASSWORD` (the latter must still match
   `hibernate.connection.password`). `data/` doesn't need copying; Sonare keeps nothing in
   Piped's database.
3. `./installPiped.sh`, `./funnel.sh install` (sign in to the same Tailscale account), then
   `loginctl enable-linger $USER` so it keeps running after logout. Then run `./funnel.sh up`.
   On Windows: `.\installPiped.ps1`, `.\funnel.ps1 install`, `.\funnel.ps1 up`.
4. With the same name, tailnet and key, the Render backend needs no change. If the address or
   key changed, update `PIPED_API_URL` and `PIPED_KEY` in Render's environment, and the admin
   page's Piped URL if one is saved there (it overrides the environment).
5. A `sonare-backend` on the old machine now uses the Funnel too:
   `PIPED_API_URL=https://<machine>.<tailnet>.ts.net`, the same `PIPED_KEY`, and no
   `PIPED_LOCAL_PROXY_URL`.

## Database password

`docker-compose.yml` reads the Postgres password from `PIPED_DB_PASSWORD` and falls back to
`changeme`, which is only acceptable on a development machine. In production:

1. Set a strong `PIPED_DB_PASSWORD` in `.env` (docker compose reads it) before
   `./runPiped.sh up`.
2. Set `hibernate.connection.password` in `config.properties` to the same value.

Postgres only applies the password when it first creates `data/db`; to change it on an
existing database, also run `ALTER USER piped PASSWORD '…'` inside the postgres container.

## Licence

AGPL-3.0, like upstream Piped — see [LICENSE](LICENSE).

---

## Upstream Piped-Backend

An advanced open-source privacy friendly alternative to YouTube, crafted with the help of [NewPipeExtractor](https://github.com/TeamNewPipe/NewPipeExtractor).

## Official Frontend

- VueJS frontend - [Piped](https://github.com/TeamPiped/Piped)

## Community Projects

- See https://github.com/TeamPiped/Piped#made-with-piped
