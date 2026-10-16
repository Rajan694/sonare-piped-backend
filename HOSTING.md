# Hosting Piped for Sonare

How to set up, run, publish, update and move this Piped backend. Linux commands come first;
Windows has the same scripts as `.ps1` (`.\runPiped.ps1 up` instead of `./runPiped.sh up`).
The rest of the details are in [README.md](README.md).

## What runs

| Container     | Port (127.0.0.1 only) | What it is                                                     |
| ------------- | --------------------- | -------------------------------------------------------------- |
| `piped`       | 8090                  | Piped's API, built from this repo (`sonare-piped:local`)       |
| `piped-proxy` | 8091                  | Media proxy: the audio the backend relays to listeners         |
| `bg-helper`   | internal              | PoTokens, without which YouTube gives no audio-only streams    |
| `postgres`    | internal              | Piped's own database (`data/db`; Sonare keeps nothing in it)   |
| `gate`        | 8092, 8093            | Only with Funnel: lets through requests that carry `PIPED_KEY` |

```
Render backend --https--> <machine>.<tailnet>.ts.net       --Funnel--> gate :8092 --> piped
               --https--> <machine>.<tailnet>.ts.net:8443  --Funnel--> gate :8093 --> piped-proxy
```

Without Funnel, Piped is reachable only from this machine. That's enough for a
`sonare-backend` running here. Funnel publishes it for a backend hosted elsewhere (Render).

## Requirements

- A machine on a **home internet connection**. YouTube blocks datacenter IPs, so a VPS or
  cloud VM won't work. All web playback is relayed from this machine, so upload speed matters.
- **Linux:** Docker with compose v2, systemd, git, curl, python3, openssl, and jq (for
  `./runPiped.sh check`). x86_64 or arm64. A Raspberry Pi 4/5 is fine.
- **Windows 10/11:** Docker Desktop, git, and PowerShell 5.1 or 7. winget installs Tailscale.
- RAM: the running stack uses about 400 MB. The first build (Gradle) wants 2 GB or more.
- For Funnel: a Tailscale account (the free plan is enough).

## 1. First-time setup

```bash
git clone https://github.com/Rajan694/sonare-piped-backend.git
cd sonare-piped-backend
./installPiped.sh        # creates .env and config.properties, pulls the images, builds Piped
./runPiped.sh up         # starts everything and waits until the API answers
./runPiped.sh check      # search, album, streams and audio: all should say "ok"
```

If you cloned the whole `sonare` repo, Piped is the `sonare-piped-backend` folder in it, and
`../install.sh piped` runs the install step.

The first build takes a few minutes. It downloads NewPipeExtractor from jitpack.io, which can
time out the first time while JitPack compiles it; run `./runPiped.sh up` again.

Settings live in `.env` (see `.env.example`). For anything other than a dev machine, set a
real database password before the first `up`:

- `PIPED_DB_PASSWORD` in `.env`
- the same value as `hibernate.connection.password` in `config.properties`

## 2. Running it day to day

| What                           | Linux                  | Windows                 |
| ------------------------------ | ---------------------- | ----------------------- |
| Start, or apply `.env` changes | `./runPiped.sh up`     | `.\runPiped.ps1 up`     |
| Stop                           | `./runPiped.sh down`   | `.\runPiped.ps1 down`   |
| Is it healthy?                 | `./runPiped.sh status` | `.\runPiped.ps1 status` |
| Follow the logs                | `./runPiped.sh logs`   | `.\runPiped.ps1 logs`   |
| Does YouTube still work?       | `./runPiped.sh check`  | `.\runPiped.ps1 check`  |

- `up` rebuilds the image only when the Piped source changed. Otherwise it starts the existing
  image.
- If the image is missing (pruned, say), `up` restores the last good build from
  `image-backup/` without needing the network.
- Containers restart on their own after a reboot (`restart: unless-stopped`), as long as Docker
  starts at boot. On Windows, turn on "Start Docker Desktop when you sign in".
- Funnel's gate is part of the stack once Funnel is set up (`COMPOSE_PROFILES=funnel` in
  `.env`). So `./runPiped.sh down` and `up` stop and start it too. Tailscale keeps the Funnel
  configured in between; it just has nothing to forward to.
- Running the whole app on one machine for development: `../run.sh all` starts Piped, the
  backend and the web app. `../run.sh piped` starts only Piped.

## 3. Publishing it for Render (Tailscale Funnel)

