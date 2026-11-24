# Compresses $Inputs into a new 7z archive and prints its size and SHA-256.
# $Inputs are paths, wildcards or @listfiles (UTF-8) relative to $Root; the archive stores paths relative to $Root.
function New-ReleaseArchive([string] $OutFile, [string] $Root, [string[]] $Inputs) {
	$sevenZip = Get-Command 7z.exe -ErrorAction SilentlyContinue
	$sevenZip = if ($sevenZip) { $sevenZip.Source } else { Join-Path $env:ProgramFiles '7-Zip\7z.exe' }
	Push-Location -LiteralPath $Root
	try { & $sevenZip a -t7z -mx=9 -mmt=on -scsUTF-8 $OutFile @Inputs | Out-Null }
	finally { Pop-Location }
	if ($LASTEXITCODE) { throw "7-Zip failed with exit code $LASTEXITCODE" }

	"Archive: $OutFile, {0:N0} MB" -f ((Get-Item $OutFile).Length / 1MB)
	"SHA-256: $((Get-FileHash $OutFile -Algorithm SHA256).Hash.ToLowerInvariant())"
}
