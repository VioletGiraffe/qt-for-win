#Requires -Version 7
<#
Packs a trimmed Windows Qt kit for CI: the requested qmake modules with their dependencies, the build tools, and the plugins those modules can load.
The archive has the kit's contents at its root: extract it into an empty folder and point QT_ROOT_DIR at that folder.

  pwsh pack_qt_kit.ps1 -QtDir C:\Qt\6.11.2\msvc2022_64 -Modules core,gui,widgets,svg,network
#>
param(
	[Parameter(Mandatory)] [string] $QtDir,
	# qmake module names, as written in QT += (each one's _private module comes along)
	[Parameter(Mandatory)] [string[]] $Modules,
	[string[]] $Tools = @('qmake.exe', 'moc.exe', 'rcc.exe', 'uic.exe', 'qtpaths.exe', 'windeployqt.exe'),
	# The GPL and LGPL texts, which must accompany the binaries; the Qt installer puts them in <root>\Licenses
	[string] $LicenseFile,
	[string] $OutFile,
	# Stages and verifies the kit without archiving it, and keeps the staging folder for inspection
	[switch] $NoArchive
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'release_archive.ps1')

# pwsh -File passes "a,b" as one string
$Modules = @($Modules -split '[,\s]+' | Where-Object { $_ })
$Tools = @($Tools -split '[,\s]+' | Where-Object { $_ })

$QtDir = (Resolve-Path $QtDir).Path
$kitBin = Join-Path $QtDir 'bin'
$qmake = Join-Path $kitBin 'qmake.exe'
if (-not (Test-Path $qmake)) { throw "No qmake.exe under $kitBin" }
if (-not $LicenseFile) { $LicenseFile = Join-Path $QtDir '..\..\Licenses\LICENSE' }
if (-not (Test-Path $LicenseFile)) { throw "No Qt license file at ${LicenseFile}: pass -LicenseFile" }

function Find-Dumpbin {
	$onPath = Get-Command dumpbin.exe -ErrorAction SilentlyContinue
	if ($onPath) { return $onPath.Source }
	$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
	if (Test-Path $vswhere) {
		$found = & $vswhere -latest -products * -find 'VC\Tools\MSVC\**\bin\Hostx64\x64\dumpbin.exe' | Select-Object -Last 1
		if ($found) { return $found }
	}
	throw 'dumpbin.exe not found: install the MSVC build tools or run from a VS developer prompt'
}
$dumpbin = Find-Dumpbin

# Maps each file path to the DLL names it imports, delay-loaded ones included
function Get-DllImports([string[]] $paths) {
	$imports = @{}
	# Chunked: the command line is limited to 32K characters
	for ($i = 0; $i -lt $paths.Count; $i += 64) {
		$chunk = $paths[$i..([Math]::Min($i + 63, $paths.Count - 1))]
		$current = $null
		foreach ($line in & $dumpbin /nologo /dependents @chunk) {
			if ($line -match '^Dump of file (.+)$') {
				$current = $Matches[1].Trim()
				$imports[$current] = [System.Collections.Generic.List[string]]::new()
			}
			elseif ($current -and $line -match '^\s+(\S+\.dll)\s*$') {
				$imports[$current].Add($Matches[1])
			}
		}
		if ($LASTEXITCODE) { throw "dumpbin failed on $($chunk -join ', ')" }
	}
	return $imports
}

# Module definitions keyed by qmake name: one .pri can define several (qt_lib_entrypoint_private.pri also defines entrypoint_implementation)
$definitions = @{}
foreach ($pri in Get-ChildItem (Join-Path $QtDir 'mkspecs\modules') -Filter 'qt_lib_*.pri') {
	foreach ($line in Get-Content $pri.FullName) {
		if ($line -notmatch '^QT\.(\w+)\.(module|includes|depends)\s*=\s*(.*)$') { continue }
		$name, $field, $value = $Matches[1], $Matches[2], $Matches[3].Trim()
		if (-not $definitions.ContainsKey($name)) { $definitions[$name] = @{ pri = $pri.Name; module = ''; includes = ''; depends = '' } }
		$definitions[$name][$field] = $value
	}
}

