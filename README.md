![doom-pgsql](assets/logo.png)

doom, but the engine is rewritten in sql.

```sh
./play
```

press `enter` on `new game` to start. use the arrow keys to choose a map or difficulty.

## controls

move with `wasd`. turn with `←` and `→` or `j` and `l`. press `space` to fire and `e` to open doors or hit switches. `r` toggles auto-walk, `esc` pauses and `q` quits.

## flags

| flag | use |
| --- | --- |
| `--wad doom2.wad` | load your own wad |
| `--map e1m1` | choose the starting map (the bundled shareware wad defaults to e1m7) |
| `--skill 3` | choose a difficulty from 1 to 5 (default 3) |
| `--game 1` | resume a saved game by id |
| `--dsn <connection>` | play on an existing postgres database with the engine installed |
| `--rtt-ms 0` | set the local round-trip delay in milliseconds (0 turns it off) |
| `--delta` | fetch only the strips of the frame that changed |
| `--rife` | draw at 64×40, upscale to 160×100 and show up to four rife frames between sql frames |
| `--predict-turn` | show turns before the next frame arrives |
| `--mute` | turn off sound |

set local cpu, ram, swap and simulated latency in [settings.yaml](settings.yaml). `--dsn` skips the file.

`docker compose down` stops the database and keeps your saves.
