$ErrorActionPreference = 'Stop'
$package = Split-Path -Parent $PSScriptRoot
$simWork = Join-Path $env:TEMP 'ecg_two_stage_adaptive_work'
if (!(Test-Path -LiteralPath $simWork)) { & vlib $simWork | Out-Null }
$sources = @(Get-ChildItem -LiteralPath "$package\stage1_hdl","$package\rtl" -Filter '*.v' | ForEach-Object FullName)
& vlog -sv -work $simWork $sources "$package\tb\BUFGCE.v" "$package\tb\two_stage_shared_reference_tb.sv" "$package\tb\adaptive_clock_tb.sv"
if ($LASTEXITCODE -ne 0) { throw 'Adaptive compile failed' }
function Invoke-AdaptiveTest([string] $top, [string[]] $extraArgs) {
    $logFile = Join-Path $simWork ($top+'_last.log')
    $result = & vsim -c -l $logFile -lib $simWork $top @extraArgs -do 'run -all; quit -f' 2>&1
    $result | Select-String -Pattern 'PASS:|CLOCK:|ACTIVITY:|Fatal|Error:'
    if ($LASTEXITCODE -ne 0 -or !($result -match 'PASS:') -or ($result -match '\*\* Fatal')) {
        throw "Adaptive test failed: $top $extraArgs"
    }
}
Invoke-AdaptiveTest 'adaptive_clock_tb' @()
foreach ($case in @(
    @{ Mode='mixed'; Count=1200; Phase=0; FullRate=0; Arms=1; Drains=0 },
    @{ Mode='mixed'; Count=1200; Phase=199999; FullRate=0; Arms=1; Drains=0 },
    @{ Mode='stress'; Count=1200; Phase=0; FullRate=0; Arms=0; Drains=0 },
    @{ Mode='reactivation'; Count=3600; Phase=0; FullRate=0; Arms=2; Drains=1 },
    @{ Mode='reactivation'; Count=3600; Phase=199999; FullRate=1; Arms=2; Drains=1 }
)) {
    $vectors = Join-Path $env:TEMP ('ecg_adaptive_'+$case.Mode)
    & python "$package\reference\fixed_shared_hp1.py" $vectors --count $case.Count --mode $case.Mode
    if ($LASTEXITCODE -ne 0) { throw 'Vector generation failed' }
    Write-Host "Case: $($case.Mode) phase=$($case.Phase) full_rate=$($case.FullRate)"
    Invoke-AdaptiveTest 'two_stage_shared_reference_tb' @(
        '-gADAPTIVE=1','-gSHARED_HP1_MODEL=1','-gCLOCK_HZ=100000',
        "-gN=$($case.Count)","-gINITIAL_PHASE=$($case.Phase)",
        "-gSTAGE1_FULL_RATE=$($case.FullRate)","+VECTOR_DIR=$vectors",
        "+MIN_ARMS=$($case.Arms)","+MIN_DRAINS=$($case.Drains)")
}
Write-Host 'All adaptive-clock tests passed.'
