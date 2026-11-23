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
| `--map e1m1` | choose the starting map |
| `--skill 3` | set difficulty from 1 to 5 (default 3) |
| `--game 1` | resume a saved game by id |
| `--dsn <connection>` | play on an existing postgres database with the engine installed |
| `--rtt-ms 0` | set simulated latency in milliseconds for local play |
| `--delta` | fetch only changed strips of each frame |
| `--rife` | render at 64×40 with frame generation |
| `--rife --detail` | render at 160×100 with frame generation |
| `--predict-turn` | show turns while waiting for the next sql frame |
| `--mute` | turn off sound |

configure local cpu, memory, swap and simulated latency in [settings.yaml](settings.yaml).

`docker compose down` stops the local database and keeps your saves.
