# PHP 5.4.45 php2shell 緩和策バックポート

[English](README.md)

このリポジトリは、次の脆弱性に対する PHP 公式の緩和策を PHP 5.4.45 へ移植した非公式パッチです。

- [CVE-2026-109618 / GHSA-w8hw-w9fx-j79w](https://github.com/php/php-src/security/advisories/GHSA-w8hw-w9fx-j79w): OOM bailout 後の状態破損
- [CVE-2026-109619 / GHSA-6wmf-4rv5-p3rp](https://github.com/php/php-src/security/advisories/GHSA-6wmf-4rv5-p3rp): リクエストをまたいで残存するグローバル状態

移植元は PHP 公式の [PHP 7.4 EOL 向け修正 `712e60f9`](https://github.com/php/php-src/commit/712e60f9edfd03f0960fc4fc3c2c375f42b90aa2) です。[完全な修正 `01a40e89`](https://github.com/php/php-src/commit/01a40e89fbfc499936e3b05888d8f00bfde886df) と PHP 5.4.45 の Zend Engine、SAPI、RFC1867、session 実装を比較し、PHP 5.4 に存在する経路へ合わせています。

PHP 5.4 は upstream のサポート終了版です。このパッチは 2 件の脆弱性を緩和しますが、PHP 5.4 全体を現在のセキュリティ水準に更新するものではありません。長期的にはサポート中の PHP へ移行してください。

## パッチの適用

配布物は `php-5.4.45-php2shell.patch` です。公式 PHP 5.4.45 tarball のトップディレクトリから `-p1` で適用できます。

```sh
tar xf php-5.4.45.tar.gz
cd php-5.4.45

patch -p1 < ../php-5.4.45-php2shell.patch

./configure --prefix=/opt/php54-patched
make -j$(nproc)
make test
```

新しい GCC では PHP 5.4 自体の互換性のため `-fcommon` が必要になる場合があります。新しい glibc で古い `readdir_r` の configure 判定に失敗する場合は、次のように指定できます。

```sh
ac_cv_func_readdir_r=no CFLAGS=-fcommon \
  ./configure --prefix=/opt/php54-patched
```

適用前に配布パッチを検証できます。

```sh
sha256sum -c SHA256SUMS
```

## 修正内容

パッチは 10 ファイルを変更し、133 行追加、68 行削除です。

- Zend Memory Manager の OOM と割り当てサイズのオーバーフローでは、固定長バッファの診断を出して `_exit(1)` で終了します。危険な `longjmp` bailout には入りません。
- PHP 5.4 の文字列結合は `concat_function()` に集約されているため、その 2 つのサイズオーバーフロー経路も同じ終了処理へ変更します。
- executor、SAPI、HTTP superglobal、linked-list の解放済みポインタをリクエスト終了時に `NULL` へ戻します。
- PHP 5.4 には安全な serializer 基盤がないため、公式 EOL 緩和策と同じく session upload progress を無効化します。
- multipart の保存対象ヘッダーを `Content-Disposition` と `Content-Type` に限定し、重複ヘッダーを無視します。
- `max_multipart_body_parts` を追加します。既定値 `-1` では `max_input_vars + max_file_uploads` から上限を算出します。

PHP 7.4 の修正に含まれる HashTable singleton と VM opcode の変更は、PHP 5.4 の構造へそのまま対応しません。PHP 5.4 は最小バケット配列を確保し、文字列結合を `Zend/zend_operators.c` で処理するため、それぞれ対応する経路へ置き換えています。

## 動作上の変更

- Zend Memory Manager が OOM または割り当てサイズのオーバーフローを検出すると、worker は終了コード 1 で直ちに終了します。FastCGI または process manager が worker を再起動できる構成にしてください。スレッド型 Apache MPM の mod_php では、`_exit(1)` がリクエスト thread だけでなく worker process 全体を終了します。
- `session.upload_progress.enabled=1` を指定しても upload progress は保存されません。
- multipart request に body-part 上限が導入されます。`max_multipart_body_parts=-1` は無制限ではなく、算出された既定値を意味します。

## AddressSanitizer 検証

`tests/run-asan.sh` は公式 tarball を取得し、配布パッチを `patch -p1` で適用してから、PHP CLI、CGI、session を AddressSanitizer 付きでビルドします。

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

2026-10-22 に Ubuntu 22.04、GCC 11、AddressSanitizer で確認しました。

| 検証 | 結果 |
| --- | --- |
| 8 MiB 制限下で 32 MiB を確保し、Fatal error 出力後に exit 1 | PASS |
| fatal request と正常 request を同じ server process で 25 回反復 | PASS |
| session upload-progress data が保存されないこと | PASS |
| `max_multipart_body_parts=2` で 2 part だけ受理すること | PASS |
| 全体で AddressSanitizer error がないこと | PASS |

25 回の request-cycle 検査は、sanitizer error や正常応答の破損を検出する回帰テストです。この検査だけでは未パッチ版との差を識別しません。識別できる検査は OOM の exit status、upload-progress record の非保存、multipart 上限です。

## 全 PHPT の実行

`tests/run-phpt.sh` は毎回新しい最小 non-ZTS build を作成し、PHP 5.4 の PHPT suite を実行します。

```powershell
docker build -f Dockerfile.asan -t php54-php2shell-test .
New-Item -ItemType Directory -Force test-results | Out-Null
docker run --rm -e RESULT_DIR=/results `
  -v "${PWD}:/workspace:ro" `
  -v "${PWD}\test-results:/results" `
  php54-php2shell-test bash /workspace/tests/run-phpt.sh
```

2026-10-22 の結果です。

| PHPT 結果 | 件数 |
| --- | ---: |
| test inventory 全体 | 12,562 |
| extension skip 後の対象 | 7,078 |
| PASS | 7,032 |
| FAIL | 15 |
| XFAIL | 30 |
| WARN | 1 |
| SKIP | 5,484 |
| `make test` exit status | 0 |

15 件の FAIL は次の内訳です。

- 8 件の `ext/session/tests/rfc1867*.phpt` は、session upload progress が保存されることを期待します。この機能は緩和策で意図的に無効化されています。
- `tests/lang/bug45392.phpt` は、従来の回復可能な OOM 経路を期待します。緩和策では worker を直ちに終了します。
- 残る 6 件は現行 container 環境に依存する古い test です。glob/open_basedir が 2 件、service database lookup が 3 件、`strptime()` が 1 件です。

WARN は、現在は PASS する古い XFAIL test です。完全な実行ログは `test-results/php-5.4.45-phpt.log` に出力されます。このディレクトリは配布物から除外しています。

## Windows ネイティブ検証

PHP の [Windows compiler 対応表](https://wiki.php.net/internals/windows/compiler) では、PHP 5.4 の正式対応 compiler は Visual C++ 9、Visual C++ 11 は動作実績ありとされています。Microsoft 公式の Visual Studio Express 2012 for Windows Desktop offline media に収録された Visual C++ 2012 RTM x86 compiler（`cl.exe` 17.00.50727.1）、linker、CRT、Windows SDK 8.0 で native 検証しました。

公式の [2011-09-15 版 PHP SDK binary tools](https://downloads.php.net/~windows/php-sdk/php-sdk-binary-tools-20110915.zip) を使い、x86 non-ZTS、CLI、session を構成しました。

```bat
git apply ..\php-5.4.45-php2shell.patch
git apply ..\tests\windows-vc11-link-version.patch

set PATH=C:\php-sdk-tools\bin;%PATH%
call "C:\Program Files (x86)\Microsoft Visual Studio 11.0\VC\vcvarsall.bat" x86

call buildconf.bat
call configure.bat --disable-all --enable-cli --disable-zts --enable-session
nmake
```

PHP 5.4.45 の元の Windows build rule は、二要素の image version を受け付ける `link.exe` に `/version:5.4.45` を渡します。別ファイルの試験用 `tests/windows-vc11-link-version.patch` はこれを `/version:5.4` に直します。PHP の runtime code は変更せず、配布用 security patch にも含まれません。

修正対象の runtime source はすべて compile され、`php5.dll` と `php.exe` の link に成功しました。`tests/run-windows-smoke.ps1` の結果は次のとおりです。

| Windows ネイティブ検証 | 結果 |
| --- | --- |
| PHP 5.4.45 CLI の起動 | PASS |
| OOM 診断と exit code 1 | PASS |
| fatal/healthy request cycle、25 回 | PASS |
| session upload-progress 緩和策 | PASS |
| multipart body-parts 上限 | PASS |

```powershell
powershell -ExecutionPolicy Bypass -File tests\run-windows-smoke.ps1 `
  -PhpExe C:\path\to\php-5.4.45\Release\php.exe
```

この結果は、PHP 5.4 で動作実績ありとされる compiler を使った non-ZTS x86 経路を対象にします。ZTS、Apache module、x64、正式対応の VC9 toolchain は未検証です。

## 整合性

`SHA256SUMS` に配布用パッチの SHA-256 を収録しています。

```text
afa262fd41cd2f7cb7f0842f4d936924412456609270b0a5d4864f7c0c656a0f  php-5.4.45-php2shell.patch
```
