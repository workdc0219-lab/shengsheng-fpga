$ErrorActionPreference = 'Stop'
$candidateRoot = Split-Path -Parent $PSScriptRoot
$studentRoot = [IO.Path]::GetFullPath((Join-Path $candidateRoot 'student_B'))
$runRoot = [IO.Path]::GetFullPath((Join-Path $studentRoot 'td_shengsheng_b_run'))
if ([IO.Path]::GetDirectoryName($runRoot) -ne $studentRoot) { throw 'Student run escaped candidate' }
if (@(Get-Process -Name td_commands_prompt,bw_commands_prompt -ErrorAction SilentlyContinue).Count) {
    throw 'Another TD/BW process is active'
}
$stageScript = Join-Path $PSScriptRoot 'build_student_stage1.tcl'
$log = Join-Path $candidateRoot 'evidence/student_td_seed1_stage1.log'
$receiptPath = Join-Path $candidateRoot 'evidence/student_stage1_run.json'
if ((Test-Path -LiteralPath $log) -or (Test-Path -LiteralPath $receiptPath)) {
    throw 'Archive existing Stage1 log/receipt before starting a new attempt'
}
$snapshotPath = Join-Path $candidateRoot 'evidence/feature_source_scope.json'
$snapshot = Get-Content -LiteralPath $snapshotPath -Raw -Encoding UTF8 | ConvertFrom-Json
function Assert-CandidateInputs {
    foreach ($board in @('student_B','teacher_A')) {
        $records = $snapshot.changes.$board.input_snapshot
        foreach ($property in $records.PSObject.Properties) {
            $path = Join-Path (Join-Path $candidateRoot $board) $property.Name
            if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $property.Value) {
                throw "Candidate input changed: $board/$($property.Name)"
            }
        }
    }
}
Assert-CandidateInputs
$env:TD_PLACE_SEED = '1'
$env:TD_RUN_DIR = 'td_shengsheng_b_run'
$record = [ordered]@{
    schema='controls_student_stage1_run/v1'; state='RUNNING'
    started_utc=(Get-Date).ToUniversalTime().ToString('o')
    place_seed=1; run_directory=$runRoot
    script_sha256=(Get-FileHash -LiteralPath $stageScript -Algorithm SHA256).Hash
    input_snapshot_sha256=(Get-FileHash -LiteralPath $snapshotPath -Algorithm SHA256).Hash
    bitgen=$false; hardware='NOT_TESTED'
}
$record | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $receiptPath -Encoding UTF8
Write-Output "STUDENT_STAGE1_STARTED fixed_seed=1 no_bitgen=True run=$runRoot"
# TD parses its script argument as Tcl: native backslashes must be normalized.
& '<TD_INSTALL>/bin/td_commands_prompt.exe' ($stageScript.Replace('\','/')) *> $log
$record['tool_exit_code']=$LASTEXITCODE
$record['finished_utc']=(Get-Date).ToUniversalTime().ToString('o')
$text = Get-Content -LiteralPath $log -Raw -Encoding UTF8
$complete = $text -match '(?m)^CONTROLS_STUDENT_STAGE1_COMPLETE=1\s*$'
$hasError = $text -match '(?im)\bERROR\s*:|couldn.t read file'
$record['state']=if ($record.tool_exit_code -eq 0 -and $complete -and -not $hasError) {'STAGE1_COMPLETE_REQUIRES_GATES'} else {'FAIL_STAGE1'}
$record | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $receiptPath -Encoding UTF8
Assert-CandidateInputs
if ($record.state -ne 'STAGE1_COMPLETE_REQUIRES_GATES') { throw 'Student Stage1 did not complete; inspect recorded log' }
Write-Output 'STUDENT_STAGE1_COMPLETE_REQUIRES_GATES'
