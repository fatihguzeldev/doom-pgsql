# Doom on PostgreSQL

With Docker running and the Compose plugin installed, open a terminal in this directory and run

```sh
./play
```

The first run installs the SQL engine in a local container and opens E1M1 from the bundled shareware WAD. Move with WASD, turn with J/L or the left and right arrows, fire with Space, open doors with E, and quit with Q.

```sh
./play --map E1M7 --skill 1
./play --wad ~/games/doom2.wad --map MAP01
./play --game 1
```

Use `--wad` for a classic WAD that includes its own map and textures. Use `--dsn` to connect to an existing SQL Doom database. Run `./play --help` to see all options.

After quitting, `docker compose down` stops PostgreSQL. Your games stay in the Compose volume for the next run.
