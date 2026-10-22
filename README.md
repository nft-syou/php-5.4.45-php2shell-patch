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

The patch changes 10 files, adding 133 lines and removing 68.

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

Validated on 2026-10-22 with Ubuntu 22.04, GCC 11, and AddressSanitizer:

| Check | Result |
| --- | --- |
| Allocate 32 MiB under an 8 MiB limit; print the fatal error and exit 1 | PASS |
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

PHP's [Windows compiler table](https://wiki.php.net/internals/windows/compiler) lists Visual C++ 9 as officially supported for PHP 5.4 and Visual C++ 11 as known to work. Native validation used the Microsoft Visual C++ 2012 RTM x86 compiler (`cl.exe` 17.00.50727.1), linker, CRT, and Windows SDK 8.0 from the official Visual Studio Express 2012 for Windows Desktop offline media.

The build used the official [PHP SDK binary tools from 2011-09-15](https://downloads.php.net/~windows/php-sdk/php-sdk-binary-tools-20110915.zip), an x86 non-ZTS configuration, CLI, and session support:

```bat
git apply ..\php-5.4.45-php2shell.patch
git apply ..\tests\windows-vc11-link-version.patch

set PATH=C:\php-sdk-tools\bin;%PATH%
call "C:\Program Files (x86)\Microsoft Visual Studio 11.0\VC\vcvarsall.bat" x86

call buildconf.bat
call configure.bat --disable-all --enable-cli --disable-zts --enable-session
nmake
```

PHP 5.4.45's original Windows build rule passes `/version:5.4.45` to `link.exe`, although the linker accepts a two-component image version. The separate test-only `tests/windows-vc11-link-version.patch` changes that flag to `/version:5.4`; it does not modify PHP runtime code and is not included in the release security patch.

All patched runtime sources compiled, and `php5.dll` and `php.exe` linked successfully. `tests/run-windows-smoke.ps1` then produced:

| Native Windows check | Result |
| --- | --- |
| PHP 5.4.45 CLI starts | PASS |
| OOM diagnostic and exit code 1 | PASS |
| Fatal/healthy request cycle, 25 loops | PASS |
| Session upload-progress mitigation | PASS |
| Multipart body-parts limit | PASS |

```powershell
powershell -ExecutionPolicy Bypass -File tests\run-windows-smoke.ps1 `
  -PhpExe C:\path\to\php-5.4.45\Release\php.exe
```

This validates the non-ZTS x86 paths with a compiler listed as known to work for PHP 5.4. ZTS, Apache module builds, x64, and the officially supported VC9 toolchain remain untested.

## Integrity

`SHA256SUMS` records the SHA-256 digest of the release patch:

```text
afa262fd41cd2f7cb7f0842f4d936924412456609270b0a5d4864f7c0c656a0f  php-5.4.45-php2shell.patch
```
