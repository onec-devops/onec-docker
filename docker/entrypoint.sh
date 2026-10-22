#!/usr/bin/env bash
# Container entrypoint.
#   ragent [extra args] - 1C server agent with the cluster administration server (default);
#                         in the full image also the virtual display, VNC server and noVNC;
#                         extra args alone, starting with a key, mean the same
#   ras    [extra args] - cluster administration server alone
#   ibsrv  [extra args] - standalone server; on the first start creates an empty file infobase
#                         for it or takes one from the file in ONEC_INFOBASE_SOURCE,
#                         in the full image also starts the virtual display
#   any other command   - executed as is
# Any of them also runs as an arbitrary user given with --user.
set -euo pipefail

ONEC_HOME=${ONEC_HOME:-/opt/1cv8/current}
ONEC_SRV_DATA=${ONEC_SRV_DATA:-/home/usr1cv8/.1cv8/1C/1cv8}
ONEC_PORT=${ONEC_PORT:-1540}
ONEC_RAS_PORT=${ONEC_RAS_PORT:-1545}
# Tells healthcheck.sh that ibsrv is ready; /dev/shm is empty in a started container
IBSRV_READY=/dev/shm/ibsrv-ready

die() {
    echo "entrypoint: $*" >&2
    exit 1
}

# Starts the virtual display of the full image with a window manager, a VNC server and noVNC on it.
# These are helpers: the container keeps running when one of them exits.
start_display() {
    local number=${DISPLAY#:}
    # Left behind when the container is restarted
    rm -f "/tmp/.X$number-lock" "/tmp/.X11-unix/X$number"
    Xvfb "$DISPLAY" -nolisten tcp -dpi "${SCREEN_DPI:-96}" \
        -screen 0 "${SCREEN_WIDTH:-1920}x${SCREEN_HEIGHT:-1080}x${SCREEN_DEPTH:-24}" &
    for _ in $(seq 50); do
        xdpyinfo >/dev/null 2>&1 && break
        sleep 0.1
    done
    fluxbox >/dev/null 2>&1 &
    # VNC_PASSWORD_FILE, such as a Docker secret, takes precedence over VNC_PASSWORD.
    # Without either the VNC server asks for no password.
    local password=${VNC_PASSWORD:-}
    if [[ -n ${VNC_PASSWORD_FILE:-} ]]; then
        password=$(<"$VNC_PASSWORD_FILE")
    fi
    unset VNC_PASSWORD VNC_PASSWORD_FILE
    local auth=(-nopw)
    if [[ -n $password ]]; then
        mkdir -p "$HOME/.vnc"
        x11vnc -storepasswd "$password" "$HOME/.vnc/passwd" >/dev/null 2>&1
        auth=(-rfbauth "$HOME/.vnc/passwd")
    fi
    x11vnc -forever -shared "${auth[@]}" -quiet &
    novnc_proxy --listen 6080 --vnc localhost:5900 >/dev/null &
}

# stop_ibsrv <pid>: on SIGTERM ibsrv stops serving at once, but after it has had a session
# its process never exits, so it is killed if it is still there a second later. The wait
# is short because docker stop gives a container as little as three seconds.
stop_ibsrv() {
    kill -TERM "$1" 2>/dev/null || return 0
    for _ in $(seq 10); do
        kill -0 "$1" 2>/dev/null || return 0
        sleep 0.1
    done
    kill -KILL "$1" 2>/dev/null || true
}

# A user given with --user may have no entry in /etc/passwd. The platform crashes without
# one, and Java, which runs 1C:EDT, takes the home directory only from there, so nss_wrapper
# supplies it, the way the postgres image does
if ! getent passwd "$(id -u)" >/dev/null; then
    NSS_WRAPPER_PASSWD=$(mktemp)
    NSS_WRAPPER_GROUP=$(mktemp)
    echo "usr1cv8:x:$(id -u):$(id -g)::$HOME:/bin/bash" >"$NSS_WRAPPER_PASSWD"
    echo "grp1cv8:x:$(id -g):" >"$NSS_WRAPPER_GROUP"
    export LD_PRELOAD=libnss_wrapper.so NSS_WRAPPER_PASSWD NSS_WRAPPER_GROUP
fi

# Arguments that start with a key are keys of the default command
if [[ ${1:-} == -* ]]; then
    set -- ragent "$@"
fi

cmd=${1:-ragent}
if [[ $# -gt 0 ]]; then
    shift
fi

case "$cmd" in
    ragent)
        # ragent refuses a key given twice, and ras would not learn the port from it
        for arg in "$@"; do
            case "$arg" in
                -d) variable=ONEC_SRV_DATA ;;
                -port) variable=ONEC_PORT ;;
                -regport) variable=ONEC_REGPORT ;;
                -range) variable=ONEC_RANGE ;;
                -seclev) die "the $arg key is set by the image and cannot be changed" ;;
                *) continue ;;
            esac
            die "the $arg key is set by the image, use the $variable variable instead"
        done
        args=(
            -d "$ONEC_SRV_DATA"
            -port "$ONEC_PORT"
            -regport "${ONEC_REGPORT:-1541}"
            -range "${ONEC_RANGE:-1560:1591}"
            -seclev 0
        )
        if [[ ${ONEC_DEBUG:-false} == true ]]; then
            args+=(-debug -http -debugServerPort "${ONEC_DEBUG_PORT:-1550}")
        fi
        # Only the full image sets DISPLAY
        if [[ -n ${DISPLAY:-} && ${START_DISPLAY:-true} == true ]]; then
            start_display
        fi
        "$ONEC_HOME/ragent" "${args[@]}" "$@" &
        pids=($!)
        "$ONEC_HOME/ras" cluster --port="$ONEC_RAS_PORT" "localhost:$ONEC_PORT" &
        pids+=($!)
        # When either process exits, the other one is stopped too, so the container stops
        # and its restart policy applies. docker stop reaches both through the trap.
        # The display helpers are not waited for, they end with the container.
        trap 'kill -TERM "${pids[@]}" 2>/dev/null || true' TERM INT
        status=0
        wait -n "${pids[@]}" || status=$?
        kill -TERM "${pids[@]}" 2>/dev/null || true
        wait "${pids[@]}" || true
        exit "$status"
        ;;
    ras)
        exec "$ONEC_HOME/ras" cluster --port="$ONEC_RAS_PORT" \
            "${ONEC_RAS_AGENT:-localhost:$ONEC_PORT}" "$@"
        ;;
    ibsrv)
        # The data directory and the settings file are the image's own unless the arguments
        # give theirs. The settings file makes ibsrv listen on all addresses instead of
        # localhost; the keys given in the arguments take precedence over it. A file
        # the user keeps with the other settings of the platform replaces the one of the image.
        data=$ONEC_SRV_DATA/standalone-server
        config=/usr/local/etc/ibsrv.yml
        if [[ -e $ONEC_SRV_DATA/conf/ibsrv.yml ]]; then
            config=$ONEC_SRV_DATA/conf/ibsrv.yml
        fi
        create=true
        for arg in "$@"; do
            case "$arg" in
                -h | '-?' | --help | -v | --version) exec "$ONEC_HOME/ibsrv" "$@" ;;
                -d | --data | --data=*) data='' create=false ;;
                -c | --config | --config=*) config='' create=false ;;
                --dbms | --dbms=* | --db-* | --database-*) create=false ;;
            esac
        done
        # ibsrv does not serve without an infobase, so the first start creates an empty file
        # one, the way the postgres image creates a database, or takes it from
        # ONEC_INFOBASE_SOURCE: a file infobase or a dump, told apart by the first bytes.
        # An infobase the arguments place elsewhere is not created.
        infobase=$data/db-data/1Cv8.1CD
        if [[ $create == true && ! -e $infobase ]]; then
            source=${ONEC_INFOBASE_SOURCE:-}
            if [[ -z $source ]]; then
                "$ONEC_HOME/ibcmd" infobase create --data="$data"
            elif [[ ! -f $source ]]; then
                die "ONEC_INFOBASE_SOURCE: no file $source"
            else
                case "$(head -c 8 "$source" | tr -d '\0')" in
                    1CDBMSV8)
                        # Copied under another name first, so an interrupted copy is not taken
                        # for the infobase on the next start
                        echo "entrypoint: copying the infobase from $source"
                        install -D -m 640 "$source" "$infobase.part"
                        mv "$infobase.part" "$infobase"
                        ;;
                    1CIBDmpF)
                        if ! "$ONEC_HOME/ibcmd" infobase create --data="$data" --restore="$source"; then
                            # Without the infobase the next start restores again
                            rm -rf "$data"
                            die "ONEC_INFOBASE_SOURCE: cannot restore the infobase from $source"
                        fi
                        ;;
                    *)
                        die "ONEC_INFOBASE_SOURCE: $source is neither a file infobase nor a dump"
                        ;;
                esac
            fi
        fi
        args=()
        if [[ -n $data ]]; then
            args+=(--data="$data")
        fi
        if [[ -n $config ]]; then
            args+=(--config="$config")
        fi
        if [[ ${ONEC_DEBUG:-false} == true ]]; then
            args+=(--debug=http --debug-address=any --debug-port="${ONEC_DEBUG_PORT:-1550}")
        fi
        if [[ -n ${DISPLAY:-} && ${START_DISPLAY:-true} == true ]]; then
            start_display
        fi
        # the health check goes by the message ibsrv prints when it is ready
        rm -f "$IBSRV_READY"
        "$ONEC_HOME/ibsrv" "${args[@]}" "$@" > >(
            # The signals of a stop are left to ibsrv, so its last messages get through
            trap '' TERM INT
            while IFS= read -r line; do
                printf '%s\n' "$line"
                if [[ $line == *'Server ready.' ]]; then
                    touch "$IBSRV_READY"
                fi
            done
        ) &
        pid=$!
        # A stop on request ends with the code of the signal, even when ibsrv had to be killed
        trap 'stop_ibsrv "$pid"; exit 143' TERM
        trap 'stop_ibsrv "$pid"; exit 130' INT
        status=0
        wait "$pid" || status=$?
        exit "$status"
        ;;
    *)
        exec -- "$cmd" "$@"
        ;;
esac
