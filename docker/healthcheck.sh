#!/usr/bin/env bash
# Container health check: the server the entrypoint was told to start is ready.
# A container that runs any other command is healthy.
set -euo pipefail

# The command of the container follows "tini -- entrypoint.sh" in the arguments of PID 1
mapfile -d '' -t args </proc/1/cmdline
cmd=
if [[ ${args[2]:-} == */entrypoint.sh ]]; then
    cmd=${args[3]:-ragent}
fi

case "$cmd" in
    ragent | -*)
        (exec 3<>"/dev/tcp/127.0.0.1/${ONEC_PORT:-1540}")
        (exec 3<>"/dev/tcp/127.0.0.1/${ONEC_RAS_PORT:-1545}")
        ;;
    ras)
        (exec 3<>"/dev/tcp/127.0.0.1/${ONEC_RAS_PORT:-1545}")
        ;;
    ibsrv)
        # ibsrv listens long before it is ready, so the entrypoint leaves this file
        # when ibsrv reports that it is
        [[ -e /dev/shm/ibsrv-ready ]]
        pgrep -x ibsrv >/dev/null
        ;;
esac
