$ErrorActionPreference = 'Stop'
$package = Split-Path -Parent $PSScriptRoot
$simWork = Join-Path $env:TEMP 'ecg_two_stage_models_work'
$vectors600 = Join-Path $env:TEMP 'ecg_two_stage_vectors'
$vectors1200 = Join-Path $env:TEMP 'ecg_two_stage_vectors_1200'
$vectorsStress = Join-Path $env:TEMP 'ecg_two_stage_vectors_stress'
$vectorsShared = Join-Path $env:TEMP 'ecg_two_stage_vectors_shared'
$vectorsSharedReactivation = Join-Path $env:TEMP 'ecg_two_stage_vectors_shared_reactivation'
$vectorsSharedStress = Join-Path $env:TEMP 'ecg_two_stage_vectors_shared_stress'
$vectorsSharedPersistent = Join-Path $env:TEMP 'ecg_two_stage_vectors_shared_persistent'
$vectorsCandidate = Join-Path $env:TEMP 'ecg_two_stage_vectors_shared_hp1'
$vectorsCandidatePersistent = Join-Path $env:TEMP 'ecg_two_stage_vectors_shared_hp1_persistent'
$vectorsCandidateReactivation = Join-Path $env:TEMP 'ecg_two_stage_vectors_shared_hp1_reactivation'

if (!(Test-Path -LiteralPath $simWork)) { & vlib $simWork | Out-Null }
$stage1 = @(Get-ChildItem -LiteralPath (Join-Path $package 'stage1_hdl') -Filter '*.v' | ForEach-Object FullName)
$rtl = @(Get-ChildItem -LiteralPath (Join-Path $package 'rtl') -Filter '*.v' | ForEach-Object FullName)
$tb = @(Get-ChildItem -LiteralPath (Join-Path $package 'tb') -Filter '*.sv' | ForEach-Object FullName)
& vlog -sv -work $simWork $stage1 $rtl (Join-Path $package 'tb\BUFGCE.v') $tb
if ($LASTEXITCODE -ne 0) { throw 'ModelSim compilation failed' }

function Invoke-EcgTest([string] $top, [string] $vectorDir = '', [int] $sampleCount = 0, [int] $minArms = 0, [int] $minDrains = 0, [int] $initialPhase = 0, [int] $sharedHp1 = 0, [int] $clockHz = 0, [int] $deepHistory = 0, [int] $stage1FullRate = 0) {
    $args = @('-c','-lib',$simWork,$top)
    if ($vectorDir) { $args += "+VECTOR_DIR=$vectorDir" }
    if ($sampleCount) { $args += "-gN=$sampleCount" }
    if ($minArms) { $args += "+MIN_ARMS=$minArms" }
    if ($minDrains) { $args += "+MIN_DRAINS=$minDrains" }
    if ($initialPhase) { $args += "-gINITIAL_PHASE=$initialPhase" }
    if ($sharedHp1) { $args += "-gSHARED_HP1_MODEL=$sharedHp1" }
    if ($clockHz) { $args += "-gCLOCK_HZ=$clockHz" }
    if ($deepHistory) { $args += "-gDEEP_HISTORY=$deepHistory" }
    if ($stage1FullRate) { $args += "-gSTAGE1_FULL_RATE=$stage1FullRate" }
    $args += @('-do','run -all; quit -f')
    $result = & vsim @args 2>&1
    $result | Select-String -Pattern 'PASS:|Fatal|Error:'
    if ($LASTEXITCODE -ne 0 -or !($result -match 'PASS:')) {
        throw "ModelSim test failed: $top"
    }
}

