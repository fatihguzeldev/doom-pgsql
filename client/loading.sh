# sourced by play while docker prepares the terminal client
boot_frame() {
    local done=$1 total=$2 tick=$3 rows=$4 cols=$5 left dash right y x i width filled bar=
    local tips=(▏ ▎ ▍ ▌)
    (( cols > 1 && rows > 0 )) || return 0
    width=$((cols > 42 ? 40 : cols - 2))
    y=$((rows / 2 + 1))
    if (( cols >= 70 && rows >= 10 )); then
        x=$(( (cols - 68) / 2 + 1 ))
        i=$((y - 4))
        while IFS='|' read -r left dash right; do
            printf '\033[%d;%dH\033[38;2;255;167;105m%s\033[38;2;124;89;121m%s\033[38;2;145;192;238m%s' \
                "$i" "$x" "$left" "$dash" "$right"
            i=$((i+1))
        done < "$repo/client/wordmark.txt"
        y=$((y+2))
    elif (( cols >= 12 && rows >= 3 )); then
        printf '\033[%d;%dH\033[38;2;255;167;105mDOOM-PGSQL' "$((y-1))" "$(((cols-10)/2+1))"
    fi
    filled=$((width * done / total))
    for ((i=0; i<width; i++)); do
        if ((i < filled)); then bar+='█'
        elif ((i == filled)); then bar+="${tips[tick % 4]}"$'\033[38;2;124;89;121m'
        else bar+='░'; fi
    done
    printf '\033[%d;%dH\033[38;2;255;209;137m%s' "$y" "$(((cols-width)/2+1))" "$bar"
}

animate_boot() {
    local tick=0 done=0 rows cols last_size=
    while :; do
        read -r done < "$runtime/steps" || done=0
        read -r rows cols < <(stty size) || return
        if [[ "$rows $cols" != "$last_size" ]]; then
            printf '\033[48;2;18;14;23m\033[2J'
            last_size="$rows $cols"
        fi
        boot_frame "$done" "$total_steps" "$tick" "$rows" "$cols"
        tick=$((tick+1))
        sleep 0.15
    done
}
