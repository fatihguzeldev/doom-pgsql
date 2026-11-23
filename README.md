# Doom on PostgreSQL

With Docker running and the Compose plugin installed, open a terminal in this directory and run

```sh
./play
```

The first run installs the SQL engine and opens the Doom menu with the bundled shareware WAD. Press Enter to start E1M1. Use the arrow keys to choose a map and difficulty, or select **Load game** to continue a previous game.

Move with WASD, turn with J/L or the left and right arrows, fire with Space, and open doors with E. Esc pauses and Q quits. In terminals that report key releases, movement stops when you release the key. Other terminals estimate the release from key repeat, so a short tap can last up to half a second. R toggles auto-walk.

The FPS counter counts fresh world frames from PostgreSQL over the last second. It can reach zero while the view is still. Pistol shots use the WAD sound on hosts with `afplay`, `paplay`, or `aplay`. Other hosts use the terminal bell. Pass `--mute` for silence.

```sh
./play --map E1M7 --skill 1
./play --wad ~/games/doom2.wad --map MAP01
./play --game 1
```

Use `--wad` for a classic WAD that includes its own map and textures. Use `--dsn` to connect to an existing SQL Doom database. Run `./play --help` to see all options.

After quitting, `docker compose down` stops PostgreSQL. Your games stay in the Compose volume for the next run.