# Dependency closure; qt.prf adds entrypoint_private to every Windows GUI app without it being listed
$keptModules = [System.Collections.Generic.HashSet[string]]::new()
$queue = [System.Collections.Generic.Queue[string]]::new()
foreach ($name in @($Modules) + 'entrypoint_private') { $queue.Enqueue($name) }
while ($queue.Count) {
	$name = $queue.Dequeue()
	if (-not $keptModules.Add($name)) { continue }
	if (-not $definitions.ContainsKey($name)) { throw "Module '$name' is not in this kit" }
	if ($definitions.ContainsKey("${name}_private")) { $queue.Enqueue("${name}_private") }
	foreach ($dependency in $definitions[$name].depends -split '\s+' | Where-Object { $_ }) { $queue.Enqueue($dependency) }
}

$libraryNames = @($keptModules | ForEach-Object { $definitions[$_].module } | Where-Object { $_ } | Sort-Object -Unique)
$includeDirs = @($keptModules | ForEach-Object { $definitions[$_].includes -split '\s+' } |
	ForEach-Object { if ($_ -match '^\$\$QT_MODULE_INCLUDE_BASE/([^/]+)') { $Matches[1] } } | Sort-Object -Unique)

$kitDlls = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($dll in Get-ChildItem $kitBin -Filter '*.dll') { [void]$kitDlls.Add($dll.Name) }

# bin: the module DLLs and the tools; the closure below adds the non-Qt DLLs they import
$keptBin = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($library in $libraryNames) {
	foreach ($dll in "$library.dll", "${library}d.dll") { if ($kitDlls.Contains($dll)) { [void]$keptBin.Add($dll) } }
}
foreach ($tool in $Tools) {
	if (-not (Test-Path (Join-Path $kitBin $tool))) { throw "Tool '$tool' is not in $kitBin" }
	[void]$keptBin.Add($tool)
}

# A plugin is kept only when every Qt DLL it imports belongs to a kept module
$pluginsDir = Join-Path $QtDir 'plugins'
$pluginImports = Get-DllImports @(Get-ChildItem $pluginsDir -Recurse -Filter '*.dll' | ForEach-Object FullName)
$keptPlugins = [System.Collections.Generic.List[string]]::new()
$droppedPlugins = [System.Collections.Generic.List[string]]::new()
$pending = [System.Collections.Generic.List[string]]::new()
foreach ($plugin in $pluginImports.Keys | Sort-Object) {
	$fromKit = @($pluginImports[$plugin] | Where-Object { $kitDlls.Contains($_) })
	$relative = [IO.Path]::GetRelativePath($QtDir, $plugin)
	if (@($fromKit | Where-Object { $_ -like 'Qt6*' -and -not $keptBin.Contains($_) }).Count) {
		$droppedPlugins.Add($relative)
		continue
	}
	$keptPlugins.Add($relative)
	$pending.AddRange([string[]]@($fromKit | Where-Object { $_ -notlike 'Qt6*' }))
}

# Import closure over bin: a non-Qt DLL from the kit is added, a Qt DLL outside the kept modules is an error
$scanned = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$addedThirdParty = [System.Collections.Generic.List[string]]::new()
foreach ($dll in $pending) { if ($keptBin.Add($dll)) { $addedThirdParty.Add($dll) } }
while ($true) {
	$toScan = @($keptBin | Where-Object { -not $scanned.Contains($_) })
	if (-not $toScan.Count) { break }
	foreach ($file in $toScan) { [void]$scanned.Add($file) }
	$binImports = Get-DllImports @($toScan | ForEach-Object { Join-Path $kitBin $_ })
	foreach ($importer in $binImports.Keys) {
		foreach ($import in $binImports[$importer] | Where-Object { $kitDlls.Contains($_) }) {
			if (-not $keptBin.Add($import)) { continue }
			if ($import -like 'Qt6*') { throw "$(Split-Path $importer -Leaf) imports $import, which belongs to no kept module: add that module to -Modules" }
			$addedThirdParty.Add($import)
		}
	}
}

