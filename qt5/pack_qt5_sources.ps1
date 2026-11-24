#Requires -Version 7
<#
Qt 5 counterpart of pack_qt_sources.ps1, for the qmake build: pack_qt5.ps1 calls it on the extracted qt-everywhere-src tarball.
Packs the sources without QML and Qt Quick, web, 3D, other-platform, documentation and translation repos,
and without the docs, examples and tests of the repos it keeps.
The archive has the contents of the source folder at its root.

  pwsh pack_qt5_sources.ps1 -SourceDir C:\Temp\qt-everywhere-src-5.15.2
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

# Every top-level folder of the sources must be in one of the two lists
$keptFolders = @(
	'gnuwin32',   # flex and bison for qtbase's ANGLE build
	'qtbase', 'qtactiveqt', 'qtcharts', 'qtconnectivity', 'qtgamepad', 'qtimageformats', 'qtmultimedia', 'qtnetworkauth',
	'qtremoteobjects', 'qtscript', 'qtsensors', 'qtserialbus', 'qtserialport', 'qtspeech', 'qtsvg', 'qttools', 'qtwebsockets',
	'qtwinextras', 'qtxmlpatterns'
)
$droppedFolders = @(
	'coin',
	# QML and Qt Quick, and the repos that require them
	'qtdeclarative', 'qtgraphicaleffects', 'qtlottie', 'qtquick3d', 'qtquickcontrols', 'qtquickcontrols2', 'qtquicktimeline',
	'qtscxml', 'qtvirtualkeyboard',
	# Web
	'qtwebchannel', 'qtwebengine', 'qtwebglplugin', 'qtwebview',
	# 3D, maps, other platforms, app stores, documentation and translations
	'qt3d', 'qtdatavis3d', 'qtlocation', 'qtandroidextras', 'qtmacextras', 'qtx11extras', 'qtwayland', 'qtpurchasing',
	'qtdoc', 'qttranslations'
)

$SourceDir = (Resolve-Path $SourceDir).Path
$version = (Select-String -Path (Join-Path $SourceDir 'qtbase\.qmake.conf') -Pattern '^MODULE_VERSION = (\S+)').Matches[0].Groups[1].Value

if (-not $OutFile) { $OutFile = "qt-$version-src.7z" }
$OutFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutFile)
if (-not $NoArchive -and (Test-Path $OutFile)) { throw "$OutFile already exists" }

foreach ($folder in Get-ChildItem $SourceDir -Directory -Force) {
	if ($keptFolders -notcontains $folder.Name -and $droppedFolders -notcontains $folder.Name) {
		throw "$($folder.Name) is in neither keptFolders nor droppedFolders: add it to one of them"
	}
}
foreach ($name in $keptFolders) {
	if (-not (Test-Path (Join-Path $SourceDir $name))) { throw "$name is missing from $SourceDir" }
}

# .gitmodules: depends = repos each repo requires
$repos = @($keptFolders | Where-Object { $_ -ne 'gnuwin32' })
$submodule = $null
foreach ($line in Get-Content (Join-Path $SourceDir '.gitmodules')) {
	if ($line -match '^\[submodule "(.+)"\]') { $submodule = $Matches[1] }
	elseif ($repos -contains $submodule -and $line -match '^\s*depends\s*=\s*(.*)$') {
		foreach ($dependency in $Matches[1] -split '\s+' | Where-Object { $_ }) {
			if ($keptFolders -notcontains $dependency) { throw "$submodule requires $dependency, which is not in keptFolders" }
		}
	}
}

# Takes a '/'-separated path relative to the repo
function Test-KeptRepoFile([string] $repo, [string] $relative) {
	# qt_parts.prf adds tests and examples only when present
	if ($relative -match '^(tests|examples|coin|dist)/') { return $false }
	if ($relative -notmatch '(^|/)doc/') { return $true }
	# qt_docs.prf fails when a module's QMAKE_DOCS file is missing; qtspeech adds its doc.pro unconditionally
	if ($relative.EndsWith('.qdocconf') -or ($relative.EndsWith('.pro') -and $relative -notmatch '/snippets/')) { return $true }
	# qtbase.pro always adds doc/doc.pro, which installs doc/global and doc/config
	return $repo -eq 'qtbase' -and $relative -match '^doc/(global|config)/'
}

# Paths relative to the source folder, as the archive stores them
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
