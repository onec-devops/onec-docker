#!/usr/bin/env bash
# Smoke tests for the built images, reported in TAP format (https://testanything.org).
# Run after `docker compose build` of the services to test, see usage below. Each image gets
# the parts for its kind: 1-3 the server and server-edt images, 4 the full and full-edt
# images, 5 both EDT images.
#   1. Server image: version label, user, locale, fonts, time zone, shared libraries
#      of the binaries and modules, no clients, ibcmd runs as an arbitrary user, arguments
#      that start with a key go to ragent, a ragent key the image sets itself is refused.
#   2. Standalone server: the ibsrv command creates an empty file infobase on the first
#      start and serves it over OData, keeps it on restart and stops on docker stop,
#      takes the infobase from a .1CD or .dt file in ONEC_INFOBASE_SOURCE, asked for help
#      it creates nothing, given its own infobase location it creates nothing either and
#      keeps the settings of the image, a settings file of the user replaces the one
#      of the image.
#   3. The server service under a separate project without published ports: it keeps
#      its MAC address, rac -> ras -> ragent lists the cluster, the container restarts
#      when ras exits and stops on docker stop without being killed.
#   4. Full image: clients as configured by ONEC_CLIENT_COMPONENTS
#      and their shared libraries, x11vnc serves the virtual display to VNC clients
#      and to noVNC in a browser, the thin client opens an infobase served by ibsrv
#      on a virtual display, also as an arbitrary user, the ibsrv command runs with
#      the display too, the full service runs as the server with a display, a VNC
#      server and noVNC, which come back after a restart.
#   5. EDT images: 1cedtcli runs 1C:EDT of the version in the tag, which supports only the configured platform versions, imports an empty
#      configuration into a project and exports it to XML as an arbitrary user, and ibcmd
#      builds a .cf from the export.
set -euo pipefail

# Keep Git Bash on Windows from rewriting /opt/... into Windows paths
export MSYS_NO_PATHCONV=1

cd "$(dirname "$0")/.."

readonly project=onec-test
readonly curl_image=curlimages/curl:8.22.0
readonly ibsrv_container=$project-ibsrv
readonly client_container=$project-client
readonly nodisplay_container=$project-nodisplay
readonly key_container=$project-key
readonly seed_volume=$project-seed
readonly onec_home=/opt/1cv8/current
# A user and a group that have no entries in /etc/passwd and /etc/group of the images
readonly arbitrary_user=1234:5678
readonly compose=(docker compose --progress quiet -p "$project" -f compose.yaml -f tests/compose.test.yaml)

usage() {
    echo "Usage: tests/smoke.sh [service ...]"
    echo "Tests the images of the services, any of server, full, server-edt and full-edt."
    echo "Without services, tests those of them whose images are built. The versions and"
    echo "the namespace of the images come from .env or the environment, as in compose.yaml."
}

if [[ ${1:-} == -h || ${1:-} == --help ]]; then
    usage
    exit
fi

tests=0
failures=0

diag() {
    local line
    while IFS= read -r line; do
        echo "# $line"
    done <<<"$*"
}

ok() {
    tests=$((tests + 1))
    echo "ok $tests - $1"
}

not_ok() {
    tests=$((tests + 1))
    failures=$((failures + 1))
    echo "not ok $tests - $1"
    if [[ -n ${2:-} ]]; then
        diag "$2"
    fi
}

skip() {
    tests=$((tests + 1))
    echo "ok $tests - $1 # SKIP $2"
}

# check <description> <command...>: passes if the command succeeds
check() {
    local description=$1 output
    shift
    if output=$("$@" 2>&1); then
        ok "$description"
    else
        not_ok "$description" "$output"
    fi
}

# check_eq <description> <expected> <command...>: passes if the output equals <expected>
check_eq() {
    local description=$1 expected=$2 output
    shift 2
    if output=$("$@" 2>&1) && [[ $output == "$expected" ]]; then
        ok "$description"
    else
        not_ok "$description" "expected: $expected"$'\n'"got: $output"
    fi
}

