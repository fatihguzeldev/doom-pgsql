![doom-pgsql](assets/logo.png)

doom, but the engine is rewritten in sql.

```sh
./play
```

hit `enter` for e1m7 (computer station), or pick a map and difficulty with the arrow keys. the shareware wad is included.

## controls

move with `wasd`. turn with `←` and `→` or `j` and `l`. press `space` to fire and `e` to open doors or hit switches. `r` toggles auto-walk, `esc` pauses and `q` quits.

## flags

| flag | use |
| --- | --- |
| `--wad doom2.wad` | load a wad with its own maps and textures |
| `--map e1m1` | start on a specific map |
| `--skill 3` | choose a difficulty from 1 to 5 (default 3) |
| `--game 1` | resume a saved game by id |
| `--dsn <connection>` | play on an existing postgres database with the engine installed |
| `--rtt-ms 0` | set the local round-trip delay in milliseconds (0 turns it off) |
| `--delta` | fetch only the strips of the frame that changed |
| `--predict-turn` | show turns before the next frame arrives |
| `--mute` | turn off sound |

set local cpu, ram, swap and simulated latency in [settings.yaml](settings.yaml). `--dsn` skips the file.

`docker compose down` stops the database and keeps your saves.
