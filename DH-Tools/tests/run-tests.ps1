# DH-Tools Core.lua local test runner.
# Runs luac5.4 -p across every .lua file under src\DH-Tools\ (the whole
# addon, not just Core.lua - cheap and catches cross-module breakage too),
# then this harness.
# Usage: powershell -ExecutionPolicy Bypass -File tests\run-tests.ps1
# (run from src\DH-Tools\, mirroring DHQuests/DHAir's own tests\run-tests.ps1 convention)

$ErrorActionPreference = 'Continue'
$luaBin = 'C:\Users\pilot\AppData\Local\Programs\Lua\bin'
if ($env:Path -notlike "*$luaBin*") {
    $env:Path = $luaBin + ';' + $env:Path
}
# $PSScriptRoot = ...\src\DH-Tools\tests - the addon root (src\DH-Tools\)
# is one level up.
$addonRoot = Split-Path -Parent $PSScriptRoot

Write-Output '== Syntax check (luac5.4 -p), all of src\DH-Tools\ =='
$failed = $false
Get-ChildItem -Path $addonRoot -Filter *.lua -Recurse | ForEach-Object {
    $result = & luac5.4.exe -p $_.FullName 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Output ('SYNTAX ERROR in ' + $_.FullName + ': ' + $result)
        $failed = $true
    }
}
if (-not $failed) {
    Write-Output 'All .lua files under src\DH-Tools\ passed syntax check.'
} else {
    Write-Output 'One or more files failed the syntax check - see above.'
}

Write-Output ''
Write-Output '== tests\harness.lua =='
Push-Location $addonRoot
& lua5.4.exe 'tests\harness.lua'
$harnessExit = $LASTEXITCODE
Pop-Location

Write-Output ''
if ($failed -or $harnessExit -ne 0) {
    Write-Output 'RESULT: one or more checks FAILED - see above.'
    exit 1
} else {
    Write-Output 'RESULT: syntax check + harness all passed.'
    exit 0
}
