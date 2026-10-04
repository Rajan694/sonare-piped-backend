# Piped-Backend (Sonare)

This is Sonare's fork of Piped's backend; the Sonare API (`sonare-backend`) is its only
client. Run it with `./installPiped.sh` once and `./runPiped.sh up`: the API listens on
127.0.0.1:8090 and piped-proxy on 127.0.0.1:8091.

## When YouTube breaks something

`./runPiped.sh check` runs `checkPiped.sh`, which searches for a song, opens an album, extracts
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
`syncEnvConfig.sh`; an empty value leaves the file as it is.

- `PIPED_PROXY_URL`: the piped-proxy base Piped rewrites media URLs to (`PROXY_PART` in
  `config.properties`). Change it when the proxy moves off localhost.
- `PIPED_EXTRACTOR_COMMIT`: the NewPipeExtractor commit in `build.gradle`; a new one rebuilds
  the image.

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
