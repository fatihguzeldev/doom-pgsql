![doom-pgsql](assets/logo.gif)

doom, but the engine is rewritten in sql.

```sh
./play
```

press `enter` on `new game` to start. use the arrow keys to choose a map or difficulty.

## controls

move with `wasd`. turn with `←` and `→` or `j` and `l`. press `space` to fire and `e` to open doors or hit switches. `r` toggles auto-walk, `esc` pauses and `q` quits.

on the minimap, `·` marks your trail and `⚑` marks an exit.

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
| `--rife` | enable frame generation |
| `--resolution 96x60` | set the sql render size (default 160×100) |
| `--low-res` / `--detail` | shortcuts for 64×40 / 160×100 |
| `--predict-turn` | show turns while waiting for the next sql frame |
| `--mute` | turn off sound |

`docker compose down` stops the local database and keeps your saves.

## the $5 setup

i wanted to see if doom could run on the $5 postgres plan from [planetscale](https://planetscale.com). to simulate its 1/16 vcpu and 512 mib of ram locally, put this in `.env` next to `play`.

```dotenv
DOOM_DB_CPUS=0.0625
DOOM_DB_RAM=512m
DOOM_DB_RAM_SWAP=512m       # same as ram disables swap
DOOM_RTT_MS=46              # simulated latency for my connection
DOOM_RIFE_RESOLUTION=64x40
```

run `./play --rife` to use it. `--dsn` skips the local settings.
