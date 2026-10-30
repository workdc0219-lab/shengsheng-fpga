param([string]$PhyRoot = '')
$ErrorActionPreference = 'Stop'
$candidateRoot = Split-Path -Parent $PSScriptRoot
$canonical = Join-Path $candidateRoot 'student_B/board_b/scripts/run_td.ps1'
if (-not $PhyRoot) {
    $PhyRoot = Join-Path $candidateRoot 'student_B/td_shengsheng_b_run/shengsheng_board_b_Runs/phy_1'
}
$runPath = Join-Path $candidateRoot 'evidence/student_stage1_run.json'
$run = Get-Content -LiteralPath $runPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ($run.state -ne 'STAGE1_COMPLETE_REQUIRES_GATES' -or $run.tool_exit_code -ne 0 -or $run.bitgen) {
    throw 'Stage1 has no completed, no-bitgen run receipt'
}
$scopePath = Join-Path $candidateRoot 'evidence/feature_source_scope.json'
if ((Get-FileHash -LiteralPath $scopePath -Algorithm SHA256).Hash -ne $run.input_snapshot_sha256 -or
    (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'build_student_stage1.tcl') -Algorithm SHA256).Hash -ne $run.script_sha256) {
    throw 'Stage1 flow or input snapshot identity changed'
}
$scope = Get-Content -LiteralPath $scopePath -Raw -Encoding UTF8 | ConvertFrom-Json
foreach ($board in @('student_B','teacher_A')) {
    foreach ($property in $scope.changes.$board.input_snapshot.PSObject.Properties) {
        if ((Get-FileHash -LiteralPath (Join-Path (Join-Path $candidateRoot $board) $property.Name) -Algorithm SHA256).Hash -ne $property.Value) {
            throw "Stage1 source identity changed: $board/$($property.Name)"
        }
    }
}
$artifacts = @()
foreach ($file in @('shengsheng_board_b_pr.db','controls_student.pnl','controls_student_out.v',
                    'final_timing.rpt','final_timing_violations.rpt',
                    'shengsheng_board_b_exception.timing','shengsheng_board_b_phy.area')) {
    $item = Get-Item -LiteralPath (Join-Path $PhyRoot $file)
    if ($item.Length -le 0 -or $item.LastWriteTimeUtc -lt [datetime]$run.started_utc) {
        throw "Stage1 artifact is empty or stale: $file"
    }
    $artifacts += [ordered]@{path=$item.FullName;bytes=$item.Length;sha256=(Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash}
}
# Reuse the exact canonical fail-closed timing parsers without executing the
# build/publish body of the original wrapper.
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($canonical, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw 'Canonical wrapper parse failed' }
$required = @('Get-TimingHeader', 'Assert-TimingRows', 'Assert-TimingText', 'Assert-ViolationsText')
foreach ($name in $required) {
    $found = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true))
    if ($found.Count -ne 1) { throw "Canonical gate function missing/ambiguous: $name" }
    Invoke-Expression $found[0].Extent.Text
}
$topName = 'shengsheng_board_b_top'
$timing = Assert-TimingText (Get-Content -LiteralPath (Join-Path $PhyRoot 'final_timing.rpt') -Raw -Encoding UTF8)
Assert-ViolationsText (Get-Content -LiteralPath (Join-Path $PhyRoot 'final_timing_violations.rpt') -Raw -Encoding UTF8) $timing
# Preserve the canonical wrapper's TMDS constraints and output placement gates.
$exceptionText = Get-Content -LiteralPath (Join-Path $PhyRoot 'shengsheng_board_b_exception.timing') -Raw -Encoding UTF8
$areaText = Get-Content -LiteralPath (Join-Path $PhyRoot 'shengsheng_board_b_phy.area') -Raw -Encoding UTF8
$constraintPattern = 'set_max_delay -from \[get_clocks \{pixel_clk_5x\}\] -to \[get_ports \{HDMI_CLK_P HDMI_D0_P HDMI_D1_P HDMI_D2_P\}\] 8\.000 -datapath_only'
if ($exceptionText -notmatch $constraintPattern -or $exceptionText -notmatch 'Total Paths\s*:\s*8' -or
    $exceptionText -notmatch 'Dominated\s*:\s*8,\s*100\.0%') {
    throw 'TMDS ODDR-to-pad max-delay constraint is not fully active'
}
$laneDelays = [ordered]@{}
foreach ($lane in @('HDMI_CLK_P','HDMI_D0_P','HDMI_D1_P','HDMI_D2_P')) {
    $ioPattern = '(?m)^\s*' + [regex]::Escape($lane) + '\s+OUTPUT\s+\S+\s+LVDS33\s+PAD\s+NA\s+NONE\s+DDRX1\s*$'
    if ($areaText -notmatch $ioPattern) { throw "$lane is not placed as LVDS33 DDRX1" }
    $laneMatch = [regex]::Match($exceptionText, 'End Point\s*:\s*' + [regex]::Escape($lane) + '(?s).*?Data Path Delay\s*:\s*([0-9.]+)ns')
    if (-not $laneMatch.Success) { throw "TMDS pad delay is missing for $lane" }
    $laneDelays[$lane] = [double]::Parse($laneMatch.Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture)
}
$record = [ordered]@{
    schema = 'controls_r1_stage1_timing/v1'
    result = 'PASS_CANONICAL_TIMING_PARSERS'
    canonical_wrapper_sha256 = (Get-FileHash -LiteralPath $canonical -Algorithm SHA256).Hash
    phy_root = $PhyRoot
    timing = $timing
    tmds_reported_endpoint_delays_ns = $laneDelays
    run_receipt_sha256 = (Get-FileHash -LiteralPath $runPath -Algorithm SHA256).Hash
    input_snapshot_sha256 = $run.input_snapshot_sha256
    artifacts = $artifacts
    bitgen = $false
    hardware = 'NOT_TESTED'
}
$record | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $candidateRoot 'evidence/student_stage1_timing.json') -Encoding UTF8
Write-Output "CONTROLS_STAGE1_TIMING_PASS coverage=$($timing.coverage)"
