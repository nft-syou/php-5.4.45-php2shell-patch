#!/usr/bin/env bash
set -euo pipefail

BUILD_DIR=${BUILD_DIR:-/tmp/php-5.4.45-asan}
FIXTURE_DIR=${FIXTURE_DIR:-/workspace/tests/fixtures}
JOBS=${JOBS:-2}
PHP_ARCHIVE_URL=${PHP_ARCHIVE_URL:-https://museum.php.net/php5/php-5.4.45.tar.gz}
PATCH_FILE=${PATCH_FILE:-/workspace/php-5.4.45-php2shell.patch}
SOURCE_ARCHIVE=${SOURCE_ARCHIVE:-}

rm -rf "${BUILD_DIR}" /tmp/php-5.4.45 /tmp/php54-sessions
if [[ -n "${SOURCE_ARCHIVE}" ]]; then
    tar -xzf "${SOURCE_ARCHIVE}" -C /tmp
    test -f /tmp/php-5.4.45/PHP2SHELL-MITIGATION-NOTICE.txt
    test -f /tmp/php-5.4.45/PHP2SHELL-MITIGATION.patch
else
    curl -fsSL "${PHP_ARCHIVE_URL}" -o /tmp/php-5.4.45.tar.gz
    tar -xzf /tmp/php-5.4.45.tar.gz -C /tmp
    patch --batch --forward --directory=/tmp/php-5.4.45 -p1 <"${PATCH_FILE}"
fi
mv /tmp/php-5.4.45 "${BUILD_DIR}"
cd "${BUILD_DIR}"

ac_cv_func_readdir_r=no \
CFLAGS='-O1 -g -fno-omit-frame-pointer -fsanitize=address -fcommon' \
LDFLAGS='-fsanitize=address' \
    ./configure --disable-all --enable-cli --enable-cgi --enable-session
make -j"${JOBS}"

PHP_BIN="${BUILD_DIR}/sapi/cli/php"
ASAN_OPTIONS='detect_leaks=0:abort_on_error=1:halt_on_error=1'
export ASAN_OPTIONS

"${PHP_BIN}" -n -v

set +e
oom_output=$("${PHP_BIN}" -n -d memory_limit=8M \
    -r '$value = str_repeat("A", 32 * 1024 * 1024);' 2>&1)
oom_status=$?
set -e
printf '%s\n' "${oom_output}"

if [[ ${oom_status} -ne 1 ]]; then
    echo "OOM test: expected exit status 1, got ${oom_status}" >&2
    exit 1
fi
if ! grep -q 'Allowed memory size' <<<"${oom_output}"; then
    echo 'OOM test: fatal allocation message was not emitted' >&2
    exit 1
fi
if grep -q 'ERROR: AddressSanitizer' <<<"${oom_output}"; then
    echo 'OOM test: AddressSanitizer reported memory corruption' >&2
    exit 1
fi
echo 'OOM hard-exit test: PASS'

set +e
overflow_output=$("${PHP_BIN}" -n "${FIXTURE_DIR}/allocation-overflow.php" 2>&1)
overflow_status=$?
set -e
printf '%s\n' "${overflow_output}"

if [[ ${overflow_status} -ne 1 ]]; then
    echo "Allocation-overflow test: expected exit status 1, got ${overflow_status}" >&2
    exit 1
fi
if ! grep -Eq 'Possible integer overflow in memory allocation \([0-9]+ \* [0-9]+ \+ [0-9]+\)' <<<"${overflow_output}"; then
    echo 'Allocation-overflow test: numeric size_t values were not emitted' >&2
    exit 1
fi
if grep -q 'ERROR: AddressSanitizer' <<<"${overflow_output}"; then
    echo 'Allocation-overflow test: AddressSanitizer reported memory corruption' >&2
    exit 1
fi
echo 'Allocation-overflow hard-exit test: PASS'

mkdir -p /tmp/php54-sessions
server_log=/tmp/php54-server.log
"${PHP_BIN}" -n \
    -d session.save_path=/tmp/php54-sessions \
    -d session.upload_progress.enabled=1 \
    -d session.upload_progress.cleanup=0 \
    -d max_multipart_body_parts=2 \
    -S 127.0.0.1:18080 -t "${FIXTURE_DIR}" >"${server_log}" 2>&1 &
server_pid=$!
trap 'kill "${server_pid}" 2>/dev/null || true' EXIT

for unused in $(seq 1 50); do
    if curl -fsS http://127.0.0.1:18080/health.php >/dev/null 2>&1; then
        break
    fi
    sleep 0.1
done
curl -fsS http://127.0.0.1:18080/health.php | grep -qx 'ok'

for request_number in $(seq 1 25); do
    curl -sS "http://127.0.0.1:18080/fatal.php?n=${request_number}" >/dev/null
    curl -fsS http://127.0.0.1:18080/health.php | grep -qx 'ok'
done

upload_file=/tmp/php54-upload.txt
printf 'upload progress must stay disabled\n' >"${upload_file}"
curl -fsS -b 'PHPSESSID=php2shelltest' \
    -F 'PHP_SESSION_UPLOAD_PROGRESS=probe' \
    -F "payload=@${upload_file}" \
    http://127.0.0.1:18080/sink.php | grep -qx '2'
curl -fsS 'http://127.0.0.1:18080/probe.php?id=php2shelltest' | grep -qx 'clean'

multipart_count=$(curl -fsS \
    -F 'a=1' -F 'b=2' -F 'c=3' \
    http://127.0.0.1:18080/sink.php)
if [[ ${multipart_count} != 2 ]]; then
    echo "multipart limit test: expected 2 accepted parts, got ${multipart_count}" >&2
    exit 1
fi

kill "${server_pid}"
wait "${server_pid}" || true
trap - EXIT

cat "${server_log}"
if grep -q 'ERROR: AddressSanitizer' "${server_log}"; then
    echo 'request-cycle test: AddressSanitizer reported memory corruption' >&2
    exit 1
fi
echo 'Cross-request request-cycle regression test: PASS'
echo 'Session upload-progress mitigation test: PASS'
echo 'Multipart body-parts limit test: PASS'
