"""Offline admission/publication of the fixed-seed same-DB SRAM candidate.

No synthesis, TD, simulation, programmer, git or STATUS operation is invoked.
The default reset policy and its explicit warning review are retained; this
does not convert the optional strict FAIL into a PASS or create a release.
"""
import argparse
from collections import Counter
import datetime
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import sys
import uuid
import xml.etree.ElementTree as ET

sys.dont_write_bytecode = True
import verify_student_route_only as pnl

ROOT = Path(__file__).resolve().parents[1]
WORKSPACE = ROOT.parent
EVIDENCE = ROOT / 'evidence'
SELECTED_DB = EVIDENCE / 'student_seed1_route_only/student_route_only_pr.db'
SELECTED_PNL = EVIDENCE / 'student_seed1_route_only/after.pnl'
DB_SHA = 'A79315D9825A88CAE151739381D3A3AFFBA5E27379B783101B7E6AAB4FACACC9'
PNL_SHA = 'CAE003C47F0BE12477E2DCEAA0B1EBC7473C5DAF78CD5359E6027D86CA64D265'
STAGE1_DB = ROOT / 'student_B/td_shengsheng_b_run/shengsheng_board_b_Runs/phy_1/shengsheng_board_b_pr.db'
STAGE1_SHA = '606EF84D275E617B8F22A1916975BC7BE9A91ECF60C25C76F1092A8ADEC686E7'
WRAPPER = ROOT / 'student_B/board_b/scripts/run_td.ps1'
WRAPPER_SHA = '371807DA4D8F259696F47EB84FE07A1C1C2E5D308FCDB956EAFB8136BD1C8371'
ADMISSION = EVIDENCE / 'student_final_admission.json'
EXPORT = EVIDENCE / 'student_final_export'
EXPORT_LOG = EVIDENCE / 'student_final_export_td.log'
OUTPUT = ROOT / 'student_B/board_b/output'
PASS_STA = 'PASS_ALL54_SR_108_CHECKS_AND_FULL9GROUP_STA'
METADATA_REVIEW = EVIDENCE / 'bitgen_bram_metadata_review.json'
METADATA_REVIEW_SHA = '48F4A6588C2411D6EED6DF2690F0C754AA9A9B17A69FB96D11A9D99413B008AE'
V1_ADMISSION_SHA = 'EE57E09B61162793D3EC0CADA39A07E877F53CCECEF044154C15AAABC00259C4'
V1_FINALIZER_SHA = '1016A1305429EA584E8AA62637AC9AE25679DF56181A4E90F281E5DB7F5EB63C'
READBACK_ON = ({'u_param_panel/u_rom/ramread0_syn_' + str(i) for i in (5, 8, 11, 14)} |
               {'u_ss_overlay/u_rom/ramread0_syn_' + str(i) for i in range(5, 36, 2)})


def require(value, message):
    if not value:
        raise ValueError(message)


def sha(path):
    with Path(path).open('rb') as stream:
        digest = hashlib.sha256()
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest().upper()


def read_json(path):
    return json.loads(Path(path).read_text(encoding='utf-8-sig'))


def resolve_record(value):
    value = str(value).replace('\\', '/')
    if value == '@font/Dengb.ttf':
        return Path('<WINDOWS_FONTS>/Dengb.ttf')
    path = Path(value)
    if not path.is_absolute():
        path = (WORKSPACE if value.startswith((ROOT.name + '/', '2026_', '_deliveries/')) else ROOT) / path
    return path.resolve()


def identity(path):
    path = Path(path).resolve()
    require(path.is_file(), 'Missing input/artifact: ' + str(path))
    return {'path': str(path), 'bytes': path.stat().st_size, 'sha256': sha(path)}


class Bindings:
    def __init__(self):
        self.records = {}

    def add(self, path, expected=None, size=None):
        record = identity(path)
        if expected is not None:
            require(bool(re.fullmatch(r'[A-Fa-f0-9]{64}', str(expected))), 'Malformed SHA256: ' + str(path))
            require(record['sha256'] == str(expected).upper(), 'SHA256 changed: ' + str(path))
        if size is not None:
            require(record['bytes'] == int(size), 'Size changed: ' + str(path))
        old = self.records.get(record['path'])
        require(old is None or old == record, 'Input changed during admission: ' + record['path'])
        self.records[record['path']] = record
        return record

    def record(self, record):
        return self.add(resolve_record(record['path']), record['sha256'], record.get('bytes'))

    def document(self, path):
        self.add(path)
        return read_json(path)

    def recheck(self):
        for record in list(self.records.values()):
            self.record(record)


