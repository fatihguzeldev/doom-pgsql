![doom-pgsql](assets/logo.png)

postgres runs the game and renders the world.

```sh
./play
```

press `enter` to start the bundled shareware episode. use the arrow keys in the menu to pick a map or difficulty.

## controls

move with `wasd`. turn with `j` and `l` or the left and right arrows. `space` fires, `e` opens doors and `r` toggles auto-walk. press `esc` to pause or `q` to quit.

## flags

| flag | what it does |
| --- | --- |
| `--wad doom2.wad` | use your own wad with maps and textures |
| `--map e1m7` | pick the starting map |
| `--skill 3` | set the difficulty from 1 to 5 (default 3) |
| `--game 1` | resume a saved game by id |
| `--dsn <connection>` | connect to a postgres database with the game installed |
| `--rtt-ms 50` | add 50 ms of simulated round-trip delay for this run (0 disables it) |
| `--delta` | fetch only the parts of the frame that changed |
| `--predict-turn` | show turns before the next frame arrives |
| `--mute` | turn off sound |

edit [settings.yaml](settings.yaml) to change the local database limits and simulated delay.

`docker compose down` stops the database and keeps your saves.
