param([ValidateSet('initial','no_lut_bridge')][string]$Profile='initial')
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (@(Get-Process -Name td_commands_prompt,bw_commands_prompt -ErrorAction SilentlyContinue).Count) {
    throw 'Another TD/BW process is active'
}
$timingPath = Join-Path $root 'evidence/student_stage1_timing.json'
$timing = Get-Content -LiteralPath $timingPath -Raw -Encoding UTF8 | ConvertFrom-Json
$dbRecord = @($timing.artifacts | Where-Object { [IO.Path]::GetExtension($_.path) -eq '.db' })
if ($timing.result -ne 'PASS_CANONICAL_TIMING_PARSERS' -or $dbRecord.Count -ne 1) {
    throw 'Stage1 timing/DB receipt is incomplete'
}
$recordName = if ($Profile -eq 'initial') {'student_route_only'} else {'student_no_lut_bridge_routed'}
$recordPath = Join-Path $root "evidence/${recordName}_run.json"
$logPath = Join-Path $root "evidence/${recordName}_td.log"
if ((Test-Path -LiteralPath $recordPath) -or (Test-Path -LiteralPath $logPath)) {
    throw 'Refusing to overwrite a route-only run receipt or log'
}
$scriptName = if ($Profile -eq 'initial') {'route_only_student.tcl'} else {'route_student_no_lut_bridge.tcl'}
$script = Join-Path $PSScriptRoot $scriptName
$expectedDb = [IO.Path]::GetFullPath((Join-Path $root 'student_B/td_shengsheng_b_run/shengsheng_board_b_Runs/phy_1/shengsheng_board_b_pr.db'))
if ([IO.Path]::GetFullPath($dbRecord[0].path) -ne $expectedDb -or
    $dbRecord[0].sha256 -ne '606EF84D275E617B8F22A1916975BC7BE9A91ECF60C25C76F1092A8ADEC686E7') {
    throw 'Receipt DB does not match the reviewed Stage1 input path and full SHA256'
}
$before = (Get-FileHash -LiteralPath $dbRecord[0].path -Algorithm SHA256).Hash
if ($before -ne $dbRecord[0].sha256) { throw 'Stage1 DB identity mismatch' }
$inputDb = $expectedDb
$inputHash = $before
if ($Profile -eq 'no_lut_bridge') {
    $inputDb = Join-Path $root 'evidence/student_seed1_no_lut_bridge/parameter_on.db'
    $inputHash = '09B161F44F33A05134955D719104938788054514EEB3C8F4253A0520837CD312'
    if ((Get-FileHash -LiteralPath $inputDb -Algorithm SHA256).Hash -ne $inputHash) {
        throw 'Parameter-only DB copy identity mismatch'
    }
}
$record = [ordered]@{
    schema='controls_student_route_only_run/v1';state='RUNNING'
    started_utc=(Get-Date).ToUniversalTime().ToString('o')
    original_db_sha256=$before
    profile=$Profile;input_db=$inputDb;input_db_sha256=$inputHash
    original_stage1_receipt_sha256=(Get-FileHash -LiteralPath $timingPath -Algorithm SHA256).Hash
    script_sha256=(Get-FileHash -LiteralPath $script -Algorithm SHA256).Hash
    bitgen=$false;hardware='NOT_TESTED'
}
$record | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $recordPath -Encoding UTF8
Write-Output "STUDENT_ROUTE_ONLY_STARTED profile=$Profile no_bitgen=True"
& '<TD_INSTALL>/bin/td_commands_prompt.exe' ($script.Replace('\','/')) *> $logPath
$record['tool_exit_code']=$LASTEXITCODE
$record['finished_utc']=(Get-Date).ToUniversalTime().ToString('o')
$log = Get-Content -LiteralPath $logPath -Raw -Encoding UTF8
$complete = $log -match '(?m)^CONTROLS_STUDENT_ROUTE_ONLY_COMPLETE=1\s*$'
$errors = $log -match '(?im)\bERROR\s*:|couldn.t read file'
$preserved = (Get-FileHash -LiteralPath $dbRecord[0].path -Algorithm SHA256).Hash -eq $before -and
             (Get-FileHash -LiteralPath $inputDb -Algorithm SHA256).Hash -eq $inputHash
$record['original_db_preserved']=$preserved
$record['state']=if ($record.tool_exit_code -eq 0 -and $complete -and -not $errors -and $preserved) {'COMPLETE_REQUIRES_PRESERVATION_AND_RESET_GATES'} else {'FAIL_ROUTE_ONLY'}
$record | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $recordPath -Encoding UTF8
if ($record.state -eq 'FAIL_ROUTE_ONLY') { throw 'Route-only step failed; no bitgen authorized by this flow' }
Write-Output $record.state
