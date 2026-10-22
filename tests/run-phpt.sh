#!/usr/bin/env bash
set -euo pipefail

BUILD_DIR=${BUILD_DIR:-/tmp/php-5.4.45-phpt}
RESULT_DIR=${RESULT_DIR:-/tmp}
JOBS=${JOBS:-2}
PHP_ARCHIVE_URL=${PHP_ARCHIVE_URL:-https://museum.php.net/php5/php-5.4.45.tar.gz}
PATCH_FILE=${PATCH_FILE:-/workspace/php-5.4.45-php2shell.patch}
TEST_LOG=${TEST_LOG:-${RESULT_DIR}/php-5.4.45-phpt.log}

rm -rf "${BUILD_DIR}" /tmp/php-5.4.45
mkdir -p "${RESULT_DIR}"
curl -fsSL "${PHP_ARCHIVE_URL}" -o /tmp/php-5.4.45.tar.gz
tar -xzf /tmp/php-5.4.45.tar.gz -C /tmp
mv /tmp/php-5.4.45 "${BUILD_DIR}"
cd "${BUILD_DIR}"
patch -p1 <"${PATCH_FILE}"

ac_cv_func_readdir_r=no \
CFLAGS='-O2 -fcommon' \
    ./configure --disable-all --enable-cli --enable-cgi --enable-session
make -j"${JOBS}"

set +e
NO_INTERACTION=1 REPORT_EXIT_STATUS=1 \
    make test TESTS='-q' 2>&1 | tee "${TEST_LOG}"
test_status=${PIPESTATUS[0]}
set -e

echo "PHPT log: ${TEST_LOG}"
echo "PHPT make test exit status: ${test_status}"
exit "${test_status}"
