#!/usr/bin/env bash
# Installs 1C:EDT with its Java from the offline distribution archive in directory $1, as
# downloaded from releases.1c.ru: 1c_edt_distr_offline_<version>_<build>_linux_x86_64.tar.gz.
# EDT_ARCHIVE names another archive in the directory. Keeps the support of only the platform
# versions in EDT_PLATFORM_VERSIONS.
set -euo pipefail

die() {
    echo "install-1cedt: $*" >&2
    exit 1
}

: "${EDT_VERSION:?is required, e.g. --build-arg EDT_VERSION=2026.1.3}"
: "${ONEC_VERSION:?is required, e.g. --build-arg ONEC_VERSION=8.3.27.2342}"
# The support of each platform version takes up to 1 GB, so only the version of the image
# is kept by default
: "${EDT_PLATFORM_VERSIONS:=${ONEC_VERSION%.*}}"
EDT_PLATFORM_VERSIONS=${EDT_PLATFORM_VERSIONS//[[:space:]]/}

distr_dir=${1:-/tmp/distr}
components_dir=/opt/1C/1CE/components

# The name also carries the build number, such as _25 for 2026.1.3
wanted=${EDT_ARCHIVE:-1c_edt_distr_offline_${EDT_VERSION}_*_linux_x86_64.tar.gz}
mapfile -t archives < <(find "$distr_dir" -maxdepth 1 -type f -name "$wanted")
if [[ ${#archives[@]} -ne 1 ]]; then
    ls -la "$distr_dir" >&2
    die "expected one $wanted in $distr_dir, found ${#archives[@]}; check EDT_VERSION or set EDT_ARCHIVE"
fi
archive=${archives[0]}

echo "Installing 1C:EDT $EDT_VERSION from $(basename "$archive") (platform versions: $EDT_PLATFORM_VERSIONS)"
distr=$(mktemp -d)
tar -xzf "$archive" -C "$distr"
# The installer adds 1C:EDT Start, which it calls mandatory, but the image does not need it.
"$distr/1ce-installer-cli" install 1c-edt-product-offline --components 1c-edt,axiom-jdk-full \
    --source "$distr" --ignore-hardware-checks --ignore-signature-warnings --disable-service-creation \
    | tr '\r' '\n' | grep -v -e '% \[' -e '^\s*$'
rm -rf "$distr" "$components_dir"/1c-edt-start-* "$components_dir"/1c-enterprise-installer-*

edt_dirs=("$components_dir/1c-edt-$EDT_VERSION+"*-x86_64)
[[ -x ${edt_dirs[0]}/1cedtcli ]] \
    || die "1C:EDT $EDT_VERSION not found in $components_dir, check that EDT_VERSION matches the distribution"
edt_dir=${edt_dirs[0]}
jdk_dirs=("$components_dir"/axiom-jdk-full-*-x86_64)
java=${jdk_dirs[0]}/bin/java
[[ -x $java ]] || die "Java not found in $components_dir"

# The launcher looks for Java in the registry of the installer, which is not copied
# into the image
sed -i "/^-vmargs\$/i -vm\n$java" "$edt_dir/1cedt.ini"
ln -s "${edt_dir##*/}" "$components_dir/1c-edt"

workspace=$(mktemp -d)
platform_versions() {
    "$edt_dir/1cedtcli" -data "$workspace" -command platform-versions 2>/dev/null \
        | grep -E '^[0-9]+(\.[0-9]+)+$' | sort -V
}

IFS=, read -ra keep <<<"$EDT_PLATFORM_VERSIONS"
mapfile -t supported < <(platform_versions)
for version in "${keep[@]}"; do
    [[ " ${supported[*]} " == *" $version "* ]] \
        || die "1C:EDT $EDT_VERSION does not support platform $version, it supports ${supported[*]}"
done

# All in one run of 1cedtcli, which takes half a minute to start
for version in "${supported[@]}"; do
    if [[ ,$EDT_PLATFORM_VERSIONS, != *,$version,* ]]; then
        echo "uninstall-platform-support --version $version"
    fi
done >"$workspace/commands"
if [[ -s $workspace/commands ]]; then
    "$edt_dir/1cedtcli" -data "$workspace" -file "$workspace/commands"
    # The files of the removed versions stay until the p2 garbage collector deletes them.
    # It reports errors on exit, they do not affect the result checked below.
    "$edt_dir/1cedt" -nosplash -data "$workspace" \
        -application org.eclipse.equinox.p2.garbagecollector.application -profile DefaultProfile \
        >/dev/null 2>&1 || true
fi

left=$(platform_versions)
[[ $left == "$(printf '%s\n' "${keep[@]}" | sort -V)" ]] \
    || die "the support of other platform versions is left: $(tr '\n' ' ' <<<"$left")"
for dir in "$edt_dir"/plugins/com._1c.g5.v8.dt.natives.library.v*; do
    version=${dir##*natives.library.v}
    version=${version%%.linux_*}
    [[ ,$EDT_PLATFORM_VERSIONS, == *,$version,* ]] || die "the files of the platform $version support are left in $dir"
done
rm -rf "$workspace"
