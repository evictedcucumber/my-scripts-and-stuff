<#
.SYNOPSIS
    Compresses the contents of a directory into a maximum-compression 7-Zip
    archive placed in the current user's Downloads folder, named YYYY-MM-DD.7z.

.DESCRIPTION
    Recursively archives the contents of the given directory - names are stored
    relative to that directory, so archiving C:\projects\foo puts "bar\baz" at
    the archive root, not "foo\bar\baz" - into a .7z file using 7-Zip's
    strongest lossless settings: LZMA2, ultra level (-mx=9), maximum fast bytes
    (-mfb=273), a large dictionary, a solid archive, and sort-by-type.

    The archive is written to the user's Downloads folder - resolved from the
    Downloads known-folder registry entry, falling back to
    %USERPROFILE%\Downloads - as <YYYY-MM-DD>.7z using today's local date. If
    that name already exists a _2, _3, ... suffix is added, unless -Force is
    given, in which case the existing archive is replaced.

    7-Zip is located on PATH (7z / 7za) or at a standard 7-Zip install path
    under %ProgramFiles%.

.PARAMETER Path
    The directory to archive. Required; accepts a relative or absolute path.
    Its contents are archived; the directory's own name is not kept as a path
    prefix inside the archive.

.PARAMETER DestinationDirectory
    Where to write the archive. Defaults to the current user's Downloads
    folder.

.PARAMETER DictionarySize
    LZMA2 dictionary size (e.g. 64m, 128m, 256m, 512m, 1g). A larger
    dictionary can improve the ratio on big inputs but needs roughly 10x that
    much RAM to compress. Defaults to 256m (~2.5 GiB RAM).

.PARAMETER Force
    Replace an existing archive of the same name instead of adding a numeric
    suffix.

.EXAMPLE
    .\archive_directory.ps1 C:\projects\foo

    Archives the contents of C:\projects\foo into
    %USERPROFILE%\Downloads\<YYYY-MM-DD>.7z.

.EXAMPLE
    .\archive_directory.ps1 C:\projects\foo -DestinationDirectory D:\backups -WhatIf

    Shows which archive would be created in D:\backups without creating it.

.NOTES
    Requirements: Windows, PowerShell 5.1+, 7-Zip (https://www.7-zip.org)
    installed and on PATH or under %ProgramFiles%\7-Zip.

    Compression is CPU- and RAM-heavy at these settings (see -DictionarySize).
    Multithreading is left at 7-Zip's default; -mmt=off can squeeze out a
    fraction more ratio at a large time cost. Filesystem metadata such as NTFS
    ACLs, alternate data streams, and creation/access timestamps is not
    captured - add 7-Zip's -sni / -sna / -mtc=on / -mta=on switches to
    $sevenZipArgs if you need them.
#>

#Requires -Version 5.1

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory, Position = 0)]
    [string]$Path,

    [string]$DestinationDirectory,

    [ValidatePattern('^\d+[bkmgBKMG]?$')]
    [string]$DictionarySize = '256m',

    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Get-DownloadsFolder {
    # Downloads is a known folder and can be redirected, so prefer the shell
    # folders registry entry over assuming %USERPROFILE%\Downloads.
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders'
    $guid = '{374DE290-123F-4565-9164-39C4925E467B}'
    try {
        $value = (Get-ItemProperty -LiteralPath $key -Name $guid -ErrorAction Stop).$guid
        if ($value) {
            return [Environment]::ExpandEnvironmentVariables($value)
        }
    }
    catch {
        Write-Verbose "Downloads shell-folder lookup failed ($($_.Exception.Message)); using the default path."
    }
    return (Join-Path $env:USERPROFILE 'Downloads')
}