def check_frozen_regressions(bind):
    frozen = bind.document(EVIDENCE / 'regression_frozen_20261026.json')
    require(frozen['result'] == 'PASS_15_CURRENT_INPUTS', 'Frozen regressions are not PASS')
    require(frozen['final_counts'] == dict(passed=15, failed=0, pending=0, stale=0, invalid_inputs=0),
            'Frozen regression count is not 15 current PASS')
    require(len(frozen['final_current_cases']) == 15, 'Missing frozen regression case')
    require(len(frozen['current_input_sha256']) == frozen['input_file_count'] == 143,
            'Frozen regression input contract changed')
    for name, expected in frozen['current_input_sha256'].items():
        bind.add(resolve_record(name), expected)
    for name, record in frozen['artifacts'].items():
        bind.add(resolve_record(name), record['sha256'], record['bytes'])
    require(len(frozen['artifacts']) == frozen['artifact_count'], 'Incomplete frozen artifacts')
    for name, record in frozen['final_current_cases'].items():
        path = resolve_record(record['receipt'])
        bind.add(path, record['receipt_sha256'])
        case = read_json(path)
        require(case['status'] == 'passed', 'Regression is not passed: ' + name)
        require(bool(case.get('sources')), 'Regression has no source bindings: ' + name)
        for source, expected in case['sources'].items():
            bind.add(resolve_record(source), expected)
    return {'cases': 15, 'input_files': 143, 'artifacts': frozen['artifact_count'],
            'result': frozen['result']}