Once per machine:

```bash
./funnel.sh install               # Windows: .\funnel.ps1 install
loginctl enable-linger "$USER"    # Linux: keep it running after you log out
```

On Linux, `install` downloads Tailscale into `~/.local/share/sonare-tailscale`. It runs it as
the user service `sonare-tailscaled` (no sudo, and it doesn't affect the rest of the machine).
Then it signs the machine in as `sonare-piped`; open the link it prints. On Windows it installs
the Tailscale app with winget instead.

Then turn it on, off, or check it:

```bash
./funnel.sh up        # publish (safe to run again any time)
./funnel.sh status    # Tailscale, Funnel, gate, timer, and every relay address's answer
./funnel.sh check     # check every relay address; restart Tailscale if one is dead
./funnel.sh down      # stop publishing; Piped stays up, local only
```

`up` does the following:

1. Generates `PIPED_KEY` in `.env` if there isn't one.
2. Points Piped's media URLs at `https://<machine>.<tailnet>.ts.net:8443`.
3. Starts the gate.
4. Turns Funnel on for ports 443 and 8443.
5. Checks every relay address from the internet side.
6. Installs a check that runs every 5 minutes: the `sonare-funnel-check` systemd timer, or a
   scheduled task on Windows.

It ends by printing what the backend needs.

The first time, Tailscale may refuse Funnel until it's allowed for the tailnet. Open the link
it prints, or the [DNS](https://login.tailscale.com/admin/dns) and
[ACL](https://login.tailscale.com/admin/acls) pages, then run `up` again.

### What the backend needs

| Backend                               | Settings                                                                                   |
| ------------------------------------- | ------------------------------------------------------------------------------------------ |
| On Render (production)                | `PIPED_API_URL=https://<machine>.<tailnet>.ts.net`, `PIPED_KEY=<same as this .env>`        |
| On this machine, Funnel on            | `PIPED_API_URL=http://localhost:8090`, `PIPED_LOCAL_PROXY_URL=http://localhost:8091`       |
| On this machine, Funnel off           | `PIPED_API_URL=http://localhost:8090` (nothing else)                                       |
| On another machine (Piped lives here) | `PIPED_API_URL=https://<machine>.<tailnet>.ts.net`, `PIPED_KEY=<same>`, no local proxy URL |

If a Piped URL is saved on the backend's admin page, it overrides `PIPED_API_URL`. Update it
or clear it too. Today's production address is `https://sonare-piped.tailb61775.ts.net`
(`render.yaml`).

## 4. Updating

```bash
./updatePiped.sh            # Windows: .\updatePiped.ps1
```

This pulls the latest code and restarts Piped. It rebuilds only if the Piped source changed,
and goes through `./funnel.sh up` when Funnel is set up. It refuses to pull over uncommitted
changes. From the root `sonare` repo, `./update.sh prod` updates and starts the production
part of this machine (Piped + Funnel).

When YouTube breaks something (empty search or albums, "not a bot" errors, audio stopping
after about 1 MB), `./runPiped.sh check` shows which part failed. Then:

```bash
./runPiped.sh bump              # newest NewPipeExtractor; rebuild, check, roll back on failure
./runPiped.sh bump --bg-helper  # newest bg-helper (PoTokens); check, roll back on failure
```

Commit `build.gradle` or `docker-compose.yml` afterwards, so every machine gets the fix.

## 5. Moving Piped to another device

1. **Old machine:** `./funnel.sh down`, then `./runPiped.sh down`. In the
   [Tailscale admin console](https://login.tailscale.com/admin/machines), delete
   `sonare-piped`. Otherwise the new machine gets `sonare-piped-1`, a different address.
2. **New machine:** clone the repo (step 1 above) and copy over the old machine's `.env` and
   `config.properties`. That keeps `PIPED_KEY` and the database password. `data/` doesn't need
   copying.
   - On the same CPU architecture, you can also copy `image-backup/`. `up` then restores that
     build instead of compiling for minutes.
   - An x86_64 build won't run on a Raspberry Pi, or the other way round.
3. **New machine:** `./installPiped.sh`, `./runPiped.sh up`, `./runPiped.sh check`.
4. **New machine:** `./funnel.sh install` (same Tailscale account),
   `loginctl enable-linger "$USER"`, then `./funnel.sh up`. On Windows: `.\installPiped.ps1`,
   `.\runPiped.ps1 up`, `.\funnel.ps1 install`, `.\funnel.ps1 up`.
5. **Render:** with the same machine name, tailnet and key, nothing changes. If `up` printed a
   different address, or you made a new key, update `PIPED_API_URL` / `PIPED_KEY` in Render's
   environment (and `render.yaml`).
6. **The old machine's own backend, if you still develop there:** switch it to the "On another
   machine" row of the table above.
7. **Check from outside:** `curl https://api.sonare.vip/api/v1/healthz` should say
   `"piped":"up"`.

Windows notes: Tailscale there is the regular app, so the whole PC joins the tailnet. If that
PC was already signed in to Tailscale, it keeps its existing name; use that name in
`PIPED_API_URL`. The 5-minute check runs only while you're signed in to Windows, and logs to
`%LOCALAPPDATA%\sonare-tailscale\funnel-check.log`.

## 6. Troubleshooting

| Symptom                                                                                 | Cause and fix                                                                                                                                                                                          |
| --------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `UPSTREAM_UNAVAILABLE ... (ECONNRESET)` from api.sonare.vip, but Funnel works from here | One of the Funnel's relay addresses lost its link to this machine. `./funnel.sh check` restarts Tailscale (the timer does it within 5 minutes). By hand: `systemctl --user restart sonare-tailscaled`. |
| `./funnel.sh status` shows `NO ANSWER` on every address                                 | Tailscale is down or not signed in (`systemctl --user status sonare-tailscaled`), or Funnel is off (`./funnel.sh up`).                                                                                 |
| Relay answers `unexpected`, e.g. 403 with the key                                       | `PIPED_KEY` differs between the gate and what was tested. Run `./funnel.sh up` (it restarts the gate with `.env`'s key). Render needs that same key.                                                   |
| `502` / `piped: down` while Funnel is fine                                              | Piped itself is down. `./runPiped.sh status`, then `./runPiped.sh logs`.                                                                                                                               |
| The gate isn't answering on 127.0.0.1:8092                                              | The stack is down, or `COMPOSE_PROFILES=funnel` is missing from `.env`. Run `./runPiped.sh up`.                                                                                                        |
| Search or albums empty, "not a bot", audio stops after ~1 MB                            | YouTube changed something: `./runPiped.sh check`, then `bump` (section 4).                                                                                                                             |
| The first build fails on jitpack.io                                                     | JitPack is still compiling the extractor. Run it again in a few minutes.                                                                                                                               |
| Funnel stops when you log out (Linux)                                                   | `loginctl enable-linger "$USER"`.                                                                                                                                                                      |
| "Funnel was refused"                                                                    | Allow HTTPS and Funnel for the tailnet (section 3), then `./funnel.sh up`.                                                                                                                             |

Where to look:

- `./funnel.sh status`
- `journalctl --user -u sonare-funnel-check` (each 5-minute check)
- `journalctl --user -u sonare-tailscaled`
- `docker compose --profile funnel logs gate`: every request through Funnel, with the caller's
  IP. Render's show up as `Sonare/1.0`.

## Command summary

| Command                            | What it does                                                    |
| ---------------------------------- | --------------------------------------------------------------- |
| `./installPiped.sh`                | First-time setup: `.env`, `config.properties`, images, build    |
| `./runPiped.sh up`                 | Start (rebuild if the source changed), wait until healthy       |
| `./runPiped.sh down`               | Stop and remove the containers                                  |
| `./runPiped.sh status`             | Container state and API health                                  |
| `./runPiped.sh logs`               | Follow Piped's logs                                             |
| `./runPiped.sh check`              | Smoke test against YouTube                                      |
| `./runPiped.sh bump [--bg-helper]` | Move to the newest extractor or bg-helper, with rollback        |
| `./updatePiped.sh`                 | Pull and restart (and republish with Funnel when set up)        |
| `./funnel.sh install`              | Install Tailscale and sign in (once per machine)                |
| `./funnel.sh up`                   | Publish with Funnel, check the relays, start the 5-minute check |
| `./funnel.sh down`                 | Stop publishing; Piped stays up, local only                     |
| `./funnel.sh status`               | Tailscale, Funnel, gate, timer, and each relay's answer         |
| `./funnel.sh check`                | Check each relay; restart Tailscale if one is dead              |

On Windows, every one of these is the same name with `.ps1`: `.\runPiped.ps1 up`,
`.\funnel.ps1 up`, and so on.
