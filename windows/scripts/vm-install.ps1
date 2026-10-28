<#
.SYNOPSIS
    Installs a CI build of PopGuy in the Windows QA VM (Windows PowerShell 5.1).

.DESCRIPTION
    Picks the app folder for this machine's architecture from a downloaded CI
    artifact, stops any running PopGuy, copies the app to a local folder
    (Z: is a network zone and elevated shells may not see it), unblocks the
    files and optionally starts PopGuy.exe.

.PARAMETER Folder
    The downloaded artifact folder. Either a per-arch artifact that contains
    app\PopGuy.exe, or a folder that contains win-arm64\app and/or win-x64\app.

.PARAMETER Setup
    Instead of -Folder: a release's PopGuy-win-<arch>-Setup.exe, or a folder
    that holds it (this machine's architecture is picked). The installer is
    copied to C:\PopGuyQA and run with --silent, which installs PopGuy into
    %LOCALAPPDATA%\PopGuy (Velopack). Start the installed copy afterwards with
    explorer.exe: one started by the installer ends with this command.

.PARAMETER Launch
    Start PopGuy.exe after installing. Without -Wait the app is started through
    explorer.exe, which hands the launch to the shell, and the new process id is
    printed. Why: the VM tool runs each command in a job and kills the whole
    process tree when the command returns, which ends a Start-Process child at
    once. A process created through WMI (Win32_Process.Create) lands on a
    non-interactive desktop, so its window never shows, and a scheduled-task
    launch shows the window but renders no XAML text. With -Wait the caller
    waits, so the app is a normal child process.

.PARAMETER AppArgs
    Alias -Args. Arguments passed to PopGuy.exe. A non-empty list implies -Launch
    and needs -Wait (explorer.exe cannot pass arguments): run vm-install with
    -Wait inside a long-timeout VM command. The values are never printed (they
    may hold paths of QA key files), only their count.

.PARAMETER Wait
    Wait for PopGuy to exit, print its exit code and exit with that code. The app
    runs as a child of this script (see -Launch).

.PARAMETER Dest
    Where the app is copied. Default: C:\PopGuyQA\builds\<leaf name of -Folder>.
    An existing copy there is replaced.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File Z:\Downloads\PopGuy-win\<RUN>\vm-install.ps1 -Folder Z:\Downloads\PopGuy-win\<RUN> -Launch

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File Z:\Downloads\PopGuy-update\vm-install.ps1 -Setup Z:\Downloads\PopGuy-update\0.0.900-dev

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -Command "& 'Z:\Downloads\PopGuy-win\<RUN>\vm-install.ps1' -Folder 'Z:\Downloads\PopGuy-win\<RUN>' -Args '--spike' -Wait"

    Use -Command (not -File) to pass app arguments: under -File, a value such as
    --spike is read as a parameter name and a,b stays one string.
#>
param(
    [string]$Folder,
    [string]$Setup,
    [switch]$Launch,
    [Alias('Args')][string[]]$AppArgs = @(),
    [switch]$Wait,
    [string]$Dest
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-Arch {
    # An emulated shell reports its own arch; PROCESSOR_ARCHITEW6432 then holds the machine's.
    $machine = $env:PROCESSOR_ARCHITEW6432
    if (-not $machine) { $machine = $env:PROCESSOR_ARCHITECTURE }
    switch ($machine) {
        'ARM64' { return 'arm64' }
        'AMD64' { return 'x64' }
        default { throw "Unsupported processor architecture '$machine' (expected ARM64 or AMD64)." }
    }
}

function Find-AppFolder {
    $flat = Join-Path $Folder 'app'
    if (Test-Path -LiteralPath (Join-Path $flat 'PopGuy.exe') -PathType Leaf) {
        return $flat
    }
    $arch = Get-Arch
    $perArch = Join-Path $Folder "win-$arch\app"
    if (Test-Path -LiteralPath (Join-Path $perArch 'PopGuy.exe') -PathType Leaf) {
        return $perArch
    }
    throw "PopGuy.exe not found for $arch under '$Folder' (looked in '$flat' and '$perArch')."
}

function Install-Setup {
    $arch = Get-Arch
    $installer = $Setup
    if (Test-Path -LiteralPath $Setup -PathType Container) {
        $installer = Join-Path $Setup "PopGuy-win-$arch-Setup.exe"
    }
    if (-not (Test-Path -LiteralPath $installer -PathType Leaf)) {
        throw "Installer not found: '$installer' (pass PopGuy-win-$arch-Setup.exe or the folder that holds it)."
    }
    Get-Process PopGuy -ErrorAction SilentlyContinue | Stop-Process -Force
    New-Item -ItemType Directory -Path 'C:\PopGuyQA' -Force | Out-Null
    $local = Join-Path 'C:\PopGuyQA' (Split-Path -Leaf $installer)
    Copy-Item -LiteralPath $installer -Destination $local -Force
    $proc = Start-Process -FilePath $local -ArgumentList '--silent' -PassThru -Wait
    Write-Host "Ran $local --silent, exit code $($proc.ExitCode)."
    exit $proc.ExitCode
}

try {
    if (($Folder -and $Setup) -or -not ($Folder -or $Setup)) {
        throw 'Pass either -Folder (a CI app folder) or -Setup (a release installer).'
    }
    if ($Setup) {
        Install-Setup
    }
    if ($AppArgs.Count -gt 0 -and -not $Wait) {
        throw 'App arguments need -Wait: the VM tool kills child processes when the command returns. Run vm-install with -Wait inside a long-timeout vmpal_exec call.'
    }
    if (-not (Test-Path -LiteralPath $Folder -PathType Container)) {
        throw "Folder '$Folder' is not reachable from this session (an elevated session may not see the Z: drive). Copy the folder to C:\PopGuyQA\builds\<run> first and pass that path."
    }
    if (-not $Dest) {
        $Dest = Join-Path 'C:\PopGuyQA\builds' (Get-Item -LiteralPath $Folder).Name
    }

    $appDir = Find-AppFolder

    Get-Process PopGuy -ErrorAction SilentlyContinue | Stop-Process -Force

    $parent = Split-Path -Parent $Dest
    if ($parent) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    if (Test-Path -LiteralPath $Dest) {
        Remove-Item -LiteralPath $Dest -Recurse -Force
    }
    Copy-Item -LiteralPath $appDir -Destination $Dest -Recurse
    Get-ChildItem -LiteralPath $Dest -Recurse -File | Unblock-File
    Write-Host "Installed $appDir to $Dest."

    if (-not ($Launch -or $AppArgs.Count -gt 0)) {
        exit 0
    }

    $exe = Join-Path $Dest 'PopGuy.exe'

    if (-not $Wait) {
        # Through the shell, outside this job (see -Launch). Any earlier PopGuy was stopped above;
        # the margin covers clock granularity.
        $since = (Get-Date).AddSeconds(-1)
        # explorer.exe exits with 1 even when the launch works: its exit code is ignored.
        & "$env:WINDIR\explorer.exe" $exe
        $started = $null
        $deadline = (Get-Date).AddSeconds(10)
        while (-not $started -and (Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 250
            $started = Get-Process PopGuy -ErrorAction SilentlyContinue |
                Where-Object { $_.StartTime -ge $since } |
                Select-Object -First 1
        }
        if (-not $started) {
            throw "PopGuy did not start within 10 s (launched through explorer.exe)."
        }
        Write-Host "Launched $exe, process id $($started.Id)."
        exit 0
    }

    $startArgs = @{
        FilePath         = $exe
        WorkingDirectory = $Dest
        PassThru         = $true
    }
    if ($AppArgs.Count -gt 0) {
        $startArgs['ArgumentList'] = $AppArgs
    }
    $proc = Start-Process @startArgs
    # Cache the handle now; without it ExitCode can be empty after the process exits.
    $null = $proc.Handle
    Write-Host "Launched $exe with $($AppArgs.Count) argument(s)."

    $proc.WaitForExit()
    $code = $proc.ExitCode
    Write-Host "PopGuy exited with code $code"
    exit $code
}
catch {
    [Console]::Error.WriteLine("vm-install: $($_.Exception.Message)")
    exit 1
}
