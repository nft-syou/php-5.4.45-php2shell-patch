param(
    [string]$PhpExe = (Join-Path $PSScriptRoot '..\_build\php-5.4.45-win\Release\php.exe'),
    [string]$ResultDir = (Join-Path $PSScriptRoot '..\test-results')
)

$ErrorActionPreference = 'Stop'

$php = (Resolve-Path -LiteralPath $PhpExe).Path
$fixtures = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot 'fixtures')).Path
$oomFixture = (Resolve-Path -LiteralPath (Join-Path $fixtures 'oom.php')).Path
New-Item -ItemType Directory -Path $ResultDir -Force | Out-Null
$results = (Resolve-Path -LiteralPath $ResultDir).Path

& $php -n -v
if ($LASTEXITCODE -ne 0) {
    throw "php -v failed with exit code $LASTEXITCODE"
}

$oomStdout = Join-Path $results 'windows-oom.stdout.log'
$oomStderr = Join-Path $results 'windows-oom.stderr.log'
$oom = Start-Process -FilePath $php -ArgumentList @('-n', '-d', 'memory_limit=8M', ('"' + $oomFixture + '"')) -Wait -PassThru -NoNewWindow -RedirectStandardOutput $oomStdout -RedirectStandardError $oomStderr
$oomMessage = Get-Content -LiteralPath $oomStderr -Raw
if ($oom.ExitCode -ne 1 -or $oomMessage -notmatch 'Allowed memory size') {
    throw "OOM hard-exit check failed: exit=$($oom.ExitCode)"
}
Write-Output 'Windows OOM hard-exit test: PASS'

$runId = [Guid]::NewGuid().ToString('N')
$sessionDir = Join-Path ([IO.Path]::GetTempPath()) "php54-windows-smoke-$runId"
$upload = Join-Path ([IO.Path]::GetTempPath()) "php54-windows-upload-$runId.txt"
$serverStdout = Join-Path $results 'windows-server.stdout.log'
$serverStderr = Join-Path $results 'windows-server.stderr.log'
New-Item -ItemType Directory -Path $sessionDir | Out-Null
Set-Content -LiteralPath $upload -Value 'upload progress must stay disabled' -NoNewline

$serverArgs = @(
    '-n',
    '-d', ('"session.save_path=' + $sessionDir + '"'),
    '-d', 'session.upload_progress.enabled=1',
    '-d', 'session.upload_progress.cleanup=0',
    '-d', 'max_multipart_body_parts=2',
    '-S', '127.0.0.1:18081',
    '-t', ('"' + $fixtures + '"')
)
$server = Start-Process -FilePath $php -ArgumentList $serverArgs -PassThru -NoNewWindow -RedirectStandardOutput $serverStdout -RedirectStandardError $serverStderr

try {
    $ready = $false
    for ($attempt = 0; $attempt -lt 50; $attempt++) {
        $health = & curl.exe -fsS http://127.0.0.1:18081/health.php 2>$null
        if ($LASTEXITCODE -eq 0 -and $health -eq 'ok') {
            $ready = $true
            break
        }
        Start-Sleep -Milliseconds 100
    }
    if (-not $ready) {
        throw 'Windows PHP development server did not become ready'
    }

    for ($request = 1; $request -le 25; $request++) {
        & curl.exe -sS "http://127.0.0.1:18081/fatal.php?n=$request" | Out-Null
        $health = & curl.exe -fsS http://127.0.0.1:18081/health.php
        if ($LASTEXITCODE -ne 0 -or $health -ne 'ok') {
            throw "Request-cycle check failed at iteration $request"
        }
    }
    Write-Output 'Windows request-cycle regression test (25 loops): PASS'

    $sink = & curl.exe --http1.0 -H 'Expect:' -fsS -b 'PHPSESSID=php2shelltest' -F 'PHP_SESSION_UPLOAD_PROGRESS=probe' -F ("payload=@$upload") http://127.0.0.1:18081/sink.php
    if ($LASTEXITCODE -ne 0 -or $sink -ne '2') {
        throw "Upload request failed: expected 2 accepted parts, got '$sink'"
    }
    $probe = & curl.exe -fsS 'http://127.0.0.1:18081/probe.php?id=php2shelltest'
    if ($LASTEXITCODE -ne 0 -or $probe -ne 'clean') {
        throw "Session upload-progress check failed: got '$probe'"
    }
    Write-Output 'Windows session upload-progress mitigation test: PASS'

    $parts = & curl.exe --http1.0 -H 'Expect:' -fsS -F 'a=1' -F 'b=2' -F 'c=3' http://127.0.0.1:18081/sink.php
    if ($LASTEXITCODE -ne 0 -or $parts -ne '2') {
        throw "Multipart limit check failed: expected 2, got '$parts'"
    }
    Write-Output 'Windows multipart body-parts limit test: PASS'
}
finally {
    if (-not $server.HasExited) {
        Stop-Process -Id $server.Id -Force
    }
    $server.WaitForExit()

    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    foreach ($path in @($sessionDir, $upload)) {
        $fullPath = [IO.Path]::GetFullPath($path)
        if ($fullPath.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $fullPath -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