# check_contains <description> <substring> <command...>: passes if the output contains <substring>
check_contains() {
    local description=$1 substring=$2 output
    shift 2
    if output=$("$@" 2>&1) && [[ $output == *"$substring"* ]]; then
        ok "$description"
    else
        not_ok "$description" "expected to contain: $substring"$'\n'"got: $output"
    fi
}

in_image() {
    docker run --rm "$image" "$@"
}

in_full_image() {
    docker run --rm "$full_image" "$@"
}

in_edt_image() {
    docker run --rm "$edt_image" "$@"
}

# Libraries that are not found, and libraries too old for a library that needs them
# (such as an older C++ runtime shipped with the platform). The modules are checked too:
# the binaries load them at run time.
missing_libraries() {
    # shellcheck disable=SC2016 # expanded inside the container
    in_image bash -c '
        for f in "$ONEC_HOME"/{ragent,rmngr,rphost,ras,rac,ibcmd,ibsrv} "$ONEC_HOME"/*.so; do
            ldd "$f" | sed -n -e "s|^\s*\(\S*\) => not found|$(basename "$f"): \1|p" \
                -e "s|^\S*: \S*/\(\S*\): version .\(\S*\). not found.*|$(basename "$f"): \1 has no \2|p"
        done | sort -u'
}

# The clients load most of the platform modules at run time, so all of them are checked
missing_client_libraries() {
    # shellcheck disable=SC2016 # expanded inside the container
    in_full_image bash -c '
        for f in "$ONEC_HOME"/{1cv8,1cv8c,1cv8s} "$ONEC_HOME"/*.so /opt/1cv8/common/1cestart; do
            [[ -e $f ]] || continue
            ldd "$f" | sed -n -e "s|^\s*\(\S*\) => not found|$(basename "$f"): \1|p" \
                -e "s|^\S*: \S*/\(\S*\): version .\(\S*\). not found.*|$(basename "$f"): \1 has no \2|p"
        done | sort -u'
}

# thin_client_opens [docker run options...]: the thin client connects to ibsrv on a virtual
# display. Succeeds once the main window of the empty configuration ("Конфигурация") is shown;
# prints the windows on the display, the state of the client and the end of its output otherwise.
# Startup messages are not disabled: Vanessa Automation starts its test clients without
# /DisableStartupMessages, so a startup warning would block them.
thin_client_opens() {
    # shellcheck disable=SC2016 # expanded inside the container
    docker run --rm --name "$client_container" "$@" "$full_image" xvfb-run -a bash -c '
        ibcmd infobase create --db-path=/tmp/ib >/dev/null
        ibsrv --config=/usr/local/etc/ibsrv.yml --db-path=/tmp/ib --name=smoke >/dev/null &
        for _ in $(seq 30); do
            (</dev/tcp/127.0.0.1/8314) 2>/dev/null && break
            sleep 1
        done
        1cv8c ENTERPRISE /WS http://127.0.0.1:8314 >/tmp/client.log 2>&1 &
        client=$!
        for _ in $(seq 60); do
            sleep 2
            windows=$(xwininfo -root -tree)
            if grep -q "\"Конфигурация\"" <<<"$windows"; then
                exit 0
            fi
        done
        echo "windows:"
        grep -o "\"[^\"]*\": (\"[^\"]*\"" <<<"$windows" | sort -u
        if kill -0 "$client" 2>/dev/null; then
            echo "client is running"
        else
            wait "$client"
            echo "client exited with $?"
        fi
        echo "client output:"
        tail -n 20 /tmp/client.log
        exit 1'
}

# novnc_proxy serves the noVNC page and proxies WebSocket connections to x11vnc; prints
# the status line of the page and the RFB protocol banner from the first WebSocket frame
novnc_banner() {
    # shellcheck disable=SC2016 # expanded inside the container
    in_full_image xvfb-run -a bash -c '
        x11vnc -display "$DISPLAY" -nopw -quiet >/dev/null 2>&1 &
        novnc_proxy --listen 6080 --vnc localhost:5900 >/dev/null 2>&1 &
        for _ in $(seq 20); do
            (</dev/tcp/127.0.0.1/6080) 2>/dev/null && break
            sleep 0.5
        done
        exec 3<>/dev/tcp/127.0.0.1/6080
        printf "GET / HTTP/1.0\r\n\r\n" >&3
        head -n 1 <&3 | tr -d "\r"
        exec 3<>/dev/tcp/127.0.0.1/6080
        printf "GET /websockify HTTP/1.1\r\nHost: localhost:6080\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n" >&3
        printf "Origin: http://localhost:6080\r\nSec-WebSocket-Version: 13\r\n" >&3
        printf "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Protocol: binary\r\n\r\n" >&3
        timeout 3 cat <&3 | grep -ao "RFB 003.008"'
}

