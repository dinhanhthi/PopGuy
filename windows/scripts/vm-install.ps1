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

.PARAMETER Launch
    Start PopGuy.exe after installing.

.PARAMETER AppArgs
    Alias -Args. Arguments passed to PopGuy.exe. A non-empty list implies -Launch. The values
    are never printed (they may hold paths of QA key files), only their count.

.PARAMETER Wait
    Wait for PopGuy to exit, print its exit code and exit with that code.

.PARAMETER Dest
    Where the app is copied. Default: C:\PopGuyQA\builds\<leaf name of -Folder>.
    An existing copy there is replaced.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File Z:\Downloads\PopGuy-win\<RUN>\vm-install.ps1 -Folder Z:\Downloads\PopGuy-win\<RUN> -Launch

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -Command "& 'Z:\Downloads\PopGuy-win\<RUN>\vm-install.ps1' -Folder 'Z:\Downloads\PopGuy-win\<RUN>' -Args '--spike' -Wait"

    Use -Command (not -File) to pass app arguments: under -File, a value such as
    --spike is read as a parameter name and a,b stays one string.
#>
param(
    [Parameter(Mandatory = $true)][string]$Folder,
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

try {
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

    if ($Wait) {
        $proc.WaitForExit()
        $code = $proc.ExitCode
        Write-Host "PopGuy exited with code $code"
        exit $code
    }
    exit 0
}
catch {
    [Console]::Error.WriteLine("vm-install: $($_.Exception.Message)")
    exit 1
}
