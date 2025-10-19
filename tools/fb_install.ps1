# tools/fb_install.ps1
Param(
    [string]$ConfigFile = "Unity-Firebase-Auto-Setup/tools/firebase_tgz.config.jsonc",
    [switch]$Force,
    [switch]$NoCleanup
)

function Save-JsonNoBom([object]$json, [string]$path) {
    $txt = $json | ConvertTo-Json -Depth 100
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($path, $txt, $utf8NoBom)
}

function Read-JsonC([string]$path) {
    if (-not (Test-Path $path)) { throw "Config not found: $path" }
    $raw = Get-Content $path -Raw -Encoding UTF8
    # remove // line comments
    $raw = ($raw -split "`n" | Where-Object {$_ -notmatch '^\s*//'} ) -join "`n"
    return ($raw | ConvertFrom-Json)
}

try {
    $cfg = Read-JsonC $ConfigFile
} catch {
    Write-Host $_.Exception.Message
    Write-Host "Expected at Unity-Firebase-Auto-Setup/tools/firebase_tgz.config.jsonc (or pass -ConfigFile)."
    exit 1
}

$BaseUrl  = ($cfg.base_url.TrimEnd('/') + "/")
$DestRoot = $cfg.dest_root
$Manifest = $cfg.manifest
$Modules  = @(); foreach ($m in $cfg.modules) { $Modules += $m }

New-Item -ItemType Directory -Force -Path $DestRoot | Out-Null

# Build ordered list: app first if enabled
$Ordered = New-Object System.Collections.ArrayList
foreach ($m in $Modules) { if ($m.enabled -and $m.id -eq "com.google.firebase.app") { [void]$Ordered.Add($m) } }
foreach ($m in $Modules) { if ($m.enabled -and $m.id -ne "com.google.firebase.app") { [void]$Ordered.Add($m) } }

function Download-And-Unpack([string]$id, [string]$version) {
    if ([string]::IsNullOrWhiteSpace($version)) { throw "Version is required for enabled module: $id" }
    $url  = $BaseUrl + $id + "/" + $id + "-" + $version + ".tgz"
    $dest = Join-Path $DestRoot $id
    $pkgjson = Join-Path $dest "package.json"

    if (-not $Force.IsPresent -and (Test-Path $pkgjson)) {
        Write-Host ("- " + $id + " already installed -> skip (use -Force to reinstall)")
        return
    }

    $tmp = New-Item -ItemType Directory -Path ([System.IO.Path]::GetTempPath() + [System.Guid]::NewGuid()) -Force
    try {
        Write-Host ("Downloading " + $id + " (" + $version + ")")
        $tgz = Join-Path $tmp "pkg.tgz"
        Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $tgz | Out-Null

        if (Test-Path $dest) { Remove-Item -Recurse -Force $dest }
        New-Item -ItemType Directory -Force -Path $dest | Out-Null

        tar -xzf $tgz -C $tmp
        if (Test-Path (Join-Path $tmp "package")) {
            Copy-Item -Recurse -Force (Join-Path $tmp "package\*") $dest
        } else {
            Copy-Item -Recurse -Force (Join-Path $tmp "*") $dest -ErrorAction SilentlyContinue
        }
        Write-Host ("OK  " + $id + " -> " + $dest)
    } finally {
        if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp }
    }
}

function Ensure-ManifestDep([string]$id) {
    $value = "file:../$DestRoot/$id"
    if (-not (Test-Path $Manifest)) { throw "Manifest not found: $Manifest (open the Unity project once to generate it)" }

    $json = Get-Content $Manifest -Raw | ConvertFrom-Json

    if (-not $json.PSObject.Properties.Name.Contains("dependencies") -or -not $json.dependencies) {
        $deps = New-Object PSObject
        if ($json.PSObject.Properties.Name.Contains("dependencies")) { $json.dependencies = $deps }
        else { $json | Add-Member -NotePropertyName dependencies -NotePropertyValue $deps }
    }

    $existing = $json.dependencies.PSObject.Properties[$id]
    $write = $true
    if ($existing) {
        if ($existing.Value -eq $value) {
            $write = $false
            Write-Host ("- manifest already contains " + $id)
        } else {
            $json.dependencies | Add-Member -Force -NotePropertyName $id -NotePropertyValue $value
        }
    } else {
        $json.dependencies | Add-Member -NotePropertyName $id -NotePropertyValue $value
    }

    if ($write) {
        Save-JsonNoBom $json $Manifest
        Write-Host ("OK  manifest: " + $id + " -> " + $value)
    }
}

function Cleanup-Unused() {
    if (-not (Test-Path $Manifest)) { Write-Host "Manifest not found, skip cleanup."; return }
    $json = Get-Content $Manifest -Raw | ConvertFrom-Json
    if (-not $json.dependencies) { Write-Host "Cleanup: nothing to remove"; return }

    $active = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($m in $Modules) { if ($m.enabled) { $null = $active.Add($m.id) } }

    $toRemove = New-Object System.Collections.ArrayList
    foreach ($prop in $json.dependencies.PSObject.Properties) {
        $k = $prop.Name
        if ($k -like "com.google.firebase.*" -or $k -eq "com.google.external-dependency-manager") {
            if (-not $active.Contains($k)) { [void]$toRemove.Add($k) }
        }
    }

    if ($toRemove.Count -gt 0) {
        foreach ($k in $toRemove) { [void]$json.dependencies.PSObject.Properties.Remove($k) }
        Save-JsonNoBom $json $Manifest
        Write-Host ("Removed from manifest: " + ($toRemove -join ", "))

        foreach ($k in $toRemove) {
            $dir = Join-Path $DestRoot $k
            if (Test-Path $dir) { Remove-Item -Recurse -Force $dir; Write-Host ("Removed folder: " + $dir) }
        }
    } else {
        Write-Host "Cleanup: nothing to remove"
    }
}

Write-Host "== Unity Firebase Auto Setup (PowerShell) =="
Write-Host ("Config = " + $ConfigFile)
Write-Host ("Force = " + ($Force.IsPresent))
Write-Host ("Cleanup = " + (-not $NoCleanup.IsPresent))
Write-Host ("Dest = " + $DestRoot)

# 1) Download & unpack enabled (app first)
foreach ($m in $Ordered) {
    Download-And-Unpack $m.id $m.version
    Ensure-ManifestDep $m.id
}

# 2) Ensure disabled modules are removed (cleanup), unless skipped
if (-not $NoCleanup.IsPresent) {
    Cleanup-Unused
} else {
    Write-Host "Skipping cleanup (flag -NoCleanup)"
}

Write-Host "== Done =="