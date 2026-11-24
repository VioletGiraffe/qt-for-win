# qt-for-win

Trimmed Qt kits for Windows (MSVC, x64), published as GitHub Release assets, for use in CI or elsewhere.
Each archive holds the actual Qt dev install, with all the necessary binaries, tools, plugins and headers - and none of the bloat.

## Disclaimer

- This is an unofficial, personal repository. It is not affiliated with, endorsed by or supported by The Qt Company.
- Qt is a trademark of The Qt Company Ltd.
- The archives contain unmodified files from the official open-source Qt distribution, repackaged as a subset; nothing is rebuilt, edited or patched.
- They are provided as-is, without warranty of any kind, and exist for my own needs. Releases may be replaced or removed at any time.

## License

- The Qt binaries are licensed by The Qt Company under the GNU LGPL v3 or the GNU GPL, depending on the component; the Qt sources state the terms of each file.
- Each kit archive carries the GPL v3 and LGPL v3 texts as `LICENSE-Qt.txt`; the source archive keeps the license files of the Qt sources.
- The corresponding source code of each Qt release is available from the Qt Project:
  https://download.qt.io/official_releases/qt/ (the `single` folder of each version holds the full source archive).

## Packing a kit

Requires PowerShell 7, the MSVC build tools (for `dumpbin`) and 7-Zip. The kit must come from the Qt installer, which keeps the license texts in `<Qt root>\Licenses`; otherwise pass `-LicenseFile`.

```powershell
pwsh pack_qt_kit.ps1 -QtDir C:\Qt\6.11.2\msvc2022_64 -Modules core,gui,widgets,svg,network,multimedia,multimediawidgets
```

- `-Modules` takes qmake module names, as in `QT +=`. Dependencies and each module's `_private` twin are added from the kit's own module definitions.
- A plugin is included only when every Qt DLL it imports belongs to a kept module.
- The run fails if a kept binary imports a Qt DLL outside the kept modules, and names which module to add.
- The script prints the archive's size and SHA-256. `-NoArchive` stops after the checks and keeps the staging folder for inspection.

## Packing the sources

Requires PowerShell 7 and 7-Zip, and the Sources component of the Qt installer.

```powershell
pwsh pack_qt_sources.ps1 -SourceDir C:\Qt\6.12.1\Src
```

The script prints the archive's size and SHA-256. `-NoArchive` stops after the selection and keeps the file list for inspection.

## Using a kit in CI

The archive has the kit at its root: extract it into an empty folder and set `QT_ROOT_DIR` to that folder.

```yaml
- name: Windows - install Qt
  shell: pwsh
  env:
    GH_TOKEN: ${{ github.token }}
  run: |
    $archive = 'qt-6.11.2-msvc2022_64.7z'
    gh release download <tag> --repo VioletGiraffe/qt-for-win --pattern $archive
    if ((Get-FileHash $archive -Algorithm SHA256).Hash -ne '<sha-256>') { throw "$archive does not match its checksum" }
    7z x $archive "-o$env:RUNNER_TEMP\Qt" | Out-Null
    "QT_ROOT_DIR=$env:RUNNER_TEMP\Qt" >> $env:GITHUB_ENV
    "$env:RUNNER_TEMP\Qt\bin" >> $env:GITHUB_PATH
```
