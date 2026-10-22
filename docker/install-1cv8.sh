#!/usr/bin/env bash
# Installs the 1C:Enterprise platform from its distribution archive in directory $1, as
# downloaded from releases.1c.ru: server64_<version>.zip or .tar.gz with one *.run installer.
# ONEC_ARCHIVE names another archive in the directory.
set -euo pipefail

die() {
    echo "install-1cv8: $*" >&2
    exit 1
}

: "${ONEC_VERSION:?is required, e.g. --build-arg ONEC_VERSION=8.3.27.2342}"
: "${ONEC_COMPONENTS:=server,ws}"
ONEC_COMPONENTS=${ONEC_COMPONENTS//[[:space:]]/}

distr_dir=${1:-/tmp/distr}

if [[ -n ${ONEC_ARCHIVE:-} ]]; then
    archive=$distr_dir/$ONEC_ARCHIVE
    wanted=$ONEC_ARCHIVE
else
    # Depending on the version the archive is a .zip or a .tar.gz
    archive=$distr_dir/server64_${ONEC_VERSION//./_}.zip
    wanted="$(basename "$archive") or .tar.gz"
    [[ -f $archive ]] || archive=${archive%.zip}.tar.gz
fi
if [[ ! -f $archive ]]; then
    ls -la "$distr_dir" >&2
    die "no $wanted in $distr_dir, check ONEC_VERSION or set ONEC_ARCHIVE"
fi

# The installer is taken by its extension rather than by its name, setup-full-<version>-<arch>.run,
# so a renamed one still works; its version is checked after the installation.
installer_dir=$(mktemp -d)
case $archive in
    *.zip) unzip -q "$archive" '*.run' -d "$installer_dir" || true ;;
    *.tar.gz) tar -xzf "$archive" -C "$installer_dir" --wildcards '*.run' || true ;;
    *) die "$(basename "$archive") is neither a .zip nor a .tar.gz archive" ;;
esac
mapfile -t installers < <(find "$installer_dir" -type f -name '*.run')
if [[ ${#installers[@]} -ne 1 ]]; then
    die "expected exactly one *.run installer in $(basename "$archive"), found ${#installers[@]}" \
        "${installers[@]##*/}"
fi
installer=${installers[0]}

echo "Installing 1C:Enterprise $ONEC_VERSION from $(basename "$archive"), $(basename "$installer") (components: $ONEC_COMPONENTS)"
chmod +x "$installer"

# The installer enables client_full by default and --enable-components only adds
# to the defaults, so it is disabled explicitly unless requested
disabled=()
if [[ ,$ONEC_COMPONENTS, != *,client_full,* ]]; then
    disabled=(--disable-components client_full)
fi
"$installer" --mode unattended --enable-components "$ONEC_COMPONENTS" "${disabled[@]}"
rm -rf "$installer_dir"

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