& python (Join-Path $package 'reference\fixed_stage2.py') $vectors600 --count 600
if ($LASTEXITCODE -ne 0) { throw 'Vector generation failed' }
Invoke-EcgTest 'stage2_features_smoke_tb'
Invoke-EcgTest 'stage2_reference_tb' $vectors600
Invoke-EcgTest 'stage2_classifier_reference_tb' $vectors600
& python (Join-Path $package 'reference\fixed_stage2.py') $vectorsStress --count 600 --mode stress
if ($LASTEXITCODE -ne 0) { throw 'Stress-vector generation failed' }
Invoke-EcgTest 'stage2_reference_tb' $vectorsStress
& python (Join-Path $package 'reference\fixed_stage2.py') $vectors1200 --count 1200
if ($LASTEXITCODE -ne 0) { throw 'Vector generation failed' }
Invoke-EcgTest 'two_stage_reference_tb' $vectors1200
& python (Join-Path $package 'reference\fixed_stage2.py') $vectorsShared --count 1200 --shared-frontend
if ($LASTEXITCODE -ne 0) { throw 'Shared-front-end vector generation failed' }
Invoke-EcgTest 'two_stage_shared_reference_tb' $vectorsShared
& python (Join-Path $package 'reference\fixed_stage2.py') $vectorsSharedPersistent --count 1200 --mode persistent --shared-frontend
if ($LASTEXITCODE -ne 0) { throw 'Shared-front-end persistent generation failed' }
Invoke-EcgTest 'two_stage_shared_reference_tb' $vectorsSharedPersistent
Invoke-EcgTest 'two_stage_shared_reference_tb' $vectorsSharedPersistent 1200 1 0 500
& python (Join-Path $package 'reference\fixed_stage2.py') $vectorsSharedReactivation --count 3600 --mode reactivation --shared-frontend
if ($LASTEXITCODE -ne 0) { throw 'Shared-front-end reactivation generation failed' }
Invoke-EcgTest 'two_stage_shared_reference_tb' $vectorsSharedReactivation 3600 2 1
& python (Join-Path $package 'reference\fixed_stage2.py') $vectorsSharedStress --count 1200 --mode stress --shared-frontend
if ($LASTEXITCODE -ne 0) { throw 'Shared-front-end stress generation failed' }
Invoke-EcgTest 'two_stage_shared_reference_tb' $vectorsSharedStress
& python (Join-Path $package 'reference\fixed_shared_hp1.py') $vectorsCandidate --count 1200
if ($LASTEXITCODE -ne 0) { throw 'Candidate vector generation failed' }
Invoke-EcgTest 'two_stage_shared_reference_tb' $vectorsCandidate 1200 1 0 0 1 100000
Invoke-EcgTest 'two_stage_shared_reference_tb' $vectorsCandidate 1200 1 0 0 1 100000 0 1
Invoke-EcgTest 'clock_gate_equivalence_tb' $vectorsCandidate 1200
Invoke-EcgTest 'two_stage_shared_reference_tb' $vectorsCandidate 1200 1 0 50000 1 100000
Invoke-EcgTest 'two_stage_shared_reference_tb' $vectorsCandidate 1200 1 0 0 1 1000 1
& python (Join-Path $package 'reference\fixed_shared_hp1.py') $vectorsCandidatePersistent --count 1200 --mode persistent
if ($LASTEXITCODE -ne 0) { throw 'Candidate persistent vector generation failed' }
Invoke-EcgTest 'two_stage_shared_reference_tb' $vectorsCandidatePersistent 1200 1 0 0 1 100000
Invoke-EcgTest 'two_stage_shared_reference_tb' $vectorsCandidatePersistent 1200 1 0 0 1 1000 1
& python (Join-Path $package 'reference\fixed_shared_hp1.py') $vectorsCandidateReactivation --count 3600 --mode reactivation
if ($LASTEXITCODE -ne 0) { throw 'Candidate reactivation vector generation failed' }
Invoke-EcgTest 'two_stage_shared_reference_tb' $vectorsCandidateReactivation 3600 2 1 0 1 100000
Invoke-EcgTest 'two_stage_shared_reference_tb' $vectorsCandidateReactivation 3600 2 1 0 1 100000 0 1
Invoke-EcgTest 'two_stage_shared_reference_tb' $vectorsCandidateReactivation 3600 2 1 0 1 1000 1
Invoke-EcgTest 'board_demo_tb'
Write-Host 'All two-stage RTL tests passed.'
