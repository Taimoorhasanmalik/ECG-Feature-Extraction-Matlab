param(
    [string]$VivadoRoot = 'C:\Xilinx\Vivado\2020.2',
    [switch]$SimulationOnly
)

$ErrorActionPreference = 'Stop'
$packageDir = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$vivadoBin = Join-Path $VivadoRoot 'bin'
$xvlog = Join-Path $vivadoBin 'xvlog.bat'
$xelab = Join-Path $vivadoBin 'xelab.bat'
$xsim = Join-Path $vivadoBin 'xsim.bat'
$vivado = Join-Path $vivadoBin 'vivado.bat'
$glbl = Join-Path $VivadoRoot 'data\verilog\src\glbl.v'
foreach ($required in @($xvlog, $xelab, $xsim, $vivado, $glbl)) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw "Required Vivado file not found: $required"
    }
}

$simulationDir = Join-Path ([System.IO.Path]::GetTempPath()) ('ecg_240_power_' + [guid]::NewGuid().ToString('N'))
$saifFile = Join-Path $packageDir 'power_comparison\mostly_normal_240.saif'
$saifBefore = if (Test-Path -LiteralPath $saifFile) {
    (Get-Item -LiteralPath $saifFile).LastWriteTimeUtc
} else {
    [datetime]::MinValue
}
New-Item -ItemType Directory -Path $simulationDir | Out-Null
Push-Location $simulationDir
try {
    $sources = @(
        'stage1_hdl\01_highpass_iir_filter.v',
        'stage1_hdl\02_window_sequencer.v',
        'rtl\stage2_filter_q29.v',
        'rtl\stage2_shared_hp1_q29.v',
        'rtl\stage2_classifier_gated_q.v',
        'rtl\shared_classifier_mac_q.v',
        'rtl\two_stage_shared_replay_top.v',
        'tb\mostly_normal_power_tb.sv'
    ) | ForEach-Object { Join-Path $packageDir $_ }
    & $xvlog -sv @sources $glbl
    if ($LASTEXITCODE -ne 0) { throw 'xvlog failed' }
    & $xelab -debug typical -timescale 1ns/1ps -L unisims_ver `
        mostly_normal_power_tb glbl -s mostly_normal_power_sim
    if ($LASTEXITCODE -ne 0) { throw 'xelab failed' }
    $saifScript = (Join-Path $packageDir 'scripts\mostly_normal_power_saif.tcl').Replace('\', '/')
    & $xsim mostly_normal_power_sim -tclbatch $saifScript
    if ($LASTEXITCODE -ne 0) { throw 'xsim failed' }
    if (-not (Test-Path -LiteralPath $saifFile) -or
        (Get-Item -LiteralPath $saifFile).LastWriteTimeUtc -le $saifBefore) {
        throw 'xsim did not regenerate the expected SAIF file'
    }
} finally {
    Pop-Location
}

if ($SimulationOnly) {
    Write-Host 'Paired simulation and SAIF generation completed.'
    return
}

foreach ($gateMode in @(1, 0)) {
    & $vivado -mode batch -source `
        (Join-Path $packageDir 'scripts\report_mostly_normal_gate_power.tcl') `
        -nojournal -nolog -tclargs $gateMode
    if ($LASTEXITCODE -ne 0) { throw "Vivado power build failed for CLOCK_GATING=$gateMode" }
}
Write-Host 'Gated and always-on 240-entry power reports completed.'