# full_display: size, DPI and color depth of the display the full service starts, its window manager
# and the windows it manages (none expected), the RFB protocol banner of its VNC server,
# the number of security types it offers with the types (2 is password authentication)
# and the status line of the noVNC page
full_display() {
    "${compose[@]}" exec -T "$full_service" bash -c '
        xdpyinfo | sed -n "s/^ *dimensions: *\([0-9x]*\) .*/\1/p; s/^ *resolution: *\([0-9x]*\) .*/\1 dpi/p"
        xdpyinfo | sed -n "s/^ *depth of root window: *\([0-9]*\) .*/\1 bit/p"
        xprop -root _NET_SUPPORTING_WM_CHECK >/dev/null && pgrep -x fluxbox >/dev/null && echo fluxbox
        xprop -root _NET_CLIENT_LIST | sed "s/.*# *//"
        exec 4<>/dev/tcp/127.0.0.1/5900
        head -c 12 <&4
        printf "RFB 003.008\n" >&4
        head -c 2 <&4 | od -An -tu1 | xargs
        exec 3<>/dev/tcp/127.0.0.1/6080
        printf "GET / HTTP/1.0\r\n\r\n" >&3
        head -n 1 <&3 | tr -d "\r"'
}

# The full image started with START_DISPLAY=false runs the server without the display;
# prints the display processes found otherwise
display_disabled() {
    docker run -d --name "$nodisplay_container" -e START_DISPLAY=false "$full_image" >/dev/null
    for _ in $(seq 30); do
        docker exec "$nodisplay_container" pgrep -x ragent >/dev/null && break
        sleep 1
    done
    docker exec "$nodisplay_container" pgrep -x ragent >/dev/null || {
        echo "ragent is not running"
        return 1
    }
    ! docker exec "$nodisplay_container" pgrep -l -x 'Xvfb|fluxbox|x11vnc|python3'
}

# Arguments that start with a key are passed to ragent; prints its command line
leading_key_runs_ragent() {
    docker run -d --name "$key_container" "$image" -pingTimeout 30000 >/dev/null
    for _ in $(seq 30); do
        docker exec "$key_container" pgrep -x ragent >/dev/null && break
        sleep 1
    done
    docker exec "$key_container" ps -o args= -C ragent
}

# A ragent key the image sets itself is refused; prints the message
image_key_refused() {
    ! docker run --rm "$image" ragent -port 2540
}

# The ibsrv command given its own infobase location; prints the command line of ibsrv
# and the infobases found in the container other than its own. The infobase is created
# beforehand, because without it some versions, such as 8.3.20, stop ibsrv at once.
ibsrv_with_own_infobase() {
    # shellcheck disable=SC2016 # expanded inside the container
    docker run --rm --entrypoint bash "$image" -c '
        ibcmd infobase create --db-path=/tmp/ib >/dev/null
        entrypoint.sh ibsrv --db-path=/tmp/ib >/dev/null 2>&1 &
        for _ in $(seq 30); do
            pgrep -x ibsrv >/dev/null && break
            sleep 1
        done
        ps -o args= -C ibsrv
        find / -name 1Cv8.1CD -not -path "/tmp/ib/*" 2>/dev/null || true'
}

# The ibsrv command with a settings file of the user among the settings of the platform;
# prints the command line of ibsrv
ibsrv_with_own_settings() {
    # shellcheck disable=SC2016 # expanded inside the container
    docker run --rm --entrypoint bash "$image" -c '
        mkdir -p "$ONEC_SRV_DATA/conf"
        printf "server:\n  address: any\n  port: 9000\n" >"$ONEC_SRV_DATA/conf/ibsrv.yml"
        entrypoint.sh ibsrv >/dev/null 2>&1 &
        for _ in $(seq 30); do
            (exec 3<>/dev/tcp/127.0.0.1/9000) 2>/dev/null && break
            sleep 1
        done
        ps -o args= -C ibsrv
        (exec 3<>/dev/tcp/127.0.0.1/9000) 2>/dev/null && echo "port 9000 is open"'
}

