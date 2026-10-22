# PHP 5.4.45 php2shell mitigation backport

[日本語](README.ja.md)

This repository contains an unofficial source backport of PHP's mitigations for:

- [CVE-2026-109618 / GHSA-w8hw-w9fx-j79w](https://github.com/php/php-src/security/advisories/GHSA-w8hw-w9fx-j79w): corrupted state after an out-of-memory bailout
- [CVE-2026-109619 / GHSA-6wmf-4rv5-p3rp](https://github.com/php/php-src/security/advisories/GHSA-6wmf-4rv5-p3rp): global state surviving across requests

The port starts from PHP's official [PHP 7.4 EOL mitigation commit `712e60f9`](https://github.com/php/php-src/commit/712e60f9edfd03f0960fc4fc3c2c375f42b90aa2). It was compared with the [complete fix `01a40e89`](https://github.com/php/php-src/commit/01a40e89fbfc499936e3b05888d8f00bfde886df) and adapted to the Zend Engine, SAPI, RFC1867, and session implementations in PHP 5.4.45.

PHP 5.4 has been unsupported upstream for years. This patch mitigates these two vulnerabilities; it does not bring PHP 5.4 to a current security level. Moving to a supported PHP release remains the proper long-term fix.

## Apply the patch

The release artifact is `php-5.4.45-php2shell.patch`. It applies at `-p1` to the official PHP 5.4.45 tarball:

```sh
tar xf php-5.4.45.tar.gz
cd php-5.4.45

patch -p1 < ../php-5.4.45-php2shell.patch

./configure --prefix=/opt/php54-patched
make -j$(nproc)
make test
```

New GCC releases may require `-fcommon` for PHP 5.4 itself. On a recent glibc, the old `readdir_r` configure probe may also need an override:

```sh
ac_cv_func_readdir_r=no CFLAGS=-fcommon \
  ./configure --prefix=/opt/php54-patched
```

Verify the release patch before applying it:

```sh
sha256sum -c SHA256SUMS
```

## What the patch changes

The patch changes 10 files, adding 142 lines and removing 68.

- Zend Memory Manager OOM and allocation-size overflows now print a fixed-buffer diagnostic and terminate with `_exit(1)`. They no longer enter the unsafe `longjmp` bailout path.
- PHP 5.4 handles string concatenation in `concat_function()`, so both size-overflow paths there use the same hard-exit handler.
- Request shutdown clears freed executor, SAPI, HTTP-superglobal, and linked-list pointers before another request can observe them.
- Session upload progress is disabled, matching the official EOL mitigation where a safe serializer backport is unavailable.
- Multipart parsing retains only `Content-Disposition` and `Content-Type`, and ignores duplicate headers.
- `max_multipart_body_parts` is added. Its default value of `-1` derives the limit from `max_input_vars + max_file_uploads`.

The PHP 7.4 patch also changes HashTable singleton handling and VM opcodes. Those changes do not map directly to PHP 5.4: this branch allocates a minimum bucket array and routes string concatenation through `Zend/zend_operators.c`.

## Runtime changes

- An OOM or allocation-size overflow detected by Zend Memory Manager terminates the worker immediately with exit code 1. FastCGI or a process manager should restart it. With a threaded Apache MPM, `_exit(1)` terminates the whole worker process, not only the request thread.
- `session.upload_progress.enabled=1` no longer creates upload-progress session data.
- Multipart requests now have a body-part limit. `max_multipart_body_parts=-1` selects the derived default; it does not mean unlimited.

## AddressSanitizer validation

`tests/run-asan.sh` downloads the official tarball, applies the release patch with `patch -p1`, and builds CLI, CGI, and session support with AddressSanitizer.

PowerShell:

```powershell
docker build -f Dockerfile.asan -t php54-php2shell-asan .
docker run --rm -v "${PWD}:/workspace:ro" php54-php2shell-asan bash /workspace/tests/run-asan.sh
```

POSIX shell:

```sh
docker build -f Dockerfile.asan -t php54-php2shell-asan .
docker run --rm -v "$PWD:/workspace:ro" php54-php2shell-asan bash /workspace/tests/run-asan.sh
```

Validated on 2026-10-23 with Ubuntu 22.04, GCC 11, and AddressSanitizer:

| Check | Result |
| --- | --- |
| Allocate 32 MiB under an 8 MiB limit; print the fatal error and exit 1 | PASS |
| Reject an overflowing allocation and print numeric `size_t` values | PASS |
| Alternate a fatal request and a healthy request 25 times in one server process | PASS |
| Do not persist session upload-progress data | PASS |
| Accept only two parts when `max_multipart_body_parts=2` | PASS |
| No AddressSanitizer error during the suite | PASS |

The 25-loop request-cycle check is a regression test for sanitizer errors and corrupted healthy responses. It does not distinguish the patched build from the original by itself. The OOM exit status, missing upload-progress record, and multipart limit are the discriminating checks.

## Full PHPT run

`tests/run-phpt.sh` performs a fresh minimal non-ZTS build and runs the PHP 5.4 PHPT suite:

```powershell
docker build -f Dockerfile.asan -t php54-php2shell-test .
New-Item -ItemType Directory -Force test-results | Out-Null
docker run --rm -e RESULT_DIR=/results `
  -v "${PWD}:/workspace:ro" `
  -v "${PWD}\test-results:/results" `
  php54-php2shell-test bash /workspace/tests/run-phpt.sh
```

Results from 2026-10-22:

| PHPT result | Count |
| --- | ---: |
| Total test inventory | 12,562 |
| Eligible after extension skips | 7,078 |
| Passed | 7,032 |
| Failed | 15 |
| Expected failures | 30 |
| Warned | 1 |
| Skipped | 5,484 |
| `make test` exit status | 0 |

The 15 failures are accounted for as follows:

- Eight `ext/session/tests/rfc1867*.phpt` cases expect session upload progress to be written. The mitigation intentionally disables that feature.
- `tests/lang/bug45392.phpt` expects the legacy recoverable OOM path; the mitigation hard-exits the worker.
- Six old platform-sensitive tests fail against the current container environment: two glob/open_basedir cases, three service-database lookups, and one `strptime()` case.

The warning is an old XFAIL test that now passes. The complete local run log is written to `test-results/php-5.4.45-phpt.log`; that directory is intentionally excluded from release artifacts.

## Native Windows validation

PHP's [Windows compiler table](https://wiki.php.net/internals/windows/compiler) lists Visual C++ 9 as the supported compiler for PHP 5.4. On 2026-10-23, the release patch was validated with the x86 Visual C++ 2008 SP1 compiler and linker (`15.00.30729.01` and `9.00.30729.01`), Windows SDK 6.1 (`rc.exe` 6.0.5724.0), and the official [PHP SDK binary tools from 2011-09-15](https://downloads.php.net/~windows/php-sdk/php-sdk-binary-tools-20110915.zip).

The tested build was x86, non-ZTS, with CLI and session support. With Visual C++ 2008 SP1 and Windows SDK 6.1 already installed, the equivalent build commands are:

```bat
git apply ..\php-5.4.45-php2shell.patch

call "C:\Program Files (x86)\Microsoft Visual Studio 9.0\VC\vcvarsall.bat" x86
set "WINSDK61=C:\Program Files\Microsoft SDKs\Windows\v6.1"
set "PATH=C:\php-sdk-tools\bin;%WINSDK61%\Bin;%PATH%"
set "INCLUDE=%WINSDK61%\Include;%INCLUDE%"
set "LIB=%WINSDK61%\Lib;%LIB%"
set "LIBPATH=%WINSDK61%\Lib;%LIBPATH%"
set "WindowsSdkDir=%WINSDK61%\"

call buildconf.bat
call configure.bat --disable-all --enable-cli --disable-zts --enable-session
nmake
```

No Windows-specific adjustment was applied to the release patch or the PHP build system. PHP 5.4.45's original `/version:5.4.45` linker option succeeded with the VC9 linker. `dumpbin` confirmed an x86 image, linker version 9.00, image version 5.04, and an `MSVCR90.dll` dependency.

The VC9 run found one portability defect during validation: Visual C++ 2008's CRT does not support the C99 `%zu` format. Allocation-overflow diagnostics now use `%Iu` on Windows and `%zu` elsewhere. The PHPT that exposed it, `ext/spl/tests/bug67247.phpt`, passes after the change.

`tests/run-windows-smoke.ps1` produced:

| Native Windows check | Result |
| --- | --- |
| PHP 5.4.45 CLI starts | PASS |
| OOM diagnostic and exit code 1 | PASS |
| Allocation-overflow diagnostic uses numeric `size_t` values and exits 1 | PASS |
| Fatal/healthy request cycle, 25 loops | PASS |
| Session upload-progress mitigation | PASS |
| Multipart body-parts limit | PASS |

```powershell
powershell -ExecutionPolicy Bypass -File tests\run-windows-smoke.ps1 `
  -PhpExe C:\path\to\php-5.4.45\Release\php.exe
```

The complete native Windows PHPT run covered all 12,562 tests in the source tree. Its final counts and comparison with an unmodified PHP 5.4.45 build are recorded below.

```bat
set NO_INTERACTION=1
set REPORT_EXIT_STATUS=1
set TESTS=-q
nmake test
```

| Native Windows PHPT result | Count |
| --- | ---: |
| Total test inventory | 12,562 |
| Executed after skips | 6,826 |
| Passed | 6,753 |
| Failed | 43 |
| Expected failures | 29 |
| Warned | 1 |
| Skipped | 5,736 |
| Time | 1,281 seconds |
| `nmake test` exit status with `REPORT_EXIT_STATUS=1` | 1 |

All 43 failures were accounted for. A targeted run against an unmodified PHP 5.4.45 build made with the same VC9 toolchain reproduced 41. `tests/lang/bug45392.phpt` expects recovery after an OOM, while the mitigation deliberately terminates the worker. `tests/func/005a.phpt` is timing-sensitive under the PHPT wrapper; direct execution printed both expected lines on patched and unmodified builds. The VC9-specific regression test `ext/spl/tests/bug67247.phpt` passes.

ZTS, Apache module, and x64 builds remain untested. A separate earlier VC11 check required `tests/windows-vc11-link-version.patch` because that newer linker rejects PHP 5.4.45's three-component image version. That compatibility helper is not part of the release patch.

## Integrity

`SHA256SUMS` records the SHA-256 digest of the release patch:

```text
31927aaacb5d1158d6461bdeb8360ec3a4eb48c2ffa3bf69b751ddb0a0bd713c  php-5.4.45-php2shell.patch
```
