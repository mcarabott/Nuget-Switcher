<#
.SYNOPSIS
    Swaps a PackageReference in every .csproj under the current repo for a ProjectReference
    to a local .csproj, and can undo the swap back to the original PackageReference.
    Run from anywhere inside the target repo; the repo root is auto-detected via git
    (override with -RepoRoot).

.EXAMPLE
    Switch-Nuget.ps1 -PackageId MyProject -ProjectPath D:\SourceCode\MyProject.csproj

.EXAMPLE
    Switch-Nuget.ps1 -PackageId MyProject -Undo
#>
[CmdletBinding(DefaultParameterSetName = 'Swap')]
param(
    [Parameter(Mandatory = $true)]
    [string]$PackageId,

    [Parameter(Mandatory = $true, ParameterSetName = 'Swap')]
    [string]$ProjectPath,

    [Parameter(Mandatory = $true, ParameterSetName = 'Undo')]
    [switch]$Undo,

    [string]$RepoRoot
)

$ErrorActionPreference = 'Stop'

if (-not $RepoRoot) {
    $gitRoot = git rev-parse --show-toplevel 2>$null
    $RepoRoot = if ($LASTEXITCODE -eq 0 -and $gitRoot) { ($gitRoot.Trim() -replace '/', '\') } else { $PWD.Path }
}

$manifestPath = Join-Path $RepoRoot '.nuget-switch-manifest.json'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Write-TextPreservingBom([string]$Path, [string]$Content) {
    $hasBom = $false
    $existing = [System.IO.File]::ReadAllBytes($Path)
    if ($existing.Length -ge 3 -and $existing[0] -eq 0xEF -and $existing[1] -eq 0xBB -and $existing[2] -eq 0xBF) {
        $hasBom = $true
    }
    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($hasBom)))
}

function Get-Manifest {
    if (Test-Path -LiteralPath $manifestPath) {
        $raw = [System.IO.File]::ReadAllText($manifestPath)
        if ($raw.Trim()) {
            $parsed = ConvertFrom-Json -InputObject $raw
            # Pipe through ForEach-Object to force one-at-a-time enumeration -
            # `return @(...)` on its own can hand back the array as a single
            # item instead of unrolling it, doubly-wrapping the result.
            return @($parsed | ForEach-Object { $_ })
        }
    }
    return @()
}

function Save-Manifest([array]$entries) {
    if ($entries.Count -eq 0) {
        if (Test-Path -LiteralPath $manifestPath) {
            Remove-Item -LiteralPath $manifestPath
        }
        return
    }
    $json = ConvertTo-Json -InputObject $entries -Depth 5
    [System.IO.File]::WriteAllText($manifestPath, $json, $utf8NoBom)
}

function Get-RelativePath([string]$FromDir, [string]$ToFile) {
    $fromFull = [System.IO.Path]::GetFullPath("$FromDir\")
    $toFull = [System.IO.Path]::GetFullPath($ToFile)
    $uriFrom = New-Object System.Uri($fromFull)
    $uriTo = New-Object System.Uri($toFull)
    $relative = $uriFrom.MakeRelativeUri($uriTo).ToString()
    return [System.Uri]::UnescapeDataString($relative).Replace('/', '\')
}

function Get-CsProjFiles([string]$Root) {
    Get-ChildItem -LiteralPath $Root -Filter '*.csproj' -Recurse |
        Where-Object { $_.FullName -notmatch '\\(bin|obj)\\' }
}

if ($Undo) {
    $manifest = @(Get-Manifest)
    $toUndo = @($manifest | Where-Object { $_.PackageId -eq $PackageId })

    if ($toUndo.Count -eq 0) {
        Write-Warning "No recorded swap found for package '$PackageId'. Nothing to undo."
        return
    }

    foreach ($entry in $toUndo) {
        $filePath = Join-Path $RepoRoot $entry.File
        $content = [System.IO.File]::ReadAllText($filePath)
        $updated = $content.Replace($entry.NewLine, $entry.OriginalLine)
        if ($updated -eq $content) {
            Write-Warning "Could not find expected ProjectReference line in $($entry.File); leaving file untouched."
            continue
        }
        Write-TextPreservingBom -Path $filePath -Content $updated
        Write-Host "Reverted $($entry.File)"
    }

    $remaining = @($manifest | Where-Object { $_.PackageId -ne $PackageId })
    Save-Manifest $remaining
    return
}

$fullProjectPath = (Resolve-Path -LiteralPath $ProjectPath).Path
$manifest = @(Get-Manifest)
$changedAny = $false

foreach ($file in Get-CsProjFiles -Root $RepoRoot) {
    $relPath = Get-RelativePath -FromDir $RepoRoot -ToFile $file.FullName

    if ($manifest | Where-Object { $_.File -eq $relPath -and $_.PackageId -eq $PackageId }) {
        Write-Host "Skipping (already swapped): $relPath"
        continue
    }

    $content = [System.IO.File]::ReadAllText($file.FullName)
    $escapedId = [regex]::Escape($PackageId)
    $pattern = "(?m)^([ \t]*)<PackageReference\s+Include=`"$escapedId`"[^>]*/?>[ \t]*(?=\r?$)"
    $regex = [System.Text.RegularExpressions.Regex]::new($pattern)
    $regexMatches = $regex.Matches($content)

    if ($regexMatches.Count -eq 0) {
        continue
    }

    $relProjectPath = Get-RelativePath -FromDir $file.DirectoryName -ToFile $fullProjectPath

    foreach ($m in $regexMatches) {
        $indent = $m.Groups[1].Value
        $manifest += [PSCustomObject]@{
            File          = $relPath
            PackageId     = $PackageId
            OriginalLine  = $m.Value
            NewLine       = "$indent<ProjectReference Include=`"$relProjectPath`" />"
        }
    }

    $newContent = $regex.Replace($content, { param($m)
        $indent = $m.Groups[1].Value
        "$indent<ProjectReference Include=`"$relProjectPath`" />"
    })
    Write-TextPreservingBom -Path $file.FullName -Content $newContent
    Write-Host "Swapped in $relPath -> $relProjectPath"
    $changedAny = $true
}

if (-not $changedAny) {
    Write-Warning "No PackageReference to '$PackageId' found in any .csproj under $RepoRoot."
}

Save-Manifest $manifest