# odata <path> [curl options...]: request to ibsrv from a curl container in its network namespace
odata() {
    local path=$1
    shift
    docker run --rm --network "container:$ibsrv_container" "$curl_image" \
        --silent --show-error --retry 30 --retry-delay 1 --retry-connrefused "$@" \
        "http://127.0.0.1:8314/odata/standard.odata/$path"
}

# Errors of the attempts made before ibsrv is up are left out
odata_status() {
    odata "$1" --output /dev/null --write-out '%{http_code}' 2>/dev/null
}

# Fills the seed volume with a file infobase and its dump, the dump under a name without
# an extension; the infobase has an extension named Seed to tell it from an empty one
make_seed_infobase() {
    docker volume create "$seed_volume" >/dev/null
    docker run --rm --user 0 -v "$seed_volume:/seed" "$image" chmod 777 /seed
    docker run --rm -v "$seed_volume:/seed" "$image" bash -c '
        set -e
        ibcmd infobase create --data=/tmp/ib
        # 8.3.20 creates the extension but exits with 102, so the extension is looked up instead
        ibcmd infobase config extension create --data=/tmp/ib --name=Seed --name-prefix=Seed_ || true
        ibcmd infobase config extension list --data=/tmp/ib | grep -qw Seed
        ibcmd infobase dump --data=/tmp/ib /seed/dump
        cp /tmp/ib/db-data/1Cv8.1CD /seed/seed.1CD
        head -c $(($(stat -c %s /seed/dump) / 2)) /seed/dump >/seed/truncated.dt
        echo garbage >/seed/garbage.dt'
}

# infobase_from <file>: starts ibsrv with ONEC_INFOBASE_SOURCE set to the file of the seed
# volume and prints the extensions of the infobase it serves
infobase_from() {
    docker rm -fv "$ibsrv_container" >/dev/null 2>&1 || true
    docker run -d --name "$ibsrv_container" -v "$seed_volume:/seed:ro" \
        -e ONEC_INFOBASE_SOURCE="/seed/$1" "$image" ibsrv >/dev/null
    container_healthy "$ibsrv_container" || return 1
    # shellcheck disable=SC2016 # expanded inside the container
    docker exec "$ibsrv_container" bash -c \
        'ibcmd infobase config extension list --pid="$(pgrep -x ibsrv)"'
}

# infobase_source_refused <file>: output of the ibsrv command that cannot use the file
# and what it left in the server data directory; fails if the command succeeds
infobase_source_refused() {
    # shellcheck disable=SC2016 # expanded inside the container
    docker run --rm -v "$seed_volume:/seed:ro" -e ONEC_INFOBASE_SOURCE="/seed/$1" \
        --entrypoint bash "$image" -c '
            if timeout 60 entrypoint.sh ibsrv 2>&1; then exit 1; fi
            echo "data left: [$(find "$ONEC_SRV_DATA" -mindepth 1)]"'
}

# Restarts the ibsrv container and succeeds if it serves the same infobase file again;
# prints the inode of the file before and after otherwise
infobase_kept_on_restart() {
    local file=/home/usr1cv8/.1cv8/1C/1cv8/standalone-server/db-data/1Cv8.1CD before after
    before=$(docker exec "$ibsrv_container" stat -c %i "$file")
    docker restart "$ibsrv_container" >/dev/null
    [[ $(odata_status "\$metadata") == 200 ]] || return 1
    after=$(docker exec "$ibsrv_container" stat -c %i "$file")
    [[ $before == "$after" ]] || {
        echo "inode before: $before, after: $after"
        return 1
    }
}

# container_healthy <container>: succeeds once the health check of the image passes;
# prints the health status and the output of the last check otherwise
container_healthy() {
    local status
    for _ in $(seq 60); do
        status=$(docker inspect -f '{{.State.Health.Status}}' "$1")
        [[ $status == healthy ]] && return 0
        sleep 1
    done
    echo "health: $status"
    docker inspect -f '{{range .State.Health.Log}}{{.Output}}{{end}}' "$1"
    return 1
}

