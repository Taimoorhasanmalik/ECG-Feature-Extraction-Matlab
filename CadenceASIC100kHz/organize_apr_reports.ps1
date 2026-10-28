param([Parameter(Mandatory = $true)][string]$ReportDirectory)

# Mechanical report conversion only; original compressed tool files stay intact.
$ErrorActionPreference = 'Stop'
$reportRoot = (Resolve-Path -LiteralPath $ReportDirectory).Path
$verified = 0
foreach ($line in Get-Content -LiteralPath (Join-Path $reportRoot 'SHA256SUMS')) {
    if ($line -notmatch '^([a-f0-9]{64})  \./(.+)$') {
        throw ('Invalid original-file manifest entry: ' + $line)
    }
    $expected = $Matches[1]
    $relative = $Matches[2]
    $target = [IO.Path]::GetFullPath((Join-Path $reportRoot $relative))
    if (-not $target.StartsWith($reportRoot + [IO.Path]::DirectorySeparatorChar,
            [StringComparison]::OrdinalIgnoreCase)) { throw 'Manifest path escapes package' }
    if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expected) {
        throw ('Original tool report checksum mismatch: ' + $relative)
    }
    $verified++
}

$friendly = @{
    'final.summary.gz' = 'setup_summary.rpt'
    'final_hold.summary.gz' = 'hold_summary.rpt'
    'final_all.tarpt.gz' = 'setup_paths_all.rpt'
    'final_all_hold.tarpt.gz' = 'hold_paths_all.rpt'
}
$rows = Import-Csv -LiteralPath (Join-Path $reportRoot 'SUMMARY.csv')
foreach ($caseName in @('gated_500Hz', 'ungated_100kHz')) {
    $caseRoot = Join-Path $reportRoot $caseName
    $result = Get-Content -LiteralPath (Join-Path $caseRoot 'provenance/case_result.json') -Raw | ConvertFrom-Json
    $row = @($rows | Where-Object { $_.case -eq $caseName })
    if ($row.Count -ne 1) { throw 'Missing or duplicate summary row' }
    foreach ($pair in @(
        @('dynamic_uW', $result.power.dynamic_uw),
        @('leakage_uW', $result.power.leakage_uw),
        @('total_uW', $result.power.total_uw),
        @('postroute_non_filler_area_um2', $result.area.non_filler_area_um2),
        @('setup_WNS_ns', $result.timing.setup_wns_ns),
        @('hold_WNS_ns', $result.timing.hold_wns_ns)
    )) {
        if ([math]::Abs([double]$row[0].($pair[0]) - [double]$pair[1]) -gt 0.0000001) {
            throw ('Summary does not match accepted result: ' + $caseName + '/' + $pair[0])
        }
    }
    foreach ($source in Get-ChildItem -LiteralPath (Join-Path $caseRoot 'timing/raw_compressed') -File -Filter '*.gz') {
        $outputName = $friendly[$source.Name]
        if (-not $outputName) { $outputName = $source.BaseName -replace '\.tarpt$', ''; $outputName += '.rpt' }
        $destination = Join-Path $caseRoot ('timing/' + $outputName)
        $inputStream = [IO.File]::OpenRead($source.FullName)
        try {
            $gzip = New-Object IO.Compression.GZipStream($inputStream, [IO.Compression.CompressionMode]::Decompress)
            try {
                $outputStream = [IO.File]::Create($destination)
                try { $gzip.CopyTo($outputStream) } finally { $outputStream.Dispose() }
            } finally { $gzip.Dispose() }
        } finally { $inputStream.Dispose() }
    }
}

$manifestPath = Join-Path $reportRoot 'MANIFEST_SHA256.csv'
$manifestRows = foreach ($entry in Get-ChildItem -LiteralPath $reportRoot -File -Recurse | Sort-Object FullName) {
    if ($entry.FullName -ne $manifestPath) {
        [PSCustomObject]@{
            path = $entry.FullName.Substring($reportRoot.Length + 1).Replace('\', '/')
            bytes = $entry.Length
            sha256 = (Get-FileHash -LiteralPath $entry.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
}
$manifestRows | Export-Csv -LiteralPath $manifestPath -NoTypeInformation -Encoding ASCII
Write-Output ('Verified {0} original files; summary values match both accepted cases.' -f $verified)
Write-Output ('Readable timing reports and full manifest ready: ' + $reportRoot)
