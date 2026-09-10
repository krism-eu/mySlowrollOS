#!/usr/bin/env bash
set -euo pipefail

stage="${1:-stage0}"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd -- "${script_dir}/../.." && pwd)"
seed_file="${script_dir}/${stage}.seed"

if [[ ! -f "${seed_file}" ]]; then
    printf 'Seed file not found: %s\n' "${seed_file}" >&2
    exit 2
fi

runtime_cmd=()
if command -v podman >/dev/null 2>&1; then
    if [[ "${MYSLOWROLL_ROOTFUL:-0}" == 1 ]]; then
        runtime_cmd=(sudo podman)
    else
        runtime_cmd=(podman)
    fi
elif command -v docker >/dev/null 2>&1; then
    runtime_cmd=(docker)
else
    printf 'Podman or Docker is required.\n' >&2
    exit 2
fi

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
run_dir="${repo_dir}/out/${stage}-${stamp}"
rootfs_dir="${run_dir}/rootfs"
report_dir="${run_dir}/report"
mkdir -p "${rootfs_dir}" "${report_dir}"

tool_image="registry.opensuse.org/opensuse/tumbleweed:latest"

printf 'Runtime: %s\nTarget:  %s\n' "${runtime_cmd[*]}" "${run_dir}"

"${runtime_cmd[@]}" run --rm \
    --mount "type=bind,src=${rootfs_dir},dst=/target" \
    --mount "type=bind,src=${report_dir},dst=/report" \
    --mount "type=bind,src=${seed_file},dst=/input/seed,readonly" \
    "${tool_image}" bash -euxo pipefail -c '
        mapfile -t seeds < <(sed -E "/^[[:space:]]*(#|$)/d; s/[[:space:]]+$//" /input/seed)
        printf "%s\n" "${seeds[@]}" > /report/seeds.txt

        mkdir -p /target/etc/zypp/repos.d
        zypper --root /target --non-interactive addrepo \
            --refresh https://download.opensuse.org/slowroll/repo/oss/ slowroll-oss
        zypper --root /target --non-interactive addrepo \
            --refresh https://download.opensuse.org/update/slowroll/repo/oss/ slowroll-update
        zypper --root /target --non-interactive --gpg-auto-import-keys refresh

        zypper --root /target --non-interactive --gpg-auto-import-keys \
            install --no-recommends "${seeds[@]}"

        rpm --root /target -qa \
            --qf "%{NAME}\t%{EPOCHNUM}:%{VERSION}-%{RELEASE}\t%{ARCH}\t%{INSTALLSIZE}\n" \
            | sort > /report/installed.tsv
        cut -f1 /report/installed.tsv > /report/installed.names

        zypper --root /target --non-interactive packages --installed-only \
            > /report/zypper-installed.txt
        zypper --root /target --non-interactive packages --unneeded \
            > /report/unneeded.txt || true

        package_count="$(wc -l < /report/installed.names)"
        installed_bytes="$(awk -F "\t" "{ total += \\$4 } END { print total + 0 }" /report/installed.tsv)"
        rootfs_bytes="$(du -sx -B1 /target | cut -f1)"
        {
            printf "stage=%s\n" "'"${stage}"'"
            printf "packages=%s\n" "${package_count}"
            printf "rpm_install_bytes=%s\n" "${installed_bytes}"
            printf "rootfs_bytes=%s\n" "${rootfs_bytes}"
        } > /report/summary.txt
    '

printf '\nCompleted. Reports: %s\n' "${report_dir}"