# container_stop_exit_code <container>: exit code of the container after docker stop,
# 137 if it had to be killed
container_stop_exit_code() {
    docker stop "$1" >/dev/null
    docker inspect -f '{{.State.ExitCode}}' "$1"
}

# The full image started with the ibsrv command runs the display next to it;
# prints the processes found otherwise
ibsrv_with_display() {
    local status=0 process
    docker run -d --name "$client_container" "$full_image" ibsrv >/dev/null
    for _ in $(seq 60); do
        docker exec "$client_container" pgrep -x ibsrv >/dev/null && break
        sleep 1
    done
    for process in ibsrv Xvfb fluxbox x11vnc; do
        docker exec "$client_container" pgrep -x "$process" >/dev/null || status=1
    done
    [[ $status == 0 ]] || docker exec "$client_container" ps -eo comm
    docker rm -fv "$client_container" >/dev/null
    return "$status"
}

# configured_mac_address <service>: MAC address of the service as configured in compose.yaml
configured_mac_address() {
    "${compose[@]}" config --format json "$1" | sed -n 's/.*"mac_address": *"\([^"]*\)".*/\1/p'
}

# Client components of the full image as configured in compose.yaml
configured_client_components() {
    docker compose config --format json "$full_service" | sed -n 's/.*"ONEC_CLIENT_COMPONENTS": *"\([^"]*\)".*/\1/p'
}

