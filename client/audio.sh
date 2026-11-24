#!/usr/bin/env bash
# the host owns the audio device. the client publishes completed wav files here.
dir=$1
player=$2
track=
music_pid=
voices=()
slot=0

stop_music() {
    if [[ -n $music_pid ]]; then
        kill "$music_pid" 2>/dev/null
        wait "$music_pid" 2>/dev/null
        music_pid=
    fi
    track=
}

cleanup() {
    local pid
    for pid in $(jobs -pr); do kill "$pid" 2>/dev/null; done
    wait
}
trap cleanup EXIT
trap 'exit 0' HUP INT TERM
exec 3<"$dir/events"
while [[ -d $dir ]]; do
    while read -r command name <&3; do
        case "$command" in
            stop) stop_music ;;
            quit) exit 0 ;;
            music)
                stop_music
                [[ $name =~ ^D_[A-Z0-9_]{1,6}$ ]] && track="$dir/$name.wav"
                ;;
            effect)
                [[ $name =~ ^DS[A-Z0-9_]{1,6}$ ]] || continue
                if [[ -n ${voices[slot]} ]]; then
                    kill "${voices[slot]}" 2>/dev/null
                    wait "${voices[slot]}" 2>/dev/null
                fi
                "$player" "$dir/$name.wav" </dev/null >/dev/null 2>&1 &
                voices[slot]=$!
                slot=$(( (slot + 1) % 8 ))
                ;;
        esac
    done
    if [[ -n $music_pid ]] && ! kill -0 "$music_pid" 2>/dev/null; then
        wait "$music_pid" || track=
        music_pid=
    fi
    if [[ -n $track && -z $music_pid ]]; then
        "$player" "$track" </dev/null >/dev/null 2>&1 &
        music_pid=$!
    fi
    sleep 0.03
done