def check_semantics_and_policy(bind):
    preservation = bind.document(EVIDENCE / 'student_route_only_preservation.json')
    require(preservation['comparison']['result'] == 'PASS', 'Route-only full preservation failed')
    require(preservation['comparison']['instances_before'] == preservation['comparison']['instances_after'] == 8993,
            'Unexpected placed cell count')
    require(preservation['comparison']['nets_before'] == preservation['comparison']['nets_after'] == 23285,
            'Unexpected placed net count')
    require({x['net'] for x in preservation['comparison']['net_route_changes']} == set(pnl.TARGETS),
            'Route-only changes are not exactly dup13/dup27')
    for record in preservation['inputs'].values():
        bind.record(record)
    require(preservation['inputs']['after_db']['sha256'] == DB_SHA and
            preservation['inputs']['after_pnl']['sha256'] == PNL_SHA, 'Wrong preservation target')
    # Its stricter-mode FAIL remains evidence. The caller's explicit default
    # policy below is evaluated separately, never by editing that receipt.
    strict = bind.document(EVIDENCE / 'student_route_only.reset_gate.json')
    require(strict['result'] == 'FAIL' and strict['summary']['strict_functional'] is True and
            strict['summary']['fatal_violations'] == 1, 'Optional strict FAIL1 evidence changed')
    require(strict['input']['sha256'] == PNL_SHA, 'Strict gate refers to another PNL')
    default = bind.document(EVIDENCE / 'student_candidate.default_reset_gate.json')
    require(default['input']['sha256'] == PNL_SHA, 'Default gate refers to another PNL')
    checks = {x['id']: x for x in default['checks']}
    require(len(checks) == len(default['checks']) == 3, 'Default reset gate checks incomplete/duplicated')
    for key in ('RESET-01-DISCOVERY', 'RESET-02-KEY-LUT-PATH'):
        require(checks[key]['status'] == 'PASS', key + ' not PASS')
    require(checks['RESET-03-BASELINE-DRIVER-AND-27-SR']['status'] == 'FAIL', 'Historical RESET03 FAIL not preserved')
    require(default['result'] == 'FAIL' and default['summary']['strict_functional'] is False and
            default['summary']['fatal_violations'] == 0 and default['summary']['warnings'] == 1 and
            len(default['warnings']) == 1, 'Unexpected default reset policy result')
    warning = default['warnings'][0]
    require(warning['net'] == pnl.TARGETS[0] and warning['row']['location'] == 'x7y3_1' and
            warning['row']['pins'] == 'a1.f1' and warning['row']['kind'] == 'functional_nonkey_bridge',
            'Unreviewed reset warning')
    bind.record(default['script'])
    policy = bind.document(EVIDENCE / 'student_sram_candidate_policy.json')
    require(policy['candidate_db_sha256'] == DB_SHA and policy['original_stage1_db_sha256'] == STAGE1_SHA,
            'Policy does not bind selected DB')
    require(policy['decision'] == 'CONDITIONAL_SRAM_CANDIDATE_ONLY_PENDING_FINAL_TIMING_AND_AFFECTED_RESET_STA',
            'No explicit SRAM-only policy')
    require(bool(policy['policy_review']['old_identity_check']) and bool(policy['policy_review']['independent_review']),
            'Historical mismatch/warning lacks explicit semantic policy review')
    semantics = bind.document(EVIDENCE / 'student_actual_reset_semantics.json')
    require(semantics['driver_semantics_result'] ==
            'ALL16_DRIVER_LANES_AND_ENDPOINT_TYPES_REVIEWED_NO_FUNCTIONAL_DATA_DRIVER_FOUND',
            'All16 actual reset driver review missing')
    require(len(semantics['all_reset_branches']) == 16 and len(semantics['identity_hold_buffers']) == 15,
            'Semantic map does not cover all reset branches/buffers')
    require(semantics['summary']['direct_load_pins'] == 528 and
            semantics['summary']['unique_physical_reset_pins_after_hold_buffer_expansion'] == 526,
            'Semantic endpoint population changed')
    for record in semantics['files']:
        bind.record(record)
    bind.record(semantics['old_route_only_pnl'])
    review = bind.document(EVIDENCE / 'student_postroute_semantic_review.json')
    for record in review['files']:
        bind.record(record)
    for key in ('instances_equal', 'nets_equal_by_identity', 'same16_reset_drivers_and528_load_pins',
                'same15_hold_buffers', 'same526_expanded_physical_reset_pins'):
        require(review['checks'][key] is True, 'Semantic preservation failed: ' + key)
    require(len(review['all16_semantic_preservation']) == 16 and
            all(x['driver_configuration_preserved'] and x['all_pins_and_loads_identical']
                for x in review['all16_semantic_preservation']), 'Incomplete all16 preservation review')
    require(review['historical_reset03'] == 'FAIL_PRESERVED_OLD_PLACEMENT_IDENTITY',
            'Old identity mismatch must remain explicit')
    return {'default_RESET01_RESET02': 'PASS', 'historical_RESET03': 'FAIL_REVIEWED_NEW_PLACEMENT',
            'optional_strict_gate': 'FAIL_ONE_FUNCTIONAL_BRIDGE_PRESERVED', 'warning': warning,
            'all16_driver_semantics': semantics['driver_semantics_result'],
            'policy': policy['decision'], 'risk': 'Functional bridge electrical purity is not proven; SRAM-only observation required.'}


