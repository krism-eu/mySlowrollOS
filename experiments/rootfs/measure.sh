#!/usr/bin/env bash
set -euo pipefail

if (( $# > 0 )); then
    run_name="$1"
    shift
else
    run_name=stage0
fi

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd -- "${script_dir}/../.." && pwd)"

if (( $# == 0 )); then
    layer_names=("${run_name}")
else
    layer_names=("$@")
fi

seed_files=()
for layer in "${layer_names[@]}"; do
    seed_file="${script_dir}/${layer}.seed"
    if [[ ! -f "${seed_file}" ]]; then
        printf 'Seed file not found: %s\n' "${seed_file}" >&2
        exit 2
    fi
    seed_files+=("${seed_file}")
done

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

mode="${MYSLOWROLL_MODE:-install}"
if [[ "${mode}" != install && "${mode}" != resolve ]]; then
    printf 'MYSLOWROLL_MODE must be install or resolve.\n' >&2
    exit 2
fi

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
run_dir="${repo_dir}/out/${run_name}-${stamp}"
rootfs_dir="${run_dir}/rootfs"
report_dir="${run_dir}/report"
merged_seed="${run_dir}/requested.seed"
mkdir -p "${rootfs_dir}" "${report_dir}"
: > "${merged_seed}"

for seed_file in "${seed_files[@]}"; do
    sed -E '/^[[:space:]]*(#|$)/d; s/[[:space:]]+$//' "${seed_file}" >> "${merged_seed}"
done
LC_ALL=C sort -u -o "${merged_seed}" "${merged_seed}"

# If protected is one of the requested layers, verify that it is only a
# protection subset. It must never smuggle packages into system + plasma.
protected_audit=0
protected_list="${run_dir}/protected.requested"
profile_seed="${run_dir}/requested-without-protected.seed"
: > "${profile_seed}"
for i in "${!layer_names[@]}"; do
    if [[ "${layer_names[i]}" == protected ]]; then
        protected_audit=1
        continue
    fi
    sed -E '/^[[:space:]]*(#|$)/d; s/[[:space:]]+$//' \
        "${seed_files[i]}" >> "${profile_seed}"
done
LC_ALL=C sort -u -o "${profile_seed}" "${profile_seed}"

if (( protected_audit )); then
    sed -E '/^[[:space:]]*(#|$)/d; s/[[:space:]]+$//' \
        "${script_dir}/protected.seed" | LC_ALL=C sort -u > "${protected_list}"
    LC_ALL=C comm -23 "${protected_list}" "${profile_seed}" \
        > "${report_dir}/protected-not-in-profile.names"
    if [[ -s "${report_dir}/protected-not-in-profile.names" ]]; then
        printf 'Protected packages missing from system + plasma:\n' >&2
        sed 's/^/  /' "${report_dir}/protected-not-in-profile.names" >&2
        exit 3
    fi
fi

tool_image="registry.opensuse.org/opensuse/tumbleweed:latest"

printf 'Runtime: %s\nMode:    %s\nTarget:  %s\nLayers:  %s\n' \
    "${runtime_cmd[*]}" "${mode}" "${run_dir}" "${layer_names[*]}"

"${runtime_cmd[@]}" run --rm \
    --mount "type=bind,src=${rootfs_dir},dst=/target" \
    --mount "type=bind,src=${report_dir},dst=/report" \
    --mount "type=bind,src=${merged_seed},dst=/input/seed,readonly" \
    --env "MYSLOWROLL_MODE=${mode}" \
    "${tool_image}" bash -euxo pipefail -c '
        mapfile -t seeds < /input/seed
        printf "%s\n" "${seeds[@]}" > /report/seeds.txt

        mkdir -p /target/etc/zypp/repos.d
        zypper --root /target --non-interactive addrepo \
            --refresh https://download.opensuse.org/slowroll/repo/oss/ slowroll-oss
        zypper --root /target --non-interactive addrepo \
            --refresh https://download.opensuse.org/update/slowroll/repo/oss/ slowroll-update
        zypper --root /target --non-interactive --gpg-auto-import-keys refresh

        if [[ "${MYSLOWROLL_MODE}" == resolve ]]; then
            zypper --root /target --non-interactive --gpg-auto-import-keys --xmlout \
                install --dry-run --no-recommends "${seeds[@]}" \
                > /report/solver.xml

            # Zypper XML uses kind="package" on solvable elements. Validate the
            # expected transaction summary first so a format change cannot be
            # mistaken for an empty solver result.
            if ! grep -Eq "<install-summary([[:space:]>])" /report/solver.xml; then
                printf "Solver XML missing install-summary.\n" >&2
                exit 5
            fi

            if ! awk '\''
                /<solvable[[:space:]][^>]*kind="package"/ {
                    if (match($0, /name="[^"]+"/)) {
                        print substr($0, RSTART + 6, RLENGTH - 7)
                    } else {
                        bad = 1
                    }
                }
                END { exit bad ? 1 : 0 }
            '\'' /report/solver.xml | LC_ALL=C sort -u > /report/resolved.names; then
                printf "Cannot parse package names from solver XML.\n" >&2
                exit 5
            fi

            if [[ ! -s /report/resolved.names ]]; then
                printf "Solver XML contained no package names for a non-empty request.\n" >&2
                exit 5
            fi

            grep -o "<install-summary[^>]*>" /report/solver.xml \
                > /report/transaction-summary.xml
            package_count="$(wc -l < /report/resolved.names)"
            {
                printf "stage=%s\n" "'"${run_name}"'"
                printf "layers=%s\n" "'"${layer_names[*]}"'"
                printf "mode=resolve\n"
                printf "packages=%s\n" "${package_count}"
            } > /report/summary.txt
            exit 0
        fi

        zypper --root /target --non-interactive --gpg-auto-import-keys \
            install --no-recommends "${seeds[@]}"

        rpm --root /target -qa \
            --qf "%{NAME}\t%{EPOCHNUM}:%{VERSION}-%{RELEASE}\t%{ARCH}\t%{SIZE}\n" \
            | sort > /report/installed.tsv
        cut -f1 /report/installed.tsv > /report/installed.names

        zypper --root /target --non-interactive packages --installed-only \
            > /report/zypper-installed.txt
        zypper --root /target --non-interactive packages --unneeded \
            > /report/unneeded.txt || true

        package_count="$(wc -l < /report/installed.names)"
        rootfs_bytes="$(du -sx -B1 /target | cut -f1)"
        {
            printf "stage=%s\n" "'"${run_name}"'"
            printf "layers=%s\n" "'"${layer_names[*]}"'"
            printf "mode=install\n"
            printf "packages=%s\n" "${package_count}"
            printf "rootfs_bytes=%s\n" "${rootfs_bytes}"
        } > /report/summary.txt
    '

if (( protected_audit )); then
    if [[ "${mode}" == resolve ]]; then
        result_names="${report_dir}/resolved.names"
    else
        result_names="${report_dir}/installed.names"
    fi

    LC_ALL=C comm -23 "${protected_list}" "${result_names}" \
        > "${report_dir}/protected-missing-from-result.names"
    if [[ -s "${report_dir}/protected-missing-from-result.names" ]]; then
        printf 'Protected packages missing from solver result:\n' >&2
        sed 's/^/  /' "${report_dir}/protected-missing-from-result.names" >&2
        exit 4
    fi

    {
        printf 'protected=%s\n' "$(wc -l < "${protected_list}")"
        printf 'missing_from_profile=0\n'
        printf 'missing_from_result=0\n'
    } > "${report_dir}/protected-summary.txt"
fi

printf '\nCompleted. Reports: %s\n' "${report_dir}"
