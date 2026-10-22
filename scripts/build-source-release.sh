#!/usr/bin/env bash
set -euo pipefail

readonly PHP_VERSION="5.4.45"
readonly UPSTREAM_URL="https://museum.php.net/php5/php-${PHP_VERSION}.tar.gz"
readonly UPSTREAM_SHA256="25bc4723955f4e352935258002af14a14a9810b491a19400d76fcdfa9d04b28f"
readonly PATCH_SHA256="31927aaacb5d1158d6461bdeb8360ec3a4eb48c2ffa3bf69b751ddb0a0bd713c"
readonly SOURCE_DATE_EPOCH="1441233720"
readonly ARCHIVE_NAME="php2shell-mitigation-for-php-${PHP_VERSION}-source.tar.gz"

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output_dir="${1:-${repo_dir}/dist}"
patch_file="${repo_dir}/php-5.4.45-php2shell.patch"
notice_file="${repo_dir}/release/PHP2SHELL-MITIGATION-NOTICE.txt"
work_dir="$(mktemp -d)"

mkdir -p "${output_dir}"
output_dir="$(cd "${output_dir}" && pwd)"

cleanup() {
    rm -rf "${work_dir}"
}
trap cleanup EXIT

for command in curl gzip patch sha256sum tar; do
    command -v "${command}" >/dev/null 2>&1 || {
        echo "Required command not found: ${command}" >&2
        exit 1
    }
done

printf '%s  %s\n' "${PATCH_SHA256}" "${patch_file}" | sha256sum --check --status

upstream_tarball="${work_dir}/php-${PHP_VERSION}.tar.gz"
if [[ -n "${UPSTREAM_TARBALL:-}" ]]; then
    cp "${UPSTREAM_TARBALL}" "${upstream_tarball}"
else
    curl --fail --location --silent --show-error \
        --output "${upstream_tarball}" "${UPSTREAM_URL}"
fi

printf '%s  %s\n' "${UPSTREAM_SHA256}" "${upstream_tarball}" | sha256sum --check --status

tar -xzf "${upstream_tarball}" -C "${work_dir}"
source_dir="${work_dir}/php-${PHP_VERSION}"
patch --batch --forward --directory="${source_dir}" -p1 < "${patch_file}"

cp "${patch_file}" "${source_dir}/PHP2SHELL-MITIGATION.patch"
cp "${notice_file}" "${source_dir}/PHP2SHELL-MITIGATION-NOTICE.txt"

rm -f "${output_dir}/${ARCHIVE_NAME}" \
      "${output_dir}/php-5.4.45-php2shell.patch" \
      "${output_dir}/SHA256SUMS"

(
    cd "${work_dir}"
    tar --sort=name \
        --format=gnu \
        --mtime="@${SOURCE_DATE_EPOCH}" \
        --owner=0 \
        --group=0 \
        --numeric-owner \
        --mode='u+rwX,go+rX,go-w' \
        -cf - "php-${PHP_VERSION}" | gzip -n -9 > "${output_dir}/${ARCHIVE_NAME}"
)

cp "${patch_file}" "${output_dir}/php-5.4.45-php2shell.patch"
(
    cd "${output_dir}"
    sha256sum "${ARCHIVE_NAME}" "php-5.4.45-php2shell.patch" > SHA256SUMS
)

verify_dir="${work_dir}/verify"
mkdir -p "${verify_dir}"
tar -xzf "${output_dir}/${ARCHIVE_NAME}" -C "${verify_dir}"
printf '%s  %s\n' \
    "${PATCH_SHA256}" \
    "${verify_dir}/php-${PHP_VERSION}/PHP2SHELL-MITIGATION.patch" | \
    sha256sum --check --status
patch --batch --dry-run --reverse --directory="${verify_dir}/php-${PHP_VERSION}" \
    -p1 < "${patch_file}" >/dev/null

cat "${output_dir}/SHA256SUMS"