def check_sta(bind, directory):
    directory = directory.resolve()
    require(EVIDENCE in directory.parents, '--sta-dir must be a candidate evidence subdirectory')
    receipt = bind.document(directory / 'affected_reset_sta_receipt.json')
    require(receipt['result'] == PASS_STA, 'Affected reset STA not ready/PASS: ' + receipt['result'])
    plan_record = bind.record(receipt['plan'])
    require(Path(plan_record['path']) == directory / 'expected_endpoints.json', 'Wrong STA plan location')
    plan = read_json(plan_record['path'])
    for record in plan['inputs'].values():
        bind.record(record)
    require(plan['inputs']['db']['sha256'] == DB_SHA and plan['inputs']['pnl']['sha256'] == PNL_SHA,
            'STA used another DB/PNL')
    require(plan['inputs']['canonical_wrapper']['sha256'] == WRAPPER_SHA, 'Canonical STA parser changed')
    require(plan['expected_endpoints'] == 54 and plan['expected_recovery_removal_checks'] == 108,
            'Wrong affected reset plan population')
    for name, record in receipt['artifacts'].items():
        actual = bind.record(record)
        require(Path(actual['path']) == directory / name and actual['bytes'] > 0, 'Wrong/empty STA artifact: ' + name)
    require(receipt['read_only_snapshot']['result'] == 'PASS', 'STA snapshot did not preserve the selected PNL')
    require(receipt['checks_total'] == 108 and set(receipt['groups']) == set(plan['groups']) == {'dup13', 'dup27'},
            'Incomplete affected groups')
    for label, expected_count in (('dup13', 37), ('dup27', 17)):
        group, expected = receipt['groups'][label], plan['groups'][label]
        require(group['endpoints'] == expected_count and group['checks'] == expected_count * 2,
                'Incomplete reset endpoints/checks: ' + label)
        for kind in ('recovery', 'removal'):
            paths = [p for p in group['paths'] if p['check'] == kind]
            require(Counter(p['endpoint'] for p in paths) == Counter(expected['endpoints'].keys()),
                    'Reset endpoint multiplicity mismatch: ' + label + '/' + kind)
            for path in paths:
                require(math.isfinite(path['slack_ns']) and path['slack_ns'] >= 0, 'Negative/malformed reset slack')
                require(path['begin'] == expected['driver'] + '.clk' and
                        expected['driver'] + '.' + expected['driver_port'] in path['pins'], 'Wrong reset launch lane')
                require(all(net in path['nets'] for net in expected['endpoints'][path['endpoint']]['via_nets']),
                        'Reset path bypassed reviewed route/buffer')
    full = receipt['full_sta']
    require(99.95 <= full['coverage'] <= 100 and full['max_groups'] == full['min_groups'] == 9,
            'Full nine-group canonical STA/coverage incomplete')
    require(full['global']['SWNS'] >= 0 and full['global']['HWNS'] >= 0 and
            full['global']['STNS'] == full['global']['HTNS'] == 0 and full['period_wns_ns'] >= 0,
            'Full STA reports setup/hold/period violation')
    expected_sdc = ROOT / 'student_B/board_b/constraints/board_b_top.sdc'
    require(resolve_record(full['constraints'].rstrip(';')) == expected_sdc, 'STA constraint identity mismatch')
    # Exact equivalent of the canonical wrapper's $hasTmds block. Its source
    # is SHA-pinned above and in the admission, without executing its body.
    exception = (directory / 'shengsheng_board_b_exception.timing').read_text(encoding='utf-8-sig')
    area = (directory / 'shengsheng_board_b_phy.area').read_text(encoding='utf-8-sig')
    pattern = r'set_max_delay -from \[get_clocks \{pixel_clk_5x\}\] -to \[get_ports \{HDMI_CLK_P HDMI_D0_P HDMI_D1_P HDMI_D2_P\}\] 8\.000 -datapath_only'
    require(re.search(pattern, exception) and re.search(r'Total Paths\s*:\s*8', exception) and
            re.search(r'Dominated\s*:\s*8,\s*100\.0%', exception), 'TMDS 8/8 constraint not active')
    delays = {}
    for lane in ('HDMI_CLK_P', 'HDMI_D0_P', 'HDMI_D1_P', 'HDMI_D2_P'):
        require(re.search(r'(?m)^\s*' + lane + r'\s+OUTPUT\s+\S+\s+LVDS33\s+PAD\s+NA\s+NONE\s+DDRX1\s*$', area),
                lane + ' is not LVDS33 DDRX1')
        found = re.search(r'End Point\s*:\s*' + lane + r'(?s:.*?)Data Path Delay\s*:\s*([0-9.]+)ns', exception)
        require(found is not None, 'Missing TMDS pad delay: ' + lane)
        delays[lane] = float(found.group(1))
        require(math.isfinite(delays[lane]) and 0 <= delays[lane] <= 8, 'Invalid TMDS pad delay: ' + lane)
    return {'directory': str(directory), 'result': receipt['result'], 'full_sta': full,
            'checks_total': 108, 'tmds_delays_ns': delays, 'canonical_wrapper_sha256': WRAPPER_SHA}


