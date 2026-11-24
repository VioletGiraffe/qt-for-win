#Requires -Version 7
<#
Packs the Qt sources from the Qt installer's Src folder without QML and Qt Quick, web, 3D, documentation and translation repos,
and without the docs, examples and tests of the repos it keeps.
The archive has the contents of Src at its root.

  pwsh pack_qt_sources.ps1 -SourceDir C:\Qt\6.12.1\Src
#>
param(
	[Parameter(Mandatory)] [string] $SourceDir,
	[string] $OutFile,
	# Selects the files without archiving them, and keeps the file list for inspection
	[switch] $NoArchive
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'release_archive.ps1')

# Every top-level folder of Src must be in one of the two lists: an unlisted one stops the run, so a repo new in a Qt release gets classified
$keptFolders = @(
	'cmake', 'LICENSES',
	'qtbase', 'qt5compat', 'qtactiveqt', 'qtcharts', 'qtcoap', 'qtconnectivity', 'qtgrpc', 'qthttpserver', 'qtimageformats',
	'qtmultimedia', 'qtnetworkauth', 'qtopenapi', 'qtpositioning', 'qtremoteobjects', 'qtscxml', 'qtsensors',
	'qtserialbus', 'qtserialport', 'qtshadertools', 'qtspeech', 'qtsvg', 'qttasktree', 'qttools', 'qtwebsockets'
)
$droppedFolders = @(
	# CI, Android and the superbuild's own tests
	'.github', 'coin', 'gradle', 'tests',
	# QML and Qt Quick, and the repos that require them
	'qtdeclarative', 'qtlanguageserver', 'qtcanvaspainter', 'qtgraphs', 'qtlocation', 'qtlottie', 'qtmqtt', 'qtquick3d',
	'qtquick3dphysics', 'qtquickeffectmaker', 'qtquicktimeline', 'qtvirtualkeyboard',
	# Web
	'qtwebchannel', 'qtwebengine', 'qtwebview',
	# 3D, Linux only, industrial automation, documentation and translations
	'qt3d', 'qtdatavis3d', 'qtwayland', 'qtopcua', 'qtdoc', 'qttranslations'
)

$SourceDir = (Resolve-Path $SourceDir).Path
$cmakeConf = Join-Path $SourceDir 'qtbase\.cmake.conf'
if (-not (Test-Path $cmakeConf)) { throw "No qtbase\.cmake.conf under $SourceDir" }
$versionMatch = Select-String -Path $cmakeConf -Pattern '^\s*set\(QT_REPO_MODULE_VERSION "([^"]+)"\)' | Select-Object -First 1
if (-not $versionMatch) { throw "No QT_REPO_MODULE_VERSION in $cmakeConf" }
$version = $versionMatch.Matches[0].Groups[1].Value

if (-not $OutFile) { $OutFile = "qt-$version-src.7z" }
$OutFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutFile)
if (-not $NoArchive -and (Test-Path $OutFile)) { throw "$OutFile already exists" }

foreach ($folder in Get-ChildItem $SourceDir -Directory -Force) {
	if ($keptFolders -notcontains $folder.Name -and $droppedFolders -notcontains $folder.Name) {
		throw "Src\$($folder.Name) is in neither keptFolders nor droppedFolders: add it to one of them"
	}
}
foreach ($name in $keptFolders) {
	if (-not (Test-Path (Join-Path $SourceDir $name))) { throw "Src\$name is missing: install its sources or move it to droppedFolders" }
}

# dependencies.yaml lists the repos each repo builds against; a required one must be kept
$repos = @($keptFolders | Where-Object { Test-Path (Join-Path $SourceDir "$_\dependencies.yaml") })
foreach ($repo in $repos) {
	$dependency = $null
	foreach ($line in Get-Content (Join-Path $SourceDir "$repo\dependencies.yaml")) {
		if ($line -match '^\s+\.\./([\w-]+):') { $dependency = $Matches[1] }
		elseif ($line -match '^\s+required:\s*true\b' -and $keptFolders -notcontains $dependency) {
			throw "$repo requires $dependency, which is not in keptFolders"
		}
	}
}

# Takes a '/'-separated path relative to the repo
function Test-KeptRepoFile([string] $repo, [string] $relative) {
	# Configuring needs none of these: tests and examples are added only when present, coin and dist are only globbed or used for CI
	if ($relative -match '^(tests|examples|coin|dist|\.github)/') { return $false }
	if ($relative -notmatch '(^|/)doc/') { return $true }
	# qt_internal_add_docs adds each .qdocconf to its target's sources even when docs are not built
	if ($relative.EndsWith('.qdocconf')) { return $true }
	# qtbase always adds doc/, which copies doc/global and doc/config at configure time
	return $repo -eq 'qtbase' -and $relative -match '^doc/(CMakeLists\.txt$|global/|config/)'
}

# Paths relative to Src, as the archive stores them
$selected = [System.Collections.Generic.List[string]]::new()
$selectedBytes = 0
foreach ($file in Get-ChildItem $SourceDir -File -Force) {
	$selected.Add($file.Name)
	$selectedBytes += $file.Length
}
foreach ($folder in $keptFolders) {
	$root = [IO.DirectoryInfo]::new((Join-Path $SourceDir $folder))
	$isRepo = $repos -contains $folder
	foreach ($file in $root.EnumerateFiles('*', [IO.SearchOption]::AllDirectories)) {
		$relative = [IO.Path]::GetRelativePath($root.FullName, $file.FullName)
		if ($isRepo -and -not (Test-KeptRepoFile $folder $relative.Replace('\', '/'))) { continue }
		$selected.Add("$folder\$relative")
		$selectedBytes += $file.Length
	}
}

"Qt $version sources, repos: $($repos -join ' ')"
"Selected: {0:N0} files, {1:N0} MB" -f $selected.Count, ($selectedBytes / 1MB)

# Next to the archive; deleted only after a successful archive
$listFile = Join-Path (Split-Path $OutFile) "qt-$version-src-files.txt"
[IO.File]::WriteAllLines($listFile, $selected)
if ($NoArchive) {
	"File list kept: $listFile"
	return
}

New-ReleaseArchive $OutFile $SourceDir "@$listFile"
Remove-Item $listFile
