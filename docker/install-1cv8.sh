#!/usr/bin/env bash
# Installs the 1C:Enterprise platform with the *.run installer from directory $1.
# The directory must contain exactly one *.run file.
set -euo pipefail

die() {
    echo "install-1cv8: $*" >&2
    exit 1
}

: "${ONEC_VERSION:?is required, e.g. --build-arg ONEC_VERSION=8.3.25.1633}"
: "${ONEC_COMPONENTS:=server,ws}"
ONEC_COMPONENTS=${ONEC_COMPONENTS//[[:space:]]/}

distr_dir=${1:-/tmp/distr}

mapfile -t installers < <(find "$distr_dir" -maxdepth 1 -type f -name '*.run')
if [[ ${#installers[@]} -ne 1 ]]; then
    ls -la "$distr_dir" >&2
    die "expected exactly one *.run installer in $distr_dir, found ${#installers[@]}"
fi
installer=${installers[0]}

echo "Installing 1C:Enterprise $ONEC_VERSION from $(basename "$installer") (components: $ONEC_COMPONENTS)"
[[ -x $installer ]] || chmod +x "$installer"

# The installer enables client_full by default and --enable-components only adds
# to the defaults, so it is disabled explicitly unless requested
disabled=()
if [[ ,$ONEC_COMPONENTS, != *,client_full,* ]]; then
    disabled=(--disable-components client_full)
fi
"$installer" --mode unattended --enable-components "$ONEC_COMPONENTS" "${disabled[@]}"

# A key binary of each requested component must be installed for ONEC_VERSION
IFS=, read -ra components <<<"$ONEC_COMPONENTS"
for component in "${components[@]}"; do
    case $component in
        server) binary=ragent ;;
        server_admin) binary=ras ;;
        config_storage_server) binary=crserver ;;
        client_full) binary=1cv8 ;;
        client_thin | client_thin_fib) binary=1cv8c ;;
        *) continue ;;
    esac
    [[ -x /opt/1cv8/x86_64/$ONEC_VERSION/$binary ]] \
        || die "/opt/1cv8/x86_64/$ONEC_VERSION/$binary not found, check that ONEC_VERSION matches the installer version"
done