def check_metadata_review(bind):
    """Bind the reviewed, already-generated bit and the preserved v1 failure."""
    record = bind.add(METADATA_REVIEW, METADATA_REVIEW_SHA)
    review = read_json(METADATA_REVIEW)
    require(review['schema'] == 'controls_bitgen_bram_metadata_review/v1' and
            review['result'] == 'PASS_EXACT_BITGEN_ADDITIONS_INIT_CONTENT_PRESERVED',
            'Missing exact native-bitgen metadata review')
    for artifact in review['files'].values():
        bind.record(artifact)
    expected_paths = {'before_pnl': EXPORT / 'before_bitgen.pnl',
                      'after_pnl': EXPORT / 'after_bitgen.pnl',
                      'bid': EXPORT / 'shengsheng_board_b_top_inst.bid',
                      'source_selected_DB': SELECTED_DB,
                      'bitstream': EXPORT / 'shengsheng_board_b.bit',
                      'bitgen_log': EXPORT / 'bitgen.log',
                      'pnl_parser': Path(pnl.__file__)}
    for name, path in expected_paths.items():
        require(resolve_record(review['files'][name]['path']) == path.resolve(),
                'Metadata review binds wrong artifact: ' + name)
    require(review['files']['source_selected_DB']['sha256'] == DB_SHA,
            'Metadata review used another source DB')
    old_admission = bind.add(EVIDENCE / 'student_final_admission_v1.json', V1_ADMISSION_SHA)
    old_finalizer = bind.add(EVIDENCE / 'student_finalizer_v1.py.txt', V1_FINALIZER_SHA)
    old_failure = bind.add(EVIDENCE / 'student_postflight_v1_failure.json')
    failure = read_json(old_failure['path'])
    require(failure['result'] == 'FAIL' and
            failure['error'] == 'Final export changed full PNL: after_bitgen.pnl' and
            failure['admission_sha256'] == V1_ADMISSION_SHA and
            failure['finalizer_sha256'] == V1_FINALIZER_SHA and
            failure['bit_sha256'] == review['files']['bitstream']['sha256'],
            'Original strict postflight failure/history changed')
    return {'review': record, 'prior_v1_admission': old_admission,
            'prior_v1_finalizer': old_finalizer, 'prior_v1_failure': old_failure,
            'rule': 'Only the exact SHA-bound 50 emb additions READBACK/RID/WID, each matching native BID, may be removed in memory; then full PNL comparison with zero target exceptions must PASS.',
            'boundary': 'READBACK ON is backward-read capability, not OFF-default equivalence. No decoded-bitstream or electrical equivalence/board result is claimed.'}


