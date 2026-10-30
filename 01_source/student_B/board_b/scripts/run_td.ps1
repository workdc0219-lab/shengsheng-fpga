# V7 fail-closed build/release gate: zero post-route setup/hold/removal
# violations, nonempty Max/Min analyses, STA >=99.95%, immutable inputs,
# and receipt-addressed published artifacts. This script never flashes hardware.
param(
    [switch]$VerifyOnly,
    [switch]$FreezeExistingReceipt,
    [ValidateRange(1, 100)]
    [int]$PlaceSeed = 1
)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$boardRoot = Split-Path -Parent $scriptDir
$mediaRoot = Split-Path -Parent $boardRoot          # the dual-board project root
$td = 'C:\Anlogic\TD_6.2.1_Engineer_6.2.168.116\bin\td_commands_prompt.exe'
$tcl = (Join-Path $scriptDir 'run_td.tcl').Replace('\', '/')
$consoleLog = Join-Path $boardRoot 'td_console.log'
$bit = Join-Path $mediaRoot 'td_shengsheng_b_run\shengsheng_board_b_Runs\phy_1\shengsheng_board_b.bit'
$outputBit = Join-Path $boardRoot 'output\shengsheng_board_b.bit'
$outputTimingReport = Join-Path $boardRoot 'output\final_timing.rpt'
$outputExceptionReport = Join-Path $boardRoot 'output\shengsheng_board_b_exception.timing'
$outputAreaReport = Join-Path $boardRoot 'output\shengsheng_board_b_phy.area'
$phyRoot = Join-Path $mediaRoot 'td_shengsheng_b_run\shengsheng_board_b_Runs\phy_1'
$timingReport = Join-Path $phyRoot 'final_timing.rpt'
$exceptionReport = Join-Path $phyRoot 'shengsheng_board_b_exception.timing'
$areaReport = Join-Path $phyRoot 'shengsheng_board_b_phy.area'
$receiptPath = Join-Path $boardRoot 'output\shengsheng_board_b_build_receipt.json'
$srcDir = Join-Path $boardRoot 'src'
$inputPaths = @(
    (Join-Path $srcDir 'v7_link_b.v'),
    (Join-Path $srcDir 'v7_packet_tx.v'),
    (Join-Path $srcDir 'v7_packet_rx.v'),
    (Join-Path $srcDir 'v7_defs.vh'),
    (Join-Path $srcDir 'ui_config.vh'),
    (Join-Path $srcDir 'audio_config.vh'),
    (Join-Path $mediaRoot 'spec/protocol_v7.json'),
    (Join-Path $mediaRoot 'spec/ui.json'),
    (Join-Path $mediaRoot 'tools/generate_contracts.py'),
    (Join-Path $scriptDir 'run_td.ps1'),
    (Join-Path $srcDir 'afifo_32_16_256.v'),
    (Join-Path $srcDir 'audio_arc_calculate.v'),
    (Join-Path $srcDir 'audio_probe_d4.v'),
    (Join-Path $srcDir 'audio_reference_d3.v'),
    (Join-Path $srcDir 'badge_journal.v'),
    (Join-Path $srcDir 'bmp24_decoder.v'),
    (Join-Path $srcDir 'button_event.v'),
    (Join-Path $srcDir 'config_flash_journal.v'),
    (Join-Path $srcDir 'config_journal.v'),
    (Join-Path $srcDir 'dual_key_chord_router.v'),
    (Join-Path $srcDir 'dual_key_long_hold_guard.v'),
    (Join-Path $srcDir 'fat32_file_streamer.v'),
    (Join-Path $srcDir 'fat32_volume_scanner.v'),
    (Join-Path $srcDir 'fifo_prefetch_2.v'),
    (Join-Path $srcDir 'global_def.v'),
    (Join-Path $srcDir 'hdmi_1_4b_transmitter_core_wrapper.enc.v'),
    (Join-Path $srcDir 'hdmi_phy_warpper.v'),
    (Join-Path $srcDir 'lane_lvds_10_1.v'),
    (Join-Path $srcDir 'lookup_classifier.v'),
    (Join-Path $srcDir 'media_frame_loader.v'),
    (Join-Path $srcDir 'media_frame_reader.v'),
    (Join-Path $srcDir 'media_ingest_frontend.v'),
    (Join-Path $srcDir 'media_ingest_pipeline.v'),
    (Join-Path $srcDir 'media_player_control.v'),
    (Join-Path $srcDir 'media_sdram_write_cdc.v'),
    (Join-Path $srcDir 'media_storage_ingest_top.v'),
    (Join-Path $srcDir 'media_video_pipeline.v'),
    (Join-Path $srcDir 'osd_overlay_24.v'),
    (Join-Path $srcDir 'param_menu_controller.v'),
    (Join-Path $srcDir 'pcm_media_music_v8.v'),
    (Join-Path $srcDir 'spectrum_analyzer_v8.v'),
    (Join-Path $srcDir 'osd_spectrum_v8.v'),
    (Join-Path $srcDir 'spectrum_v8_tables.vh'),
    (Join-Path $srcDir 'player_config_persistence.v'),
    (Join-Path $srcDir 'promax_audio_waveform.v'),
    (Join-Path $srcDir 'promax_text_overlay.v'),
    (Join-Path $srcDir 'reset_sync.v'),
    (Join-Path $srcDir 'rgb_video_adapter.v'),
    (Join-Path $srcDir 'sd_media_service.v'),
    (Join-Path $srcDir 'sd_sector_replay_buffer.v'),
    (Join-Path $srcDir 'sd_spi_byte_engine.v'),
    (Join-Path $srcDir 'sd_spi_command.v'),
    (Join-Path $srcDir 'sd_spi_init.v'),
    (Join-Path $srcDir 'sd_spi_sector_reader.v'),
    (Join-Path $srcDir 'sdr_as_ram.enc.v'),
    (Join-Path $srcDir 'sdr_init_ref.enc.v'),
    (Join-Path $srcDir 'sdr_wrrd.enc.v'),
    (Join-Path $srcDir 'sdram.v'),
    (Join-Path $srcDir 'shengsheng_board_b_top.v'),
    (Join-Path $srcDir 'shengsheng_game.v'),
    (Join-Path $srcDir 'shengsheng_overlay.v'),
    (Join-Path $srcDir 'spi_byte_engine.v'),
    (Join-Path $srcDir 'ss_badge_rom.v'),
    (Join-Path $srcDir 'ss_consts.vh'),
    (Join-Path $srcDir 'ss_exp2_rom.v'),
    (Join-Path $srcDir 'ss_log2_rom.v'),
    (Join-Path $srcDir 'ss_phrases.vh'),
    (Join-Path $srcDir 'ss_phrase_rom.v'),
    (Join-Path $srcDir 'ss_score_reporter.v'),
    (Join-Path $srcDir 'ss_score_reporter_b.v'),
    (Join-Path $srcDir 'ss_sine_rom.v'),
    (Join-Path $srcDir 'startup_pulse.v'),
    (Join-Path $srcDir 'status_osd_overlay.v'),
    (Join-Path $srcDir 'osd_param_panel_v8.v'),
    (Join-Path $srcDir 'osd_panel_rom_v8.v'),
    (Join-Path $srcDir 'osd_panel_v8.vh'),
    (Join-Path $srcDir 'osd_caption_layer_v8.v'),
    (Join-Path $srcDir 'osd_caption_rom_v8.v'),
    (Join-Path $srcDir 'osd_caption_v8.vh'),
    (Join-Path $srcDir 'subtitle_frame_commit.v'),
    (Join-Path $srcDir 'sync_2ff.v'),
    (Join-Path $srcDir 'hdmi_gray_probe_v8.v'),
    (Join-Path $srcDir 'sys_pll_promax_40.v'),
    (Join-Path $srcDir 'tone_scorer.v'),
    (Join-Path $srcDir 'result_packet_tx.v'),
    (Join-Path $srcDir 'uart_rx_byte.v'),
    (Join-Path $srcDir 'uart_rx_feature.v'),
    (Join-Path $srcDir 'uart_tx_byte.v'),
    (Join-Path $srcDir 'video_fade_transition.v'),
    (Join-Path $srcDir 'video_rgb_to_axis_640x480.v'),
    (Join-Path $srcDir 'video_timing_ctrl.v'),
    (Join-Path $srcDir 'voice_model_synth.v'),
    (Join-Path $srcDir 'w25q64_preflight_reader.v'),
    (Join-Path $srcDir 'w25q64_record_store.v'),
    (Join-Path $srcDir 'seven_seg_display.v'),
    (Join-Path $srcDir 'buzzer_feedback.v'),
    (Join-Path $srcDir 'enc_file\global_def.v'),
    (Join-Path $srcDir 'classifier_lut.hex'),
    (Join-Path $boardRoot 'constraints\board_b_top.adc'),
    (Join-Path $boardRoot 'constraints\board_b_top.sdc'),
    (Join-Path $scriptDir 'run_td.tcl')
)


# V7 receipts bind canonical shared RTL, generated contracts/ROM dependencies,
# every enumerated implementation input, and stable published artifact copies.
$topName = 'shengsheng_board_b_top'
$marker = 'TD_SHENGSHENG_B_BUILD_COMPLETE=1'
$hasTmds = $true
$runDirectoryName = 'td_shengsheng_b_run'
if ($env:TD_RUN_DIR -and $env:TD_RUN_DIR -ne $runDirectoryName) {
    throw 'Noncanonical TD_RUN_DIR is rejected by the release wrapper'
}
if ($runDirectoryName -notmatch '^td_shengsheng_[A-Za-z0-9_]+$') {
    throw 'TD_RUN_DIR must be a named direct-child td_shengsheng_* run directory'
}
$projectRoot = Join-Path $mediaRoot $runDirectoryName
$phyRoot = Join-Path $projectRoot 'shengsheng_board_b_Runs\phy_1'
$bit = Join-Path $phyRoot 'shengsheng_board_b.bit'
$timingReport = Join-Path $phyRoot 'final_timing.rpt'
$exceptionReport = Join-Path $phyRoot 'shengsheng_board_b_exception.timing'
$areaReport = Join-Path $phyRoot 'shengsheng_board_b_phy.area'
$outputRoot = Split-Path -Parent $outputBit
$fontPath = 'C:\Windows\Fonts\Dengb.ttf'
$inputPaths += @(
    (Join-Path $mediaRoot 'common/rtl/v7_link_a.v'),
    (Join-Path $mediaRoot 'common/rtl/v7_link_b.v'),
    (Join-Path $mediaRoot 'common/rtl/v7_packet_tx.v'),
    (Join-Path $mediaRoot 'common/rtl/v7_packet_rx.v'),
    (Join-Path $mediaRoot 'tools/make_phrase_rom.py'),
    (Join-Path $mediaRoot 'tools/make_badge_rom.py'),
    $fontPath
)
$inputPaths = @($inputPaths | Sort-Object -Unique)
$roleFiles = [ordered]@{
    bit = 'shengsheng_board_b.bit'
    timing = 'final_timing.rpt'
    timing_violations = 'final_timing_violations.rpt'
    exceptions = 'shengsheng_board_b_exception.timing'
    area = 'shengsheng_board_b_phy.area'
    build_log = 'build.log'
}
if ($VerifyOnly -and $FreezeExistingReceipt) { throw 'Choose only one verification switch' }
$readOnly = $VerifyOnly -or $FreezeExistingReceipt
# An unknown old bit has no trustworthy pre-build input snapshot. Freeze is
# intentionally read-only in v7; it cannot create or overwrite a receipt.
if ($readOnly -and -not (Test-Path -LiteralPath $receiptPath -PathType Leaf)) {
    throw 'No v7 receipt exists; rebuild required. Freeze cannot attest an unknown old bit.'
}

function Get-RecordPath([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    if ($full -eq $fontPath) { return '@font/Dengb.ttf' }
    $prefix = $mediaRoot.TrimEnd('\') + '\'
    if (-not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Identity path is outside the project: $Path"
    }
    return $full.Substring($prefix.Length).Replace('\', '/')
}
function Resolve-RecordPath([string]$Path) {
    if ($Path -eq '@font/Dengb.ttf') { return $fontPath }
    if ([string]::IsNullOrWhiteSpace($Path) -or [IO.Path]::IsPathRooted($Path)) {
        throw 'Receipt path must be project-relative'
    }
    $full = [IO.Path]::GetFullPath((Join-Path $mediaRoot $Path.Replace('/', '\')))
    [void](Get-RecordPath $full)
    return $full
}
function Get-IdentityRecord([string]$Path, [string]$Role = '', [string]$PublishedPath = '') {
    $item = Get-Item -LiteralPath $Path
    if ($item.PSIsContainer) { throw "Identity must refer to a file: $Path" }
    $record = [ordered]@{
        path = $(if ($PublishedPath) { Get-RecordPath $PublishedPath } else { Get-RecordPath $item.FullName })
        bytes = $item.Length
        sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $item.FullName).Hash
    }
    if ($Role) { $record.role = $Role }
    return $record
}
function Assert-Record([object]$Record) {
    if ([string]$Record.sha256 -notmatch '^[A-Fa-f0-9]{64}$' -or [int64]$Record.bytes -lt 0) {
        throw 'Receipt contains an invalid identity record'
    }
    $path = Resolve-RecordPath ([string]$Record.path)
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Receipt file is missing: $($Record.path)" }
    $actual = Get-IdentityRecord $path
    if ($actual.bytes -ne [int64]$Record.bytes -or $actual.sha256 -ne [string]$Record.sha256) {
        throw "Receipt identity mismatch: $($Record.path)"
    }
}
function Assert-InputSnapshot([object[]]$Records) {
    foreach ($record in $Records) { Assert-Record $record }
}
function Assert-ContractCopies {
    # This is a read-only check. Never silently regenerate sources during a build.
    & python (Join-Path $mediaRoot 'tools/generate_contracts.py') --check
    if ($LASTEXITCODE -ne 0) { throw 'Canonical RTL/generated contract copies are out of sync' }
}
function Assert-Receipt([object]$Receipt) {
    if ($Receipt.schema -ne 1 -or $Receipt.gate_version -ne 7 -or $Receipt.timing_report_contract -ne 2 -or
        $Receipt.tool -ne 'TD 6.2.168116' -or $Receipt.device -ne 'EG4S20BG256' -or
        $Receipt.top -ne $topName -or $Receipt.mode -ne 'canonical_td_build') {
        throw 'Build receipt contract mismatch; canonical v7 rebuild required'
    }
    $expected = @($inputPaths | ForEach-Object { Get-RecordPath $_ } | Sort-Object -Unique)
    $actual = @($Receipt.inputs | ForEach-Object { [string]$_.path } | Sort-Object -Unique)
    if ($actual.Count -ne @($Receipt.inputs).Count -or
        $expected.Count -ne $actual.Count -or @(Compare-Object $expected $actual).Count) {
        throw 'Receipt does not enumerate the complete current input contract'
    }
    Assert-InputSnapshot @($Receipt.inputs)
    if (@($Receipt.artifacts).Count -ne $roleFiles.Count) { throw 'Receipt artifact contract is incomplete' }
    $resolved = @{}
    foreach ($role in $roleFiles.Keys) {
        $records = @($Receipt.artifacts | Where-Object { $_.role -eq $role })
        if ($records.Count -ne 1) { throw "Receipt artifact role is missing or duplicated: $role" }
        $record = $records[0]
        $expectedPath = Get-RecordPath (Join-Path $outputRoot $roleFiles[$role])
        if ($record.path -ne $expectedPath -or [int64]$record.bytes -le 0) {
            throw "Receipt artifact path/size is invalid: $role"
        }
        Assert-Record $record
        $resolved[$role] = Resolve-RecordPath $record.path
    }
    return $resolved
}
function Get-TimingHeader([string]$ReportText) {
    # Contract 2: a filtered, empty-body violation report is valid only with
    # an independently complete, routed, two-corner full summary.
    if ([string]::IsNullOrWhiteSpace($ReportText)) { throw 'Timing report is empty' }
    $headers = @{
        'Top Model' = [regex]::Escape($topName)
        'Device' = 'EG4S20BG256'
        'Confidence' = 'Routed'
        'Check Corner' = 'Both \(Slow and Fast\)'
    }
    foreach ($name in $headers.Keys) {
        $pattern = '(?m)^[ \t]*' + [regex]::Escape($name) + '[ \t]*:[ \t]*' + $headers[$name] + '[ \t]*\r?$'
        if ([regex]::Matches($ReportText, $pattern).Count -ne 1) {
            throw "Timing report identity/corner header is invalid: $name"
        }
    }
    foreach ($corner in @('Slow', 'Fast')) {
        if ($ReportText -notmatch ('(?m)^[ \t]*' + $corner + '[ \t]*\|[ \t]*yes[ \t]+yes[ \t]*\r?$')) {
            throw "Timing report lacks both Max/Min checks for $corner corner"
        }
    }
    foreach ($section in @('Check Status', 'Timing Status', 'Clock Summary', 'Intra clock domain timing', 'Inter clock domain timing', 'IP timing')) {
        if ([regex]::Matches($ReportText, ('(?m)^[ \t]*' + [regex]::Escape($section) + '[ \t]*\r?$')).Count -ne 1) {
            throw "Timing report is incomplete or duplicated: $section"
        }
    }
    $coverageMatches = @([regex]::Matches($ReportText, '(?m)^[ \t]*STA coverage[ \t]*:[ \t]*([0-9]+(?:\.[0-9]+)?)%[ \t]*\r?$'))
    if ($coverageMatches.Count -ne 1) { throw 'STA coverage is missing or duplicated' }
    $coverage = [double]::Parse($coverageMatches[0].Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture)
    if ($coverage -lt 99.95 -or $coverage -gt 100) { throw "STA coverage is invalid or below gate: $coverage%" }
    $constraintMatches = @([regex]::Matches($ReportText, '(?m)^[ \t]*Constraint File[ \t]*:[ \t]*(\S[^\r\n]*)'))
    if ($constraintMatches.Count -ne 1) { throw 'Timing report constraint identity is missing or duplicated' }
    $schemeMatches = @([regex]::Matches($ReportText, '(?m)^[ \t]*Report Scheme[ \t]*:[ \t]*(\d+) end point\(s\) per path group, (\d+) path\(s\) per end point[ \t]*\r?$'))
    if ($schemeMatches.Count -ne 1 -or [int64]$schemeMatches[0].Groups[1].Value -le 0 -or
        [int64]$schemeMatches[0].Groups[2].Value -ne 1) { throw 'Timing report scheme is missing or invalid' }
    $number = '[-+]?\d+(?:\.\d+)?'
    $global = [ordered]@{}
    foreach ($pair in @(@('SWNS','STNS'), @('HWNS','HTNS'))) {
        $pattern = '(?m)^[ \t]*' + $pair[0] + ':[ \t]*(?<wns>' + $number + ')ns,[ \t]*' + $pair[1] + ':[ \t]*(?<tns>' + $number + ')ns[ \t]*\r?$'
        $matches = @([regex]::Matches($ReportText, $pattern))
        if ($matches.Count -ne 1) { throw "Timing report has no unique global $($pair[0])/$($pair[1]) status" }
        $wns = [double]::Parse($matches[0].Groups['wns'].Value, [Globalization.CultureInfo]::InvariantCulture)
        $tns = [double]::Parse($matches[0].Groups['tns'].Value, [Globalization.CultureInfo]::InvariantCulture)
        if ($wns -lt 0 -or $tns -ne 0) { throw "RELEASE_BLOCKED: global $($pair[0])/$($pair[1]) timing violation" }
        $global[$pair[0]] = $wns
        $global[$pair[1]] = $tns
    }
    $periodMatches = @([regex]::Matches($ReportText, ('(?m)^[ \t]*Period Check WNS:[ \t]*(' + $number + ')ns[ \t]*\r?$')))
    if ($periodMatches.Count -ne 1) { throw 'Timing report has no unique period check' }
    $period = [double]::Parse($periodMatches[0].Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture)
    if ($period -lt 0) { throw 'RELEASE_BLOCKED: clock period violation' }
    return [ordered]@{
        coverage=$coverage; global=$global; period_wns_ns=$period
        constraints=$constraintMatches[0].Groups[1].Value.Trim()
        endpoints_per_group=[int64]$schemeMatches[0].Groups[1].Value
    }
}
function Assert-TimingRows([string]$ReportText, [bool]$AllowEmpty) {
    $number = '[-+]?\d+(?:\.\d+)?'
    $rows = @{}
    $groups = @([regex]::Matches($ReportText, '(?ms)^[ \t]*Path Group[ \t]*:[^\r\n]+.*?(?=^[ \t]*Path Group[ \t]*:|\z)'))
    $groupCount = $groups.Count
    foreach ($group in $groups) {
        foreach ($kind in @('Max', 'Min')) {
            if ([regex]::Matches($group.Value, ('(?m)^[ \t]*' + $kind + '[ \t]*:')).Count -ne 1) {
                throw "Timing path group has missing or duplicate $kind summary"
            }
        }
    }
    foreach ($kind in @('Max', 'Min')) {
        $prefix = $(if ($kind -eq 'Max') { 'S' } else { 'H' })
        $pattern = '(?m)^[ \t]*' + $kind + '[ \t]*:[ \t]*' + $prefix + 'WNS[ \t]+(?<wns>' + $number + ')ns,[ \t]*' +
            $prefix + 'TNS[ \t]+(?<tns>' + $number + ')ns,[ \t]*(?<viol>\d+)[ \t]+Viol Endpoints,[ \t]*(?<total>\d+)[ \t]+Total Endpoints,[ \t]*(?<paths>\d+)[ \t]+Paths Analyzed[ \t]*\r?$'
        $parsed = @([regex]::Matches($ReportText, $pattern))
        $headings = @([regex]::Matches($ReportText, ('(?m)^[ \t]*' + $kind + '[ \t]*:')))
        if ($parsed.Count -ne $headings.Count -or $parsed.Count -ne $groupCount -or
            (-not $AllowEmpty -and ($parsed.Count -eq 0 -or
                @($parsed | Where-Object { [int64]$_.Groups['paths'].Value -gt 0 }).Count -eq 0))) {
            throw "Timing report has no complete nonempty $kind summary"
        }
        foreach ($row in $parsed) {
            $wns = [double]::Parse($row.Groups['wns'].Value, [Globalization.CultureInfo]::InvariantCulture)
            $tns = [double]::Parse($row.Groups['tns'].Value, [Globalization.CultureInfo]::InvariantCulture)
            if ([int64]$row.Groups['viol'].Value -ne 0 -or $wns -lt 0 -or $tns -ne 0) {
                throw "RELEASE_BLOCKED: post-route $kind setup/hold/removal violations"
            }
        }
        $rows[$kind] = $parsed.Count
    }
    if ($rows.Max -ne $rows.Min) { throw 'Timing report Max/Min domain summaries are incomplete' }
    $slackHeads = @([regex]::Matches($ReportText, '(?m)^[ \t]*Slack(?:[ \t]*:|[ \t]+)[^\r\n]*'))
    $slacks = @([regex]::Matches($ReportText, ('(?m)^[ \t]*Slack[ \t]*:?[ \t]+(' + $number + ')(?:ns)?[ \t]*\r?$')))
    if ($slacks.Count -ne $slackHeads.Count) { throw 'Timing report contains malformed detailed Slack' }
    foreach ($slack in $slacks) {
        if ([double]::Parse($slack.Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture) -lt 0) {
            throw 'RELEASE_BLOCKED: negative detailed timing Slack'
        }
    }
    return [ordered]@{ max_groups=$rows.Max; min_groups=$rows.Min; slack_lines=$slacks.Count }
}
function Assert-TimingText([string]$ReportText) {
    $result = Get-TimingHeader $ReportText
    $rows = Assert-TimingRows $ReportText $false
    $result['max_groups'] = $rows.max_groups
    $result['min_groups'] = $rows.min_groups
    return $result
}
function Assert-ViolationsText([string]$ReportText, [object]$FullTiming) {
    $header = Get-TimingHeader $ReportText
    $rows = Assert-TimingRows $ReportText $true
    if ($header.endpoints_per_group -lt 65536 -or
        $header.coverage -ne $FullTiming.coverage -or
        $header.constraints -ne $FullTiming.constraints) {
        throw 'Violation report coverage/scope/scheme does not match the full report'
    }
    # A clean -viol_only report has no path details. Do not reject its lack
    # of Max/Min groups, but do reject a missing/header-only malformed file.
    if ($rows.slack_lines -ne 0 -or $ReportText -match '(?m)^[ \t]*(Begin Point|End Point|Check Type)[ \t]*:') {
        throw 'RELEASE_BLOCKED: violation report contains a reported timing path'
    }
    # Filtered global WNS can be clipped to zero; do not require equality
    # with the full report's positive setup/hold margin.
}

Assert-ContractCopies
$initialInputRecords = @($inputPaths | ForEach-Object { Get-IdentityRecord $_ })
$buildStarted = $null
if ($readOnly) {
    $receipt = Get-Content -Raw -Encoding UTF8 -LiteralPath $receiptPath | ConvertFrom-Json
    $sourcePaths = Assert-Receipt $receipt
} else {
    if (-not (Test-Path -LiteralPath $td -PathType Leaf)) { throw 'TD 6.2.1 was not found' }
    $buildStarted = (Get-Date).ToUniversalTime()
    $oldHoldFix = $env:TD_KEEP_DR_HOLDFIX
    $oldSeed = $env:TD_PLACE_SEED
    $oldRun = $env:TD_RUN_DIR
    try {
        $env:TD_KEEP_DR_HOLDFIX = '1'
        $env:TD_PLACE_SEED = [string]$PlaceSeed
        $env:TD_RUN_DIR = $runDirectoryName
        & $td $tcl 2>&1 | Tee-Object -FilePath $consoleLog
        if ($LASTEXITCODE -ne 0) { throw "TD process exited with code $LASTEXITCODE" }
    } finally {
        $env:TD_KEEP_DR_HOLDFIX = $oldHoldFix
        $env:TD_PLACE_SEED = $oldSeed
        $env:TD_RUN_DIR = $oldRun
    }
    $sourcePaths = @{bit=$bit; timing=$timingReport; timing_violations=(Join-Path $phyRoot 'final_timing_violations.rpt'); exceptions=$exceptionReport; area=$areaReport; build_log=$consoleLog}
    # This assertion is deliberately BEFORE any output directory/copy/write.
    Assert-InputSnapshot $initialInputRecords
}
foreach ($role in $roleFiles.Keys) {
    $path = $sourcePaths[$role]
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Build artifact is missing ($role): $path" }
    $item = Get-Item -LiteralPath $path
    if ($item.Length -le 0) { throw "Build artifact is empty ($role): $path" }
    if (-not $readOnly -and $item.LastWriteTimeUtc -lt $buildStarted) {
        throw "Build artifact predates this build ($role): $path"
    }
}
$text = Get-Content -Raw -Encoding UTF8 -LiteralPath $sourcePaths.build_log
if ($text -notmatch ('(?m)^\s*' + [regex]::Escape($marker) + '\s*$')) {
    throw 'TD log has no authentic TCL completion marker'
}
if ($text -match '(?im)^.*\bERROR\s*:') { throw 'TD log contains an ERROR; no recovery or self-stamp is accepted' }
$reportText = Get-Content -Raw -Encoding UTF8 -LiteralPath $sourcePaths.timing
$timing = Assert-TimingText $reportText
$violationsText = Get-Content -Raw -Encoding UTF8 -LiteralPath $sourcePaths.timing_violations
Assert-ViolationsText $violationsText $timing
$timing['violation_report_verified'] = $true
$exceptionText = Get-Content -Raw -Encoding UTF8 -LiteralPath $sourcePaths.exceptions
$areaText = Get-Content -Raw -Encoding UTF8 -LiteralPath $sourcePaths.area
$laneDelays = [ordered]@{}
if ($hasTmds) {
    $constraintPattern = 'set_max_delay -from \[get_clocks \{pixel_clk_5x\}\] -to \[get_ports \{HDMI_CLK_P HDMI_D0_P HDMI_D1_P HDMI_D2_P\}\] 8\.000 -datapath_only'
    if ($exceptionText -notmatch $constraintPattern -or $exceptionText -notmatch 'Total Paths\s*:\s*8' -or
        $exceptionText -notmatch 'Dominated\s*:\s*8,\s*100\.0%') {
        throw 'TMDS ODDR-to-pad max-delay constraint is not fully active'
    }
    foreach ($lane in @('HDMI_CLK_P','HDMI_D0_P','HDMI_D1_P','HDMI_D2_P')) {
        $ioPattern = '(?m)^\s*' + [regex]::Escape($lane) + '\s+OUTPUT\s+\S+\s+LVDS33\s+PAD\s+NA\s+NONE\s+DDRX1\s*$'
        if ($areaText -notmatch $ioPattern) { throw "$lane is not placed as LVDS33 DDRX1" }
        $lanePattern = 'End Point\s*:\s*' + [regex]::Escape($lane) + '(?s).*?Data Path Delay\s*:\s*([0-9.]+)ns'
        $laneMatch = [regex]::Match($exceptionText, $lanePattern)
        if (-not $laneMatch.Success) { throw "TMDS pad delay is missing for $lane" }
        $laneDelays[$lane] = [double]::Parse($laneMatch.Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture)
    }
}
Assert-InputSnapshot $initialInputRecords
$bitHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $sourcePaths.bit).Hash

if (-not $readOnly) {
    Assert-ContractCopies
    $artifactSnapshot = @($roleFiles.Keys | ForEach-Object { Get-IdentityRecord $sourcePaths[$_] $_ })
    # Stage a complete release next to output. No old output is changed until
    # every gate, source snapshot, staged hash, and receipt is validated.
    $suffix = [guid]::NewGuid().ToString('N')
    $stage = $outputRoot + '.stage_' + $suffix
    $backup = $outputRoot + '.previous_' + $suffix
    $rejected = $outputRoot + '.rejected_' + $suffix
    foreach ($path in @($stage,$backup,$rejected)) { [void](Get-RecordPath $path) }
    New-Item -ItemType Directory -Path $stage | Out-Null
    if (Test-Path -LiteralPath $outputRoot) {
        Get-ChildItem -LiteralPath $outputRoot -Force | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination $stage -Recurse -Force
        }
    }
    $publishedRecords = @()
    foreach ($role in $roleFiles.Keys) {
        $stagePath = Join-Path $stage $roleFiles[$role]
        Copy-Item -LiteralPath $sourcePaths[$role] -Destination $stagePath -Force
        $record = Get-IdentityRecord $stagePath $role (Join-Path $outputRoot $roleFiles[$role])
        $original = @($artifactSnapshot | Where-Object { $_.role -eq $role })[0]
        if ($record.bytes -ne $original.bytes -or $record.sha256 -ne $original.sha256) {
            throw "Staged artifact copy mismatch: $role; old output is untouched"
        }
        $publishedRecords += $record
    }
    Assert-InputSnapshot $initialInputRecords
    foreach ($record in $artifactSnapshot) { Assert-Record $record }
    $receipt = [ordered]@{
        schema=1; gate_version=7; timing_report_contract=2; mode='canonical_td_build'
        build_started_at=$buildStarted.ToString('o'); frozen_at=(Get-Date).ToUniversalTime().ToString('o')
        tool='TD 6.2.168116'; device='EG4S20BG256'; top=$topName; place_seed=$PlaceSeed
        run_directory=$runDirectoryName; hardware='PENDING'
        timing=$timing; tmds_reported_endpoint_delays_ns=$laneDelays
        inputs=$initialInputRecords; artifacts=$publishedRecords
    }
    $stageReceipt = Join-Path $stage (Split-Path -Leaf $receiptPath)
    $receipt | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 -LiteralPath $stageReceipt
    Assert-InputSnapshot $initialInputRecords
    $oldMoved = $false
    $newMoved = $false
    try {
        if (Test-Path -LiteralPath $outputRoot) {
            Move-Item -LiteralPath $outputRoot -Destination $backup
            $oldMoved = $true
        }
        Move-Item -LiteralPath $stage -Destination $outputRoot
        $newMoved = $true
        $published = Get-Content -Raw -Encoding UTF8 -LiteralPath $receiptPath | ConvertFrom-Json
        [void](Assert-Receipt $published)
    } catch {
        if ($newMoved -and (Test-Path -LiteralPath $outputRoot)) {
            Move-Item -LiteralPath $outputRoot -Destination $rejected
        }
        if ($oldMoved -and -not (Test-Path -LiteralPath $outputRoot)) {
            Move-Item -LiteralPath $backup -Destination $outputRoot
        }
        throw
    }
    if ($oldMoved) { Write-Output "PREVIOUS_RELEASE_PRESERVED=$backup" }
}
Write-Output "TIMING_POSTROUTE_CLEAN setup_viol=0 hold_removal_viol=0 max_groups=$($timing.max_groups) min_groups=$($timing.min_groups)"
Write-Output "TD_SHENGSHENG_B_WRAPPER_PASS sta_coverage_pct=$($timing.coverage.ToString('F2')) bit_sha256=$bitHash receipt=$receiptPath readonly=$readOnly"