$version = (& $qmake -query QT_VERSION).Trim()
$kitName = Split-Path $QtDir -Leaf
if (-not $OutFile) { $OutFile = "qt-$version-$kitName.7z" }
$OutFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutFile)
if (-not $NoArchive -and (Test-Path $OutFile)) { throw "$OutFile already exists" }

# Next to the archive; deleted only after a successful archive, so a failed or -NoArchive run leaves it for inspection
$staging = Join-Path (Split-Path $OutFile) "qt-$version-$kitName-staging"
if (Test-Path $staging) { throw "$staging already exists: delete it after inspecting it" }

function Copy-KitItem([string] $relative) {
	$destination = Join-Path $staging $relative
	New-Item -ItemType Directory -Force (Split-Path $destination) | Out-Null
	Copy-Item (Join-Path $QtDir $relative) $destination -Recurse
}

foreach ($file in $keptBin) { Copy-KitItem "bin\$file" }
Copy-KitItem 'bin\qt.conf'   # Prefix=.. makes the kit relocatable
foreach ($library in $libraryNames) {
	foreach ($file in "$library.lib", "$library.prl", "${library}d.lib", "${library}d.prl") {
		if (Test-Path (Join-Path $QtDir "lib\$file")) { Copy-KitItem "lib\$file" }
	}
}
foreach ($dir in $includeDirs) { Copy-KitItem "include\$dir" }
foreach ($item in Get-ChildItem (Join-Path $QtDir 'mkspecs') | Where-Object Name -ne 'modules') { Copy-KitItem "mkspecs\$($item.Name)" }
foreach ($pri in $keptModules | ForEach-Object { $definitions[$_].pri } | Sort-Object -Unique) { Copy-KitItem "mkspecs\modules\$pri" }
# windeployqt reads these for each module's plugin types
foreach ($json in Get-ChildItem (Join-Path $QtDir 'modules') -Filter '*.json' | Where-Object { $libraryNames -contains "Qt6$($_.BaseName)" }) {
	Copy-KitItem "modules\$($json.Name)"
}
foreach ($plugin in $keptPlugins) { Copy-KitItem $plugin }
# windeployqt reads it even with --no-translations, and warns when it is missing
if (Test-Path (Join-Path $QtDir 'translations\catalogs.json')) { Copy-KitItem 'translations\catalogs.json' }
Copy-Item $LicenseFile (Join-Path $staging 'LICENSE-Qt.txt')

$prefix = (& (Join-Path $staging 'bin\qmake.exe') -query QT_INSTALL_PREFIX).Trim()
if ([IO.Path]::GetFullPath($prefix) -ne [IO.Path]::GetFullPath($staging)) { throw "The staged qmake reports prefix $prefix, not $staging" }

$stagedBytes = (Get-ChildItem $staging -Recurse -File | Measure-Object Length -Sum).Sum
"Qt $version ($kitName), modules: $(($keptModules | Sort-Object) -join ' ')"
"Third-party DLLs added by imports: $(if ($addedThirdParty.Count) { $addedThirdParty -join ' ' } else { 'none' })"
"Plugins kept: $($keptPlugins.Count), dropped: $($droppedPlugins.Count)"
$droppedPlugins | ForEach-Object { "  dropped $_" }
"Staged: {0:N0} MB" -f ($stagedBytes / 1MB)

if ($NoArchive) {
	"Staging folder kept: $staging"
	return
}

New-ReleaseArchive $OutFile $staging '*'
Remove-Item $staging -Recurse -Force