def compare_exact_bitgen_metadata(original, before, after, review):
    """Validate every added line and native BID row before a narrow comparison."""
    rows = review['per_instance_exact_allowlist_and_full_INIT_values']
    require(len(rows) == 50, 'Metadata allowlist must contain exactly 50 instances')
    allow = {row['instance']: row for row in rows}
    require(len(allow) == 50, 'Duplicate metadata allowlist instance')
    strict = pnl.compare(original, after, targets=())
    names = sorted(allow)
    require(strict['result'] == 'FAIL' and strict['changed_instances'] == names and
            strict['errors'] == [{'instances_any_field_changed': names}],
            'After-bitgen strict differences exceed the exact 50 reviewed BRAM nodes')
    emb_names = {name for name, node in before['instances'].items()
                 if 'model emb;' in node.children}
    require(emb_names == set(allow), 'Metadata allowlist is not exactly all 50 original emb nodes')
    bid_root = ET.parse(resolve_record(review['files']['bid']['path'])).getroot()
    require(bid_root.tag == 'All_Bram_Infos', 'Unexpected native BID root')
    groups = bid_root.findall('AL_PHY_BRAM')
    require(len(groups) == 1 and len(groups[0]) == 50, 'Native BID must contain exactly 50 BRAM rows')
    bid = {}
    for element in groups[0]:
        require(re.fullmatch(r'INST_[0-9]+', element.tag), 'Unknown native BID instance element')
        values = {}
        for key in ('name', 'rid', 'wid', 'is_debuggable'):
            fields = element.findall(key)
            require(len(fields) == 1 and fields[0].text is not None, 'Missing/duplicate native BID field: ' + key)
            values[key] = fields[0].text.strip()
        require(values['name'] not in bid, 'Duplicate native BID instance')
        bid[values['name']] = (element, values)
    require(set(bid) == set(allow), 'Native BID/metadata instance names differ')
    normalized = dict(after)
    normalized['instances'] = dict(after['instances'])
    additions, ids, on_names = [], [], set()

    def attributes(node):
        section = pnl.section(node, 'attribute')
        fields = {}
        for line in section.children:
            match = re.fullmatch(r'([^:=\s]+)([:=])(.+)', line)
            require(match is not None and match.group(1) not in fields, 'Unknown/duplicate BRAM attribute: ' + line)
            fields[match.group(1)] = line
        return section, fields

    for name in names:
        row, old, new = allow[name], before['instances'][name], after['instances'][name]
        require(row['model'] == 'emb' and 'model emb;' in old.children and 'model emb;' in new.children,
                'Metadata addition is not on an unchanged emb model: ' + name)
        old_section, old_fields = attributes(old)
        new_section, new_fields = attributes(new)
        keys = {'READBACK', 'RID', 'WID'}
        require(not (keys & set(old_fields)) and set(new_fields) - set(old_fields) == keys and
                set(old_fields) <= set(new_fields) and
                all(new_fields[key] == line for key, line in old_fields.items()),
                'Metadata overwrites/removes an original attribute or adds an unknown key: ' + name)
        added = [line for line in new_section.children if line not in old_section.children]
        require(len(added) == 3 and sorted(added) == row['exact_added_attribute_lines'],
                'Added BRAM lines differ from reviewed exact values: ' + name)
        expected = row['expected_additions']
        require(set(expected) == keys and new_fields['READBACK'] == 'READBACK:' + expected['READBACK'] and
                new_fields['RID'] == 'RID=' + expected['RID'] and new_fields['WID'] == 'WID=' + expected['WID'],
                'Malformed/extraneous reviewed BRAM additions: ' + name)
        require(re.fullmatch(r'0x[0-9A-F]{4}', expected['RID']) and expected['RID'] == expected['WID'],
                'BRAM RID/WID are not equal exact hexadecimal IDs: ' + name)
        require(expected['READBACK'] == ('ON' if name in READBACK_ON else 'OFF'),
                'BRAM READBACK does not match the exact 4+16 ROM allowlist: ' + name)
        element, bid_values = bid[name]
        for key, value in row['BID'].items():
            if key == 'xml_element':
                require(element.tag == value, 'Native BID element identity mismatch: ' + name)
            else:
                fields = element.findall(key)
                require(len(fields) == 1 and (fields[0].text or '').strip() == value,
                        'Native BID differs from exact reviewed row: ' + name + '/' + key)
        require(bid_values['rid'] == expected['RID'].upper() and
                bid_values['wid'] == expected['WID'].upper() and
                bid_values['is_debuggable'] == ('y' if expected['READBACK'] == 'ON' else 'n'),
                'Native BID RID/WID/debug flag does not match added BRAM metadata: ' + name)
        ids.append(int(expected['RID'], 16))
        if expected['READBACK'] == 'ON':
            on_names.add(name)
        stripped = pnl.Node(new_section.label, [line for line in new_section.children if line not in added])
        cleaned = pnl.Node(new.label, [stripped if item is new_section else item for item in new.children])
        require(pnl.canonical(old) == pnl.canonical(cleaned),
                'BRAM has another field/INIT/order change after exact metadata removal: ' + name)
        normalized['instances'][name] = cleaned
        additions.append({'instance': name, 'model': 'emb', 'exact_added_attribute_lines': added,
                          'BID': row['BID'], 'existing_INIT_parameter_count': row['INIT_parameter_count'],
                          'existing_INIT_canonical_sha256': row['INIT_canonical_sha256']})
    require(sorted(ids) == list(range(4, 54)) and on_names == READBACK_ON,
            'BRAM IDs must be unique 4..53 and READBACK exactly 20 ON / 30 OFF')
    final = pnl.compare(original, normalized, targets=())
    require(final['result'] == 'PASS', 'Full PNL differs after exact reviewed metadata removal')
    return {'result': 'PASS_EXACT_REVIEWED_BITGEN_ADDITIONS_ONLY',
            'original_strict_comparison': strict, 'exact_added_metadata': additions,
            'native_BID_match': 'PASS_ALL50_NAMES_IDS_AND_DEBUG_FLAGS',
            'full_comparison_after_exact_in_memory_removal': final,
            'review_sha256': METADATA_REVIEW_SHA,
            'boundary': 'Raw output PNL remains unchanged and SHA-bound. The three added attributes are recorded explicitly; no blanket BRAM/INIT/route exception or hardware equivalence is asserted.'}


