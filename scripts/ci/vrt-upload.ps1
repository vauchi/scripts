# SPDX-FileCopyrightText: 2026 Mattia Egloff <mattia.egloff@pm.me>
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Upload screenshots to Visual Regression Tracker: the PowerShell twin of
# vrt-upload.sh for Windows shell runners, which have neither bash on PATH
# nor jq (vauchi/private#592). Same environment, same messages, same
# advisory contract: failures warn and never break the pipeline.
#
# Required environment: VRT_API_URL, VRT_API_KEY, VRT_SCREENSHOT_DIR,
# VRT_PLATFORM. Optional: VRT_PROJECT (vauchi), VRT_BRANCH, VRT_CI_BUILD_ID,
# VRT_DIFF_TOLERANCE (0.5). See vrt-upload.sh for the API reference.

$ErrorActionPreference = 'Stop'

foreach ($required in @('VRT_API_KEY', 'VRT_API_URL', 'VRT_SCREENSHOT_DIR')) {
    if (-not [Environment]::GetEnvironmentVariable($required)) {
        Write-Host "[vrt-upload] $required not set — skipping upload"
        exit 0
    }
}
$apiUrl = $env:VRT_API_URL.TrimEnd('/')
$root = $env:VRT_SCREENSHOT_DIR
if (-not (Test-Path $root -PathType Container)) {
    Write-Host "[vrt-upload] Screenshot directory not found: $root"
    exit 0
}
$root = (Resolve-Path $root).Path

$project = if ($env:VRT_PROJECT) { $env:VRT_PROJECT } else { 'vauchi' }
$branch = if ($env:VRT_BRANCH) { $env:VRT_BRANCH }
    elseif ($env:CI_MERGE_REQUEST_SOURCE_BRANCH_NAME) { $env:CI_MERGE_REQUEST_SOURCE_BRANCH_NAME }
    elseif ($env:CI_COMMIT_REF_NAME) { $env:CI_COMMIT_REF_NAME } else { 'main' }
$buildId = if ($env:VRT_CI_BUILD_ID) { $env:VRT_CI_BUILD_ID }
    elseif ($env:CI_PIPELINE_ID) { $env:CI_PIPELINE_ID } else { "local-$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())" }
$platform = if ($env:VRT_PLATFORM) { $env:VRT_PLATFORM } else { 'unknown' }
$tolerance = if ($env:VRT_DIFF_TOLERANCE) { [double]$env:VRT_DIFF_TOLERANCE } else { 0.5 }

# Same naming as vrt_test_name in vrt-upload.sh: "<root>/<rel>/<stem>.png"
# becomes "<rel> <stem>" with _, / and - collapsed to single spaces.
function Get-VrtTestName([string]$Png, [string]$Root) {
    $rel = $Png.Substring($Root.Length).TrimStart('\', '/')
    $rel = $rel -replace '\.png$', ''
    return (($rel -replace '[_/\\-]', ' ') -replace ' +', ' ').Trim()
}

# Depth <= 2, as `find -maxdepth 2`: the root and one level of theme subdirs.
$pngs = @(Get-ChildItem -Path $root -Filter *.png -File -Recurse -Depth 1 | Sort-Object FullName)
if ($pngs.Count -eq 0) {
    Write-Host "[vrt-upload] No PNG files in $root — skipping"
    exit 0
}

Write-Host "[vrt-upload] Uploading $($pngs.Count) screenshots from $platform"
Write-Host "[vrt-upload] Branch: $branch | Build: $buildId"

function Write-VrtDown([string]$Reason) {
    Write-Host "[vrt-upload] ================================================================"
    Write-Host "[vrt-upload] VRT IS DOWN: $Reason at $apiUrl"
    Write-Host "[vrt-upload] $($pngs.Count) screenshots from $platform were NOT uploaded."
    Write-Host "[vrt-upload] This job stays green (uploads are advisory). Alert: VrtApiDown;"
    Write-Host "[vrt-upload] recovery: journalctl -t vrt-health on the VRT host (vauchi/private#564)."
    Write-Host "[vrt-upload] ================================================================"
}

# Every call reads the status itself; a transport failure is status 0.
function Invoke-Vrt([string]$Method, [string]$Path, $Body) {
    $request = @{
        Method = $Method
        Uri = "$apiUrl$Path"
        Headers = @{ apiKey = $env:VRT_API_KEY }
        ContentType = 'application/json'
        SkipHttpErrorCheck = $true
        TimeoutSec = 60
    }
    if ($null -ne $Body) { $request.Body = ($Body | ConvertTo-Json -Compress) }
    try {
        $response = Invoke-WebRequest @request
        return @{ Status = [int]$response.StatusCode; Body = "$($response.Content)" }
    } catch {
        return @{ Status = 0; Body = "$($_.Exception.Message)" }
    }
}

# -- Step 0: health check --
try {
    $health = Invoke-WebRequest -Uri "$apiUrl/health" -SkipHttpErrorCheck -TimeoutSec 10
    $healthCode = [int]$health.StatusCode
} catch { $healthCode = 0 }
if ($healthCode -ne 200) {
    Write-VrtDown "health check answered HTTP $healthCode"
    exit 0
}

# -- Step 1: create build --
$build = Invoke-Vrt POST '/builds' @{ branchName = $branch; project = $project; ciBuildId = "$buildId-$platform" }
if ($build.Status -eq 0 -or $build.Status -ge 500) {
    Write-VrtDown "build creation answered HTTP $($build.Status)"
    exit 0
}
if ($build.Status -lt 200 -or $build.Status -ge 300) {
    Write-Host "[vrt-upload] WARNING: Build creation failed (HTTP $($build.Status))"
    Write-Host "[vrt-upload]   Response: $($build.Body)"
    exit 0
}
try { $buildJson = $build.Body | ConvertFrom-Json } catch { $buildJson = $null }
$vrtBuildId = "$($buildJson.id)"
$projectId = "$($buildJson.projectId)"
if (-not $vrtBuildId) {
    Write-Host "[vrt-upload] WARNING: No build ID in response — $($build.Body)"
    exit 0
}
Write-Host "[vrt-upload] Build created: $vrtBuildId"

# -- Step 2: upload screenshots --
$uploaded = 0
$failed = 0
foreach ($png in $pngs) {
    $name = Get-VrtTestName $png.FullName $root
    $upload = Invoke-Vrt POST '/test-runs' @{
        buildId = $vrtBuildId
        projectId = $projectId
        branchName = $branch
        name = "[$platform] $name"
        imageBase64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($png.FullName))
        os = $platform
        diffTollerancePercent = $tolerance
    }
    if ($upload.Status -lt 200 -or $upload.Status -ge 300) {
        Write-Host "[vrt-upload]   WARN: Failed to upload $($png.Name) (HTTP $($upload.Status))"
        if ($failed -eq 0) { Write-Host "[vrt-upload]   Detail: $($upload.Body)" }
        $failed++
        continue
    }
    $uploaded++
}

# -- Step 3: close build --
$close = Invoke-Vrt PATCH "/builds/$vrtBuildId" @{}
if ($close.Status -lt 200 -or $close.Status -ge 300) {
    Write-Host "[vrt-upload] WARNING: Failed to close build (HTTP $($close.Status))"
}

Write-Host "[vrt-upload] Done: $uploaded uploaded, $failed failed"
Write-Host "[vrt-upload] Dashboard: $apiUrl"
exit 0