# Platform versions 1C:EDT of the edt images supports as configured in compose.yaml, one per line;
# the version of the image by default
configured_edt_platform_versions() {
    local versions platform_version=${edt_image##*:}
    platform_version=${platform_version%%-*}
    versions=$(docker compose config --format json "$edt_service" | sed -n 's/.*"EDT_PLATFORM_VERSIONS": *"\([^"]*\)".*/\1/p')
    versions=${versions//[[:space:]]/}
    tr , '\n' <<<"${versions:-${platform_version%.*}}" | sort -V
}

# edt_project_builds <platform version>: as an arbitrary user, ibcmd exports an empty
# configuration to XML, 1cedtcli imports it into a project for the platform version
# and exports the project back to XML, then ibcmd loads that export into an infobase
# and saves it as a .cf; prints what came out of each step and the end of the output
# of a failed one
edt_project_builds() {
    # shellcheck disable=SC2016 # expanded inside the container
    docker run --rm --user "$arbitrary_user" "$edt_image" bash -c '
        if ibcmd infobase create --db-path=/tmp/empty >/tmp/ibcmd.log 2>&1 \
            && ibcmd infobase config export --db-path=/tmp/empty /tmp/empty-xml >>/tmp/ibcmd.log 2>&1; then
            echo "empty configuration exported"
        else
            tail -n 20 /tmp/ibcmd.log
            exit 1
        fi
        # Two runs: in one -file run the export after the import hangs past -timeout.
        # 1cedtcli exits with 0 on most errors, so its result is told by the files.
        1cedtcli -data /tmp/workspace -timeout 300 -command import --configuration-files /tmp/empty-xml \
            --project /tmp/project --version "$1" >/tmp/edt.log 2>&1
        1cedtcli -data /tmp/workspace -timeout 300 -command export --project /tmp/project \
            --configuration-files /tmp/xml >>/tmp/edt.log 2>&1
        if [[ -s /tmp/project/src/Configuration/Configuration.mdo && -s /tmp/xml/Configuration.xml ]]; then
            echo "project imported and exported"
        else
            find /tmp/project /tmp/xml -type f 2>/dev/null
            tail -n 20 /tmp/edt.log
            exit 1
        fi
        if ibcmd infobase create --db-path=/tmp/ib --import=/tmp/xml >>/tmp/ibcmd.log 2>&1 \
            && ibcmd infobase config save --db-path=/tmp/ib /tmp/smoke.cf >>/tmp/ibcmd.log 2>&1 \
            && test -s /tmp/smoke.cf; then
            echo "cf saved"
        else
            tail -n 20 /tmp/ibcmd.log
            exit 1
        fi' bash "$1"
}

# rac_lists_cluster <service>: succeeds once rac lists at least one cluster through ras
# in the service container; prints the last rac output otherwise
rac_lists_cluster() {
    local output=""
    for _ in $(seq 30); do
        if output=$("${compose[@]}" exec -T "$1" "$onec_home/rac" localhost:1545 cluster list 2>&1) \
            && grep -q '^cluster ' <<<"$output"; then
            return 0
        fi
        sleep 2
    done
    echo "$output"
    return 1
}

# ras_exit_restarts <service>: kills ras and succeeds once the restart policy has brought
# the container back healthy; prints its restart count and health otherwise
ras_exit_restarts() {
    local id state
    id=$("${compose[@]}" ps -q "$1")
    "${compose[@]}" exec -T "$1" pkill -x ras
    for _ in $(seq 60); do
        state=$(docker inspect -f '{{.RestartCount}} {{.State.Health.Status}}' "$id")
        [[ $state == "1 healthy" ]] && return 0
        sleep 2
    done
    echo "restart count and health: $state"
    return 1
}

# stop_exit_code <service>: exit code of the container after docker stop,
# 137 if it had to be killed
stop_exit_code() {
    local id
    id=$("${compose[@]}" ps -q "$1")
    docker stop "$id" >/dev/null
    docker inspect -f '{{.State.ExitCode}}' "$id"
}

# service_starts <service>: starts the service and waits until it is healthy
service_starts() {
    "${compose[@]}" up -d --no-build --wait --wait-timeout 120 "$1" >/dev/null 2>&1 && return 0
    "${compose[@]}" ps -a 2>&1
    "${compose[@]}" logs --tail 50 "$1" 2>&1
    return 1
}

# server_tests <service>: parts 1-3
server_tests() {
    local server_service=$1 image version
    image=$(docker compose config --images "$server_service")
    # The tag, which the version label repeats: 8.3.27.2342-edt-2026.1.3 for an EDT image
    version=${image##*:}
    server_image_tests
    ibsrv_tests
    infobase_source_tests
    server_service_tests
}

# Part 1
server_image_tests() {
    diag "Image $image"
    check_eq "version label is $version" "$version" \
        docker image inspect -f '{{index .Config.Labels "org.opencontainers.image.version"}}' "$image"
    check_eq "runs as usr1cv8 with fixed uid/gid" "uid=999(usr1cv8) gid=999(grp1cv8) groups=999(grp1cv8)" in_image id
    # shellcheck disable=SC2016 # expanded inside the container
    check_eq "locale is ru_RU.UTF-8" ru_RU.UTF-8 in_image bash -c 'locale -a | grep -qx ru_RU.utf8 && echo "$LANG"'
    check_eq "clients are not installed" "" \
        in_image find "$onec_home/" -maxdepth 1 \( -name 1cv8 -o -name 1cv8c -o -name 1cv8s \)
    check_eq "shared libraries of the binaries and modules are resolved" "" missing_libraries
    check_eq "Microsoft Core Fonts are installed" Arial in_image fc-match -f '%{family[0]}' Arial
    check_eq "time zone is Europe/Moscow" MSK in_image date +%Z
    check "ibcmd creates an infobase as an arbitrary user" \
        docker run --rm --user "$arbitrary_user" "$image" ibcmd infobase create --db-path=/tmp/ib
    check_contains "arguments that start with a key are passed to ragent" "-pingTimeout 30000" leading_key_runs_ragent
    check_contains "a ragent key the image sets itself is refused" ONEC_PORT image_key_refused
}

# Part 2 up to ONEC_INFOBASE_SOURCE. The checks of the ibsrv container are left out if it
# serves no infobase, since all of them would fail after that.
ibsrv_tests() {
    local status
    diag "Standalone server (ibsrv)"
    # shellcheck disable=SC2016 # expanded inside the container
    check_eq "ibsrv --help creates no infobase" "" docker run --rm --entrypoint bash "$image" -c \
        'entrypoint.sh ibsrv --help >/dev/null && find "$ONEC_SRV_DATA" -name 1Cv8.1CD'
    check_eq "ibsrv with its own infobase location keeps the settings of the image" \
        "$onec_home/ibsrv --data=/home/usr1cv8/.1cv8/1C/1cv8/standalone-server --config=/usr/local/etc/ibsrv.yml --db-path=/tmp/ib" \
        ibsrv_with_own_infobase
    check_contains "ibsrv takes a settings file of the user from the settings of the platform" \
        "port 9000 is open" ibsrv_with_own_settings
    docker run -d --name "$ibsrv_container" "$image" ibsrv --name=smoke >/dev/null
    if ! status=$(odata_status "\$metadata") || [[ $status != 200 ]]; then
        not_ok "ibsrv creates an infobase on the first start, OData \$metadata returns 200" "got: $status"
        return
    fi
    ok "ibsrv creates an infobase on the first start, OData \$metadata returns 200"
    check "the container with ibsrv becomes healthy" container_healthy "$ibsrv_container"
    check "ibsrv keeps the infobase on restart" infobase_kept_on_restart
    check "the container with ibsrv becomes healthy again after the restart" container_healthy "$ibsrv_container"
    check_eq "ibsrv stops on docker stop in time" 143 container_stop_exit_code "$ibsrv_container"
}

# Part 2, ONEC_INFOBASE_SOURCE
infobase_source_tests() {
    local output
    if ! output=$(make_seed_infobase 2>&1); then
        not_ok "an infobase to start ibsrv from is prepared" "$output"
        return
    fi
    check_contains "ibsrv takes the infobase from a .1CD file in ONEC_INFOBASE_SOURCE" '"Seed"' infobase_from seed.1CD
    check_contains "ibsrv restores the infobase from a dump under any name in ONEC_INFOBASE_SOURCE" '"Seed"' infobase_from dump
    check_eq "ibsrv refuses a missing file in ONEC_INFOBASE_SOURCE and creates no infobase" \
        $'entrypoint: ONEC_INFOBASE_SOURCE: no file /seed/missing.dt\ndata left: []' \
        infobase_source_refused missing.dt
    check_contains "ibsrv leaves no data when the dump cannot be restored" \
        $'entrypoint: ONEC_INFOBASE_SOURCE: cannot restore the infobase from /seed/truncated.dt\ndata left: []' \
        infobase_source_refused truncated.dt
    check_eq "ibsrv refuses a file that is neither a file infobase nor a dump" \
        $'entrypoint: ONEC_INFOBASE_SOURCE: /seed/garbage.dt is neither a file infobase nor a dump\ndata left: []' \
        infobase_source_refused garbage.dt
}

# Part 3
server_service_tests() {
    local output
    diag "Service $server_service ($project)"
    if ! output=$(service_starts "$server_service"); then
        not_ok "$server_service starts and is healthy" "$output"
        return
    fi
    ok "$server_service starts and is healthy"
    check_eq "$server_service has the MAC address from compose.yaml" "$(configured_mac_address "$server_service")" \
        "${compose[@]}" exec -T "$server_service" cat /sys/class/net/eth0/address
    check "rac lists the cluster through ras" rac_lists_cluster "$server_service"
    check "container restarts when ras exits" ras_exit_restarts "$server_service"
    check_eq "stops on docker stop without being killed" 143 stop_exit_code "$server_service"
}

# full_tests <service>: part 4
full_tests() {
    local full_service=$1 full_image output
    full_image=$(docker compose config --images "$full_service")
    diag "Image $full_image"
    if [[ ,$(configured_client_components), == *,client_full,* ]]; then
        check "1cv8 (thick client) is executable, client_full requested" in_full_image test -x "$onec_home/1cv8"
    else
        check "1cv8 (thick client) is not installed, client_full not requested" \
            in_full_image test ! -e "$onec_home/1cv8"
    fi
    check_eq "1cestart is in PATH" /opt/1cv8/common/1cestart in_full_image bash -c 'command -v 1cestart'
    check "ping is installed for Vanessa Automation" in_full_image ping -c 1 -W 1 127.0.0.1
    check_eq "novnc_proxy serves noVNC and the display over WebSocket" $'HTTP/1.1 200 OK\nRFB 003.008' novnc_banner
    check_eq "shared libraries of the clients, modules and 1cestart are resolved" "" missing_client_libraries
    check_eq "unused installer files are removed" "" \
        in_full_image find "$onec_home/" /opt/1cv8/common/ -maxdepth 1 \( -name ExtDst -o -name '*.wk41' \)
    check "thin client opens the infobase on a virtual display" thin_client_opens
    check "thin client opens the infobase as an arbitrary user" thin_client_opens --user "$arbitrary_user"
    check "the ibsrv command runs the standalone server with the display" ibsrv_with_display
    check "START_DISPLAY=false runs the server without the display" display_disabled
    if ! output=$(service_starts "$full_service"); then
        not_ok "$full_service service starts as the server and is healthy" "$output"
        return
    fi
    ok "$full_service service starts as the server and is healthy"
    check_eq "$full_service runs a display with a window manager, a VNC server with a password and noVNC" \
        $'1920x1080\n96x96 dpi\n24 bit\nfluxbox\n\nRFB 003.008\n1 2\nHTTP/1.1 200 OK' full_display
    check "$full_service restarts with the display when ras exits" ras_exit_restarts "$full_service"
    check_eq "the display is back after the restart" \
        $'1920x1080\n96x96 dpi\n24 bit\nfluxbox\n\nRFB 003.008\n1 2\nHTTP/1.1 200 OK' full_display
    check_eq "$full_service stops on docker stop without being killed" 143 stop_exit_code "$full_service"
}

# edt_tests <service>: part 5. full-edt sets DISPLAY like full, but 1cedtcli runs there
# without the display the entrypoint starts only for the server.
edt_tests() {
    local edt_service=$1 edt_image edt_version edt_platform_versions
    edt_image=$(docker compose config --images "$edt_service")
    edt_version=${edt_image##*-}
    diag "Image $edt_image"
    check_contains "1cedtcli in PATH runs 1C:EDT $edt_version" "$edt_version" \
        in_edt_image 1cedtcli -command version
    edt_platform_versions=$(configured_edt_platform_versions)
    check_eq "1C:EDT supports only the platform versions $(paste -sd, <<<"$edt_platform_versions")" \
        "$edt_platform_versions" in_edt_image 1cedtcli -command platform-versions
    # The export loads only into the platform it is made for or a newer one
    check_eq "1cedtcli imports an empty configuration as an arbitrary user and exports it for ibcmd to build a .cf" \
        $'empty configuration exported\nproject imported and exported\ncf saved' \
        edt_project_builds "$(head -n 1 <<<"$edt_platform_versions")"
}

cleanup() {
    docker rm -fv "$ibsrv_container" "$client_container" "$nodisplay_container" "$key_container" \
        >/dev/null 2>&1 || true
    docker volume rm "$seed_volume" >/dev/null 2>&1 || true
    "${compose[@]}" --profile '*' down -v --remove-orphans >/dev/null 2>&1 || true
}
image_built() {
    docker image inspect "$(docker compose config --images "$1")" >/dev/null 2>&1
}

# The images not built are skipped when no services are given, and refused when they are
skip_missing=false
if [[ $# -eq 0 ]]; then
    set -- server full server-edt full-edt
    skip_missing=true
fi
for service; do
    # tests/compose.test.yaml keeps only these services from publishing ports on the host
    if [[ ! $service =~ ^(server|full)(-edt)?$ ]]; then
        echo "Bail out! Unknown service $service, see tests/smoke.sh --help"
        exit 1
    fi
done
built=false
for service; do
    if image_built "$service"; then
        built=true
    elif [[ $skip_missing == false ]]; then
        echo "Bail out! Image of $service not found, run docker compose build $service first"
        exit 1
    fi
done
if [[ $built == false ]]; then
    echo "Bail out! No image is built, run docker compose build server first"
    exit 1
fi

trap cleanup EXIT
cleanup

for service; do
    if ! image_built "$service"; then
        skip "$service image tests" "image not found, run docker compose build $service"
        continue
    fi
    case $service in
        server*) server_tests "$service" ;;
        full*) full_tests "$service" ;;
    esac
    if [[ $service == *-edt ]]; then
        edt_tests "$service"
    fi
    # The containers of the next service take the same names
    cleanup
done

echo "1..$tests"
if [[ $failures -gt 0 ]]; then
    diag "$failures of $tests tests failed"
    exit 1
fi
