#Requires -Version 7
<#
Builds the two Qt 5.15.2 archives: both MSVC 2019 kits (x86 and x64) in one archive, and the trimmed sources.
The kits come from the Qt installer's 5.15.2 folder; the sources come from the official tarball, downloaded and checked against its MD5.

  pwsh pack_qt5.ps1 -QtRoot C:\Qt\5.15.2 -OutDir D:\out
#>
param(
	# The Qt installer's 5.15.2 folder, holding msvc2019 and msvc2019_64
	[Parameter(Mandatory)] [string] $QtRoot,
	[string] $OutDir = '.'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'release_archive.ps1')

$kits = @('msvc2019_64', 'msvc2019')
# As in QT +=
$kitModules = @('core', 'gui', 'widgets', 'svg', 'network', 'multimedia', 'multimediawidgets')
$tarballUrl = 'https://download.qt.io/archive/qt/5.15/5.15.2/single/qt-everywhere-src-5.15.2.tar.xz'
$tarballMd5 = 'e1447db4f06c841d8947f0a6ce83a7b5'   # from md5sums.txt next to the tarball

$QtRoot = (Resolve-Path $QtRoot).Path
$OutDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutDir)
$kitArchive = Join-Path $OutDir 'qt-5.15.2-msvc2019-x86-x64.7z'
$sourceArchive = Join-Path $OutDir 'qt-5.15.2-src.7z'
foreach ($archive in $kitArchive, $sourceArchive) { if (Test-Path $archive) { throw "$archive already exists" } }
New-Item -ItemType Directory -Force $OutDir | Out-Null

# Tarball, extracted sources and staged kits; deleted only after a successful run, so a failed one leaves it for inspection
$work = Join-Path $OutDir 'qt-5.15.2-work'
if (Test-Path $work) { throw "$work already exists: delete it after inspecting it" }

# Each kit keeps its own folder in the archive
$kitsDir = Join-Path $work 'kits'
foreach ($kit in $kits) {
	& (Join-Path $PSScriptRoot 'pack_qt5_kit.ps1') -QtDir (Join-Path $QtRoot $kit) -Modules $kitModules -StagingDir (Join-Path $kitsDir $kit) -NoArchive |
		Where-Object { $_ -notmatch '^(\s+dropped |Staging folder kept)' }
}
New-ReleaseArchive $kitArchive $kitsDir '*'

$tarball = Join-Path $work 'qt-everywhere-src-5.15.2.tar.xz'
Invoke-WebRequest $tarballUrl -OutFile $tarball
if ((Get-FileHash $tarball -Algorithm MD5).Hash -ne $tarballMd5) { throw "$tarball does not match its MD5" }
# qtwebengine is most of the tarball, and pack_qt5_sources.ps1 drops it
& "$env:SystemRoot\System32\tar.exe" -xf $tarball -C $work --exclude 'qt-everywhere-src-5.15.2/qtwebengine'
if ($LASTEXITCODE) { throw "tar failed with exit code $LASTEXITCODE" }
& (Join-Path $PSScriptRoot 'pack_qt5_sources.ps1') -SourceDir (Join-Path $work 'qt-everywhere-src-5.15.2') -OutFile $sourceArchive

Remove-Item $work -Recurse -Force