function Resolve-SevenZip {
    # Finds 7-Zip: PATH first (7z, 7za), then the standard install folders under
    # Program Files. Returns the full path, or $null when it is not installed.
    foreach ($name in '7z', '7za') {
        $cmd = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($cmd) {
            return $cmd.Source
        }
    }

    $roots = @($env:ProgramW6432, $env:ProgramFiles, ${env:ProgramFiles(x86)}) |
        Where-Object { $_ }
    foreach ($root in $roots) {
        $candidate = Join-Path $root '7-Zip\7z.exe'
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    return $null
}

# ---------------------------------------------------------------------------
# Resolve inputs
# ---------------------------------------------------------------------------

$sevenZip = Resolve-SevenZip
if (-not $sevenZip) {
    Write-Error "7-Zip not found. Install it from https://www.7-zip.org and make sure 7z(.exe) is on PATH."
    exit 1
}

try {
    $sourcePath = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
}
catch {
    Write-Error "Path not found: $Path"
    exit 1
}

if (-not (Test-Path -LiteralPath $sourcePath -PathType Container)) {
    Write-Error "Not a directory: $sourcePath"
    exit 1
}

if (-not (Get-ChildItem -LiteralPath $sourcePath -Force -ErrorAction SilentlyContinue)) {
    Write-Error "Directory is empty, nothing to archive: $sourcePath"
    exit 1
}

$sourcePath = $sourcePath.TrimEnd('\')
if ($sourcePath -match '^[A-Za-z]:$') {
    # A drive root trimmed to "C:" would mean "current dir on C:" to 7-Zip.
    $sourcePath += '\'
}

# Archive the directory's *contents*, not the directory itself: 7-Zip stores
# names relative to the folder that holds the wildcard, so "<dir>\*" yields
# "subdir\file", not "<dir>\subdir\file". PowerShell passes "*" through
# literally (no shell glob), so 7-Zip does its own expansion and still picks up
# hidden/dotfile entries.
$sourceSpec = Join-Path $sourcePath '*'

if (-not $DestinationDirectory) {
    $DestinationDirectory = Get-DownloadsFolder
}
# Normalise to an absolute path without requiring the folder to exist yet
# (it is created just before compressing, so -WhatIf stays side-effect free).
$DestinationDirectory =
    $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($DestinationDirectory).TrimEnd('\')

if (($DestinationDirectory + '\').StartsWith($sourcePath.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
    Write-Warning "Destination is inside the source directory; 7-Zip skips the archive itself, but a separate destination is cleaner."
}

# ---------------------------------------------------------------------------
# Pick an archive name (YYYY-MM-DD.7z, with a _N suffix on collision)
# ---------------------------------------------------------------------------

$dateStamp = Get-Date -Format 'yyyy-MM-dd'
$archivePath = Join-Path $DestinationDirectory "$dateStamp.7z"

if (Test-Path -LiteralPath $archivePath) {
    if ($Force) {
        Remove-Item -LiteralPath $archivePath -Force
    }
    else {
        $suffix = 2
        do {
            $archivePath = Join-Path $DestinationDirectory ('{0}_{1}.7z' -f $dateStamp, $suffix)
            $suffix++
        } while (Test-Path -LiteralPath $archivePath)
        Write-Warning "An archive for $dateStamp already exists; using $(Split-Path -Leaf $archivePath)."
    }
}

# ---------------------------------------------------------------------------
# Compress
# ---------------------------------------------------------------------------

# Strongest lossless 7z settings: LZMA2, ultra level, max fast bytes, large
# dictionary, solid archive, sort-by-type, and compress files open for writing.
$sevenZipArgs = @(
    'a'
    '-t7z'
    '-mx=9'
    '-m0=lzma2'
    '-mfb=273'
    "-md=$DictionarySize"
    '-ms=on'
    '-mqs=on'
    '-ssw'
    '-bsp1'
    '--'
    $archivePath
    $sourceSpec
)

Write-Output "Source:  $sourcePath (contents)"
Write-Output "Archive: $archivePath"
Write-Output "7-Zip:   $sevenZip"
Write-Output "Compressing at -mx=9 (this can take a while)..."

if (-not $PSCmdlet.ShouldProcess($archivePath, "Create 7-Zip archive of $sourcePath (contents)")) {
    return
}

if (-not (Test-Path -LiteralPath $DestinationDirectory)) {
    try {
        New-Item -ItemType Directory -Path $DestinationDirectory -Force | Out-Null
    }
    catch {
        Write-Error "Could not create destination directory '$DestinationDirectory': $($_.Exception.Message)"
        exit 1
    }
}

& $sevenZip @sevenZipArgs
$exitCode = $LASTEXITCODE

if ($exitCode -eq 1) {
    Write-Warning "7-Zip finished with warnings (exit 1); some files may have been skipped."
}
elseif ($exitCode -ne 0) {
    Write-Error "7-Zip failed (exit code $exitCode)."
    exit $exitCode
}

if (-not (Test-Path -LiteralPath $archivePath)) {
    Write-Error "7-Zip reported success but no archive was produced at $archivePath."
    exit 1
}

$sizeMiB = (Get-Item -LiteralPath $archivePath).Length / 1MB
Write-Output ("Done. {0}  ({1:N1} MiB)" -f $archivePath, $sizeMiB)
