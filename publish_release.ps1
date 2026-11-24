#Requires -Version 7
<#
Packs the kit and the sources of one Qt version and uploads them as a draft GitHub release, tagged with the version.
The draft is published by hand on GitHub; the tag is created then.

  pwsh publish_release.ps1 -QtRoot C:\Qt\6.12.1
#>
param(
	# The Qt installer's folder for one version, holding the kit and Src
	[Parameter(Mandatory)] [string] $QtRoot,
	[string] $Kit = 'msvc2022_64',
	# The archives stay there after the upload
	[string] $OutDir = '.'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# The modules of the published kit, as in QT +=
$kitModules = @('core', 'gui', 'widgets', 'svg', 'network', 'multimedia', 'multimediawidgets')

$QtRoot = (Resolve-Path $QtRoot).Path
$OutDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutDir)
$version = (& (Join-Path $QtRoot "$Kit\bin\qmake.exe") -query QT_VERSION).Trim()
$kitArchive = Join-Path $OutDir "qt-$version-$Kit.7z"
$sourceArchive = Join-Path $OutDir "qt-$version-src.7z"
foreach ($archive in $kitArchive, $sourceArchive) { if (Test-Path $archive) { throw "$archive already exists" } }

# gh finds the repository from the current folder
Push-Location -LiteralPath $PSScriptRoot
try {
	# The list includes drafts, which have no tag yet
	$existingTags = gh release list --limit 1000 --json tagName --jq '.[].tagName'
	if ($LASTEXITCODE) { throw "gh release list failed with exit code $LASTEXITCODE" }
	if ($existingTags -contains $version) { throw "Release $version already exists" }

	New-Item -ItemType Directory -Force $OutDir | Out-Null
	& (Join-Path $PSScriptRoot 'pack_qt_kit.ps1') -QtDir (Join-Path $QtRoot $Kit) -Modules $kitModules -OutFile $kitArchive
	& (Join-Path $PSScriptRoot 'pack_qt_sources.ps1') -SourceDir (Join-Path $QtRoot 'Src') -OutFile $sourceArchive

	$rows = foreach ($archive in $kitArchive, $sourceArchive) {
		$hash = (Get-FileHash $archive -Algorithm SHA256).Hash.ToLowerInvariant()
		'| `{0}` | {1:N0} MB | `{2}` |' -f (Split-Path $archive -Leaf), ((Get-Item $archive).Length / 1MB), $hash
	}
	$notes = @(
		"Qt $version for Windows: the $Kit kit with ``$($kitModules -join ',')`` and their dependencies, and the trimmed sources."
		''
		'| Archive | Size | SHA-256 |'
		'|---|---|---|'
		$rows
	) -join "`n"

	# Deleted only after a successful upload
	$notesFile = Join-Path $OutDir "qt-$version-release-notes.md"
	[IO.File]::WriteAllText($notesFile, $notes)
	gh release create $version $kitArchive $sourceArchive --draft --title "Qt $version" --notes-file $notesFile
	if ($LASTEXITCODE) { throw "gh release create failed with exit code $LASTEXITCODE" }
	Remove-Item $notesFile
}
finally { Pop-Location }
