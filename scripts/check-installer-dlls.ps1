param(
    [string]$BuildDir = (Join-Path (Split-Path -Parent $PSScriptRoot) "build\Release"),
    [string]$IssPath  = (Join-Path $PSScriptRoot "airscreen.iss")
)
$ErrorActionPreference = "Stop"

$errors = New-Object System.Collections.ArrayList

# 1. Locate dumpbin.exe: newest VS install first, then PATH.
function Find-Dumpbin {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path -LiteralPath $vswhere) {
        $vsPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath | Select-Object -First 1
        if ($vsPath) {
            $candidates = Get-ChildItem -Path (Join-Path $vsPath "VC\Tools\MSVC\*\bin\Hostx64\x64\dumpbin.exe") -File -ErrorAction SilentlyContinue | Sort-Object FullName
            $last = $candidates | Select-Object -Last 1
            if ($last) {
                return $last.FullName
            }
        }
    }
    $cmd = Get-Command dumpbin -ErrorAction SilentlyContinue
    if ($cmd) {
        return $cmd.Source
    }
    throw "dumpbin.exe not found. Install the Visual Studio C++ tools or run from a Developer PowerShell."
}

$dumpbin = Find-Dumpbin
Write-Host "Using dumpbin: $dumpbin"

# 2. Parse the [Files] section of the installer script.
if (-not (Test-Path -LiteralPath $IssPath)) {
    throw "Installer script not found: $IssPath"
}
$buildPrefix = '{#BuildDir}\'
$crtPrefix   = '{#CrtDir}\'
$buildPatterns = New-Object System.Collections.ArrayList
$crtNames      = New-Object System.Collections.ArrayList
$section = ""
foreach ($line in (Get-Content -LiteralPath $IssPath)) {
    if ($line -match '^\s*\[(.+?)\]\s*$') {
        $section = $Matches[1]
        continue
    }
    if ($section -ne "Files") {
        continue
    }
    if ($line -match '^\s*Source:\s*"([^"]+)"') {
        $src = $Matches[1]
        if ($src.StartsWith($buildPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            [void]$buildPatterns.Add($src.Substring($buildPrefix.Length))
        }
        elseif ($src.StartsWith($crtPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            [void]$crtNames.Add($src.Substring($crtPrefix.Length))
        }
    }
}

# 3. Build the shipped set from BuildDir.
if (-not (Test-Path -LiteralPath $BuildDir)) {
    throw "Build directory not found: $BuildDir"
}
$buildFiles = @{}
foreach ($f in (Get-ChildItem -LiteralPath $BuildDir -File)) {
    $buildFiles[$f.Name] = $f.FullName
}
if (-not $buildFiles.ContainsKey("AirScreen.exe")) {
    throw "AirScreen.exe not found in $BuildDir"
}

$shipped = @{}
foreach ($pattern in $buildPatterns) {
    $found = @(Get-ChildItem -LiteralPath $BuildDir -Filter $pattern -File)
    if ($found.Count -eq 0) {
        [void]$errors.Add("pattern $pattern matches nothing in BuildDir")
    }
    foreach ($f in $found) {
        $shipped[$f.Name] = $f.FullName
    }
}

# 4. Breadth-first dependency walk starting from every shipped exe/dll.
$visited = @{}
$queue = New-Object System.Collections.Queue
foreach ($name in ($shipped.Keys | Sort-Object)) {
    if ($name -match '\.(exe|dll)$') {
        $visited[$name] = $true
        $queue.Enqueue($name)
    }
}

$apiSetPattern = '^(api-ms-win-|ext-ms-win-)'   # includes api-ms-win-crt-*: UCRT ships with Windows 10+
$crtPattern    = '^(msvcp|vcruntime|concrt|vccorlib)\d'

while ($queue.Count -gt 0) {
    $name = [string]$queue.Dequeue()
    $path = $shipped[$name]

    $raw = @(& $dumpbin /nologo /dependents $path)
    if ($LASTEXITCODE -ne 0) {
        [void]$errors.Add("dumpbin failed on $name (exit code $LASTEXITCODE)")
        continue
    }

    $deps = @()
    foreach ($l in $raw) {
        $t = ([string]$l).Trim()
        if ($t -match '^[\w.\-]+\.dll$') {
            $deps += $t
        }
    }

    $nonSystem = @()
    foreach ($d in ($deps | Select-Object -Unique)) {
        if ($d -match $apiSetPattern) {
            continue
        }
        if ($d -match $crtPattern) {
            $nonSystem += "$d (CRT)"
            if (-not ($crtNames -contains $d)) {
                [void]$errors.Add("CRT DLL $d needed by $name is not in airscreen.iss")
            }
            continue
        }
        if ($buildFiles.ContainsKey($d)) {
            $nonSystem += "$d (app-local)"
            if (-not $shipped.ContainsKey($d)) {
                [void]$errors.Add("$d (needed by $name) is in BuildDir but not shipped by airscreen.iss")
            }
            elseif (-not $visited.ContainsKey($d)) {
                $visited[$d] = $true
                $queue.Enqueue($d)
            }
            continue
        }
        # Not app-local: must be a system DLL, or the installed app won't load.
        if (-not (Test-Path -LiteralPath (Join-Path $env:windir "System32\$d"))) {
            [void]$errors.Add("$d (needed by $name) is neither in BuildDir nor in System32")
        }
    }

    Write-Host "Checked $name"
    if ($nonSystem.Count -gt 0) {
        Write-Host "    non-system deps: $($nonSystem -join ', ')"
    }
    else {
        Write-Host "    non-system deps: none"
    }
}

# 5. Report.
if ($errors.Count -gt 0) {
    foreach ($e in $errors) {
        Write-Host "ERROR: $e"
    }
    exit 1
}
Write-Host "Installer DLL check passed."
exit 0