def preflight(sta_directory):
    bind = Bindings()
    bind.add(Path(__file__))
    bind.add(Path(pnl.__file__))
    bind.add(ROOT / 'tools/export_student_candidate.tcl')
    bind.add(SELECTED_DB, DB_SHA)
    bind.add(SELECTED_PNL, PNL_SHA)
    bind.add(STAGE1_DB, STAGE1_SHA)
    bind.add(WRAPPER, WRAPPER_SHA)
    scope = bind.document(EVIDENCE / 'feature_source_scope.json')
    require(scope['constraints_and_clock_reset_sources_unchanged'] is True, 'Source scope changed constraints/clocks/reset')
    populations = {}
    for board, expected_count in (('student_B', 107), ('teacher_A', 56)):
        inputs = scope['changes'][board]['input_snapshot']
        require(len(inputs) == expected_count, 'Incomplete authenticated source scope: ' + board)
        for name, expected in inputs.items():
            bind.add(ROOT / board / name, expected)
        populations[board] = len(inputs)
    regression = check_frozen_regressions(bind)
    semantics = check_semantics_and_policy(bind)
    timing = check_sta(bind, sta_directory)
    metadata_policy = check_metadata_review(bind)
    bind.recheck()
    admission = {'schema': 'controls_student_same_db_admission/v2',
        'result': 'SRAM_ONLY_CANDIDATE', 'formal_release': False, 'hardware': 'PENDING',
        'mode': 'same_db_splitflow', 'place_seed': 1, 'candidate_db_sha256': DB_SHA,
        'candidate_pnl_sha256': PNL_SHA, 'sta_directory': str(sta_directory.resolve()),
        'source_populations': populations, 'regression': regression,
        'reset_policy_and_semantic_review': semantics, 'timing': timing,
        'exact_bitgen_metadata_policy': metadata_policy,
        'inputs': dict(sorted(bind.records.items())),
        'boundary': 'Admission only: no board result, no Flash write, no formal promotion. Optional strict FAIL and historical RESET03 FAIL are retained.'}
    if ADMISSION.exists():
        frozen = read_json(ADMISSION)
        require(frozen == admission, 'Successful admission already frozen with different inputs; refusing overwrite')
    else:
        with ADMISSION.open('x', encoding='utf-8') as stream:
            stream.write(json.dumps(admission, ensure_ascii=False, indent=2) + '\n')
    return admission, bind


