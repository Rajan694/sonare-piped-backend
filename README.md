# Piped-Backend (Sonare)

This is Sonare's fork of Piped's backend; the Sonare API (`sonare-backend`) is its only
client. Run it with `./installPiped.sh` once and `./runPiped.sh up`: the API listens on
127.0.0.1:8090 and piped-proxy on 127.0.0.1:8091.

## Database password

`docker-compose.yml` reads the Postgres password from `PIPED_DB_PASSWORD` and falls back to
`changeme`, which is only acceptable on a development machine. In production:

1. Export a strong `PIPED_DB_PASSWORD` (or put it in a `.env` file next to
   `docker-compose.yml`, which docker compose reads) before `./runPiped.sh up`.
2. Set `hibernate.connection.password` in `config.properties` to the same value.

Postgres only applies the password when it first creates `data/db`; to change it on an
existing database, also run `ALTER USER piped PASSWORD '…'` inside the postgres container.

## Licence

AGPL-3.0, like upstream Piped — see [LICENSE](LICENSE).

---

## Upstream Piped-Backend

An advanced open-source privacy friendly alternative to YouTube, crafted with the help of [NewPipeExtractor](https://github.com/TeamNewPipe/NewPipeExtractor).

## Official Frontend

-   VueJS frontend - [Piped](https://github.com/TeamPiped/Piped)

## Community Projects

-   See https://github.com/TeamPiped/Piped#made-with-piped
