# DH-Air local test runner.
# Runs luac5.4 -p across every .lua file, then both headless harnesses.
# Usage: powershell -ExecutionPolicy Bypass -File tests\run-tests.ps1

$ErrorActionPreference = 'Continue'
$luaBin = 'C:\Users\pilot\AppData\Local\Programs\Lua\bin'
if ($env:Path -notlike "*$luaBin*") {
    $env:Path = $luaBin + ';' + $env:Path
}
$root = Split-Path -Parent $PSScriptRoot

Write-Output '== Syntax check (luac5.4 -p) =='
$failed = $false
Get-ChildItem -Path $root -Filter *.lua -Recurse | ForEach-Object {
    $result = & luac5.4.exe -p $_.FullName 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Output ('SYNTAX ERROR in ' + $_.FullName + ': ' + $result)
        $failed = $true
    }
}
if (-not $failed) {
    Write-Output 'All .lua files passed syntax check.'
} else {
    Write-Output 'One or more files failed the syntax check - see above.'
}

Write-Output ''
Write-Output '== tests\harness.lua =='
Push-Location $root
& lua5.4.exe 'tests\harness.lua'
$harnessExit = $LASTEXITCODE

Write-Output ''
Write-Output '== tests\harness_shared_queue.lua =='
& lua5.4.exe 'tests\harness_shared_queue.lua'
$sharedExit = $LASTEXITCODE
Pop-Location

Write-Output ''
if ($failed -or $harnessExit -ne 0 -or $sharedExit -ne 0) {
    Write-Output 'RESULT: one or more checks FAILED - see above.'
} else {
    Write-Output 'RESULT: syntax check + both harnesses all passed.'
}