def postflight(admission, bind):
    require(not OUTPUT.exists(), 'Refusing to overwrite existing student_B/board_b/output')
    export_log = EXPORT_LOG.read_text(encoding='utf-8-sig')
    require(len(re.findall(r'^\s*CONTROLS_STUDENT_FINAL_EXPORT_COMPLETE=1\s*$', export_log, re.M)) == 1,
            'Missing/duplicate genuine final-export completion marker')
    require(not re.search(r'(?im)^.*\bERROR\s*:', export_log), 'Final export TD log contains ERROR')
    require('Tang Dynasty, V6.2.168116' in export_log and
            re.search(r'(?m)^RUN-1002\s*:\s*start command "bitgen -bit ', export_log),
            'Final export log lacks native TD identity/bitgen command')
    bitgen_log = (EXPORT / 'bitgen.log').read_text(encoding='utf-8-sig')
    require(not re.search(r'(?im)^.*\bERROR\s*:', bitgen_log), 'Bitgen log contains ERROR')
    require(SELECTED_DB.as_posix() in export_log.replace('\\', '/'), 'Export log does not identify the selected DB')
    bit = EXPORT / 'shengsheng_board_b.bit'
    require(bit.is_file() and bit.stat().st_size > 0, 'Missing/empty candidate bitstream')
    original = pnl.parse_pnl(SELECTED_PNL.read_text(encoding='utf-8-sig'))
    before = pnl.parse_pnl((EXPORT / 'before_bitgen.pnl').read_text(encoding='utf-8-sig'))
    comparisons = {'before_bitgen.pnl': pnl.compare(original, before, targets=())}
    require(comparisons['before_bitgen.pnl']['result'] == 'PASS',
            'Final export changed full PNL: before_bitgen.pnl')
    after = pnl.parse_pnl((EXPORT / 'after_bitgen.pnl').read_text(encoding='utf-8-sig'))
    comparisons['after_bitgen.pnl'] = compare_exact_bitgen_metadata(original, before, after, read_json(METADATA_REVIEW))
    artifacts = [identity(p) for p in sorted(EXPORT.rglob('*')) if p.is_file()]
    require(artifacts, 'No export artifacts')
    artifacts.append(identity(EXPORT_LOG))
    bind.recheck()
    require(sha(SELECTED_DB) == DB_SHA and sha(STAGE1_DB) == STAGE1_SHA, 'Source DB changed after export')
    sta = Path(admission['sta_directory'])
    sources = {'shengsheng_board_b.bit': bit, 'build.log': EXPORT_LOG}
    for name in ('final_timing.rpt', 'final_timing_violations.rpt',
                 'shengsheng_board_b_exception.timing', 'shengsheng_board_b_phy.area'):
        sources[name] = sta / name
    stage = OUTPUT.with_name('output.stage_' + uuid.uuid4().hex)
    require(stage.parent == ROOT / 'student_B/board_b', 'Unsafe publication staging directory')
    stage.mkdir(exist_ok=False)
    published = []
    for name, source in sources.items():
        before = identity(source)
        shutil.copyfile(source, stage / name)
        copied = identity(stage / name)
        require(copied['sha256'] == before['sha256'] and copied['bytes'] == before['bytes'], 'Staged copy mismatch: ' + name)
        copied['path'] = str(OUTPUT / name)
        copied['source'] = before
        published.append(copied)
    receipt = {'schema': 'controls_student_same_db_splitflow_build/v2',
        'mode': 'same_db_splitflow', 'result': 'SRAM_ONLY_CANDIDATE', 'formal_release': False,
        'hardware': 'PENDING', 'place_seed': 1, 'device': 'EG4S20BG256', 'top': 'shengsheng_board_b_top',
        'generated_at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
        'source_scope': identity(EVIDENCE / 'feature_source_scope.json'),
        'admission': identity(ADMISSION), 'source_db': identity(SELECTED_DB),
        'source_pnl': identity(SELECTED_PNL), 'original_stage1_db': identity(STAGE1_DB),
        'inputs': admission['inputs'], 'timing': admission['timing'],
        'reset_policy_and_semantic_review': admission['reset_policy_and_semantic_review'],
        'exact_bitgen_metadata_policy': admission['exact_bitgen_metadata_policy'],
        'export_pnl_comparisons': comparisons, 'export_artifacts': artifacts, 'artifacts': published,
        'build_log_scope': 'build.log is the final same-DB export TD log; this is not a canonical single-run build receipt.',
        'boundary': admission['boundary']}
    (stage / 'shengsheng_board_b_build_receipt.json').write_text(
        json.dumps(receipt, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    bind.recheck()
    for record in artifacts:
        require(identity(record['path']) == record, 'Export artifact changed before publication')
    require(not OUTPUT.exists(), 'Output appeared during finalization; preserving staged files')
    os.rename(stage, OUTPUT)
    return {'result': 'SRAM_ONLY_CANDIDATE', 'bit': identity(OUTPUT / bit.name),
            'receipt': identity(OUTPUT / 'shengsheng_board_b_build_receipt.json')}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--preflight', action='store_true', help='Freeze/verify admission only; never publish outputs')
    parser.add_argument('--sta-dir', type=Path, help='Successful STA evidence directory; first run defaults to v3, later runs reuse frozen admission')
    args = parser.parse_args()
    try:
        if args.sta_dir is not None:
            directory = args.sta_dir.resolve()
        elif ADMISSION.exists():
            directory = Path(read_json(ADMISSION)['sta_directory'])
        else:
            directory = EVIDENCE / 'student_affected_reset_sta_v3'
        admission, bind = preflight(directory)
        result = {'result': admission['result'], 'admission': identity(ADMISSION),
                  'mode': 'preflight' if args.preflight else 'postflight', 'sta_directory': admission['sta_directory']}
        if not args.preflight:
            result.update(postflight(admission, bind))
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 0
    except Exception as exc:
        print(json.dumps({'result': 'FAIL', 'mode': 'preflight' if args.preflight else 'postflight',
                          'error': str(exc)}, ensure_ascii=False, indent=2), file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
