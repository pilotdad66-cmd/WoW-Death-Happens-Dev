# DH-Tweaks local test runner: syntax check of the module's files, then
# its mocked-API harness. The full DH-Tools suite is
# src\DH-Tools\tests\run-tests.ps1 (it also syntax-checks these files).
# Usage: powershell -ExecutionPolicy Bypass -File src\DH-Tools\Modules\DHTweaks\tests\run-tests.ps1

$ErrorActionPreference = 'Continue'
$luaBin = 'C:\Users\pilot\AppData\Local\Programs\Lua\bin'
if ($env:Path -notlike "*$luaBin*") { $env:Path = $luaBin + ';' + $env:Path }
$moduleRoot = Split-Path -Parent $PSScriptRoot

Write-Output '== Syntax check (luac5.4 -p), Modules\DHTweaks\ =='
$failed = $false
Get-ChildItem -Path $moduleRoot -Filter *.lua -Recurse | ForEach-Object {
    $result = & luac5.4.exe -p $_.FullName 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Output ('SYNTAX ERROR in ' + $_.FullName + ': ' + $result)
        $failed = $true
    }
}
if (-not $failed) { Write-Output 'All .lua files passed syntax check.' }

Write-Output ''
Write-Output '== tests\harness.lua =='
& lua5.4.exe (Join-Path $PSScriptRoot 'harness.lua')
$harnessExit = $LASTEXITCODE

Write-Output ''
if ($failed -or $harnessExit -ne 0) {
    Write-Output 'RESULT: one or more checks FAILED - see above.'
    exit 1
} else {
    Write-Output 'RESULT: syntax check + harness all passed.'
    exit 0
}
