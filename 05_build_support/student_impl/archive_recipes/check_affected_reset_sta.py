"""Prepare/check read-only A793 STA: 37+17 SR endpoints, 108 reset checks."""
import argparse
from collections import Counter
import datetime
import hashlib
import json
from pathlib import Path
import re
import subprocess
import time
import verify_student_route_only as pnl_parser

ROOT = Path(__file__).resolve().parents[1]
DB_SHA = 'A79315D9825A88CAE151739381D3A3AFFBA5E27379B783101B7E6AAB4FACACC9'
PNL_SHA = 'CAE003C47F0BE12477E2DCEAA0B1EBC7473C5DAF78CD5359E6027D86CA64D265'
SEMANTICS = ROOT/'evidence/student_actual_reset_semantics.json'
WRAPPER = ROOT/'student_B/board_b/scripts/run_td.ps1'
SDC = ROOT/'student_B/board_b/constraints/board_b_top.sdc'
DEFAULT_OUT = ROOT/'evidence/student_affected_reset_sta_v2'
NUM = r'[-+]?\d+(?:\.\d+)?'


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest().upper()


def record(path):
    path = Path(path).resolve()
    return {'path': str(path), 'sha256': sha(path), 'bytes': path.stat().st_size}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def tcl_literal(value):
    require(not any(ch in value for ch in ('{', '}', '\n', '\r')), 'Unsafe Tcl literal')
    return '{'+value+'}'


def expand_semantics(doc, placed):
    branches = {x['net']: x for x in doc['all_reset_branches']}
    buffers = {x['net']: x for x in doc['identity_hold_buffers']}
    result = {}
    visited_buffers = set()
    for target, count in zip(pnl_parser.TARGETS, (37, 17)):
        branch = branches[target]
        endpoints = {}

        def visit(net, driver, driver_port, loads, chain):
            require(net in placed['nets'], 'Missing actual net '+net)
            expected = Counter([(driver, driver_port)]+[(x['instance'], x['port']) for x in loads])
            require(pnl_parser.net_fields(placed['nets'][net])['pins'] == expected,
                    'Actual complete pin list differs from semantic map for '+net)
            for load in loads:
                if load['port'] == 'sr':
                    endpoint = load['instance']+'.sr'
                    require(endpoint not in endpoints, 'Duplicate expanded endpoint '+endpoint)
                    endpoints[endpoint] = {'via_nets': chain, 'indirect_hold_buffer': len(chain) > 1}
                else:
                    require(load.get('type') == 'identity_hold_buffer_input', 'Unreviewed non-SR load')
                    down = load['downstream_net']
                    require(down in buffers and down not in visited_buffers, 'Missing/repeated hold buffer '+down)
                    hold = buffers[down]
                    require(hold['input_net'] == net and hold['driver']['instance'] == load['instance'],
                            'Hold-buffer input/driver identity mismatch')
                    pin_nets = hold['driver']['pnl_pin_nets']
                    outputs = [port for port, connected in pin_nets.items() if connected == down and port.startswith(('f[', 'fx['))]
                    require(len(outputs) == 1, 'Ambiguous identity hold-buffer output')
                    visited_buffers.add(down)
                    visit(down, hold['driver']['instance'], outputs[0], hold['complete_loads'], chain+[down])

        visit(target, branch['driver']['instance'], branch['driver_port'], branch['complete_direct_loads'], [target])
        require(len(endpoints) == count, 'Expected %d expanded SR endpoints for %s' % (count, target))
        label = target.rsplit('_', 1)[-1]
        result['dup'+label] = {'target_net': target, 'driver': branch['driver']['instance'],
                               'driver_port': branch['driver_port'], 'expected_sr_count': count,
                               'endpoints': endpoints}
    require(len(visited_buffers) == 5, 'Must expand exactly five affected hold buffers')
    all_endpoints = [ep for group in result.values() for ep in group['endpoints']]
    require(len(all_endpoints) == len(set(all_endpoints)) == 54, 'Expected 54 unique affected physical SR pins')
    return result


def prepare(args):
    out = args.outdir.resolve()
    require(ROOT in out.parents, 'Output must stay inside candidate')
    require(sha(args.db) == DB_SHA and sha(args.pnl) == PNL_SHA, 'Input DB/PNL are not fixed A793/CAE003C4')
    require(not any((out/name).exists() for name in ('affected_dup13.rpt', 'affected_dup27.rpt', 'completed.txt')),
            'STA outputs already exist; preserve them and use another output directory')
    placed = pnl_parser.parse_pnl(args.pnl.read_text(encoding='utf-8-sig'))
    doc = json.loads(SEMANTICS.read_text(encoding='utf-8-sig'))
    groups = expand_semantics(doc, placed)
    inputs = {name: record(path) for name, path in [('db', args.db), ('pnl', args.pnl),
              ('semantic_map', SEMANTICS), ('sdc', SDC), ('canonical_wrapper', WRAPPER),
              ('tcl', ROOT/'tools/report_affected_reset_sta.tcl'), ('checker', Path(__file__)),
              ('pnl_parser', Path(pnl_parser.__file__))]}
    manifest = {'schema': 'controls_affected_reset_sta_plan/v1', 'prepared_epoch': time.time(),
                'inputs': inputs, 'groups': groups, 'expected_endpoints': 54,
                'expected_recovery_removal_checks': 108, 'hardware': 'NOT_TESTED', 'bitgen': False}
    out.mkdir(parents=True, exist_ok=True)
    (out/'expected_endpoints.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding='utf-8')
    plan = []
    for label, group in groups.items():
        # get_cells uses a glob; escaped brackets select the literal packed cell.
        pattern = group['driver'].replace('\\', '\\\\').replace('[', '\\[').replace(']', '\\]')
        plan.append('    [list '+tcl_literal(label)+' '+tcl_literal(group['driver'])+' '+tcl_literal(pattern)+']')
    text = 'set controls_sta_source_db '+tcl_literal(str(args.db.resolve()).replace('\\', '/'))+'\n'
    text += 'set controls_sta_expected_db_sha256 '+tcl_literal(DB_SHA)+'\n'
    text += 'set controls_sta_driver_plan [list \\\n'+' \\\n'.join(plan)+']\n'
    (out/'affected_plan.tcl').write_text(text, encoding='utf-8')
    print('AFFECTED_STA_PREPARED endpoints=54 hold_buffers=5 checks=108', str(out))


def parse_paths(text):
    starts = list(re.finditer(r'^Slack[ \t]*:[ \t]*('+NUM+r')ns[ \t]*$', text, re.M))
    require(starts, 'No detailed STA paths')
    paths = []
    for i, match in enumerate(starts):
        block = text[match.start():starts[i+1].start() if i+1 < len(starts) else len(text)]
        def field(name, pattern):
            values = re.findall(r'^'+re.escape(name)+r'[ \t]*:[ \t]*'+pattern, block, re.M)
            require(len(values) == 1, 'Missing/duplicated path field '+name)
            return values[0]
        check = field('Check Type', r'(\S+)')
        require(check in ('setup', 'hold', 'recovery', 'removal'), 'Unknown timing check type '+check)
        paths.append({'slack_ns': float(match.group(1)), 'check': check,
            'endpoint': field('End Point', r'(\S+)'), 'begin': field('Begin Point', r'(\S+)'),
            'nets': [x.rstrip(',') for x in re.findall(r'\bnet:[ \t]*(\S+)', block)],
            'pins': [x.rstrip(',') for x in re.findall(r'\bpin:[ \t]*(\S+)', block)]})
    return paths


def canonical_full_sta(out):
    # Extract the exact existing canonical validators, never its build body.
    quote = lambda value: "'"+str(value).replace("'", "''")+"'"
    script = "$ErrorActionPreference='Stop';$tok=$null;$err=$null;"
    script += '$ast=[System.Management.Automation.Language.Parser]::ParseFile('+quote(WRAPPER)+',[ref]$tok,[ref]$err);if($err.Count){throw "Wrapper parse"};'
    script += "foreach($name in @('Get-TimingHeader','Assert-TimingRows','Assert-TimingText','Assert-ViolationsText')){$f=@($ast.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true));if($f.Count -ne 1){throw 'Missing gate'};Invoke-Expression $f[0].Extent.Text};"
    script += "$topName='shengsheng_board_b_top';"
    script += '$full=Assert-TimingText (Get-Content -Raw -LiteralPath '+quote(out/'final_timing.rpt')+');'
    script += 'Assert-ViolationsText (Get-Content -Raw -LiteralPath '+quote(out/'final_timing_violations.rpt')+') $full;'
    script += "if($full.max_groups -ne 9 -or $full.min_groups -ne 9){throw 'Expected all nine Max/Min groups'};$full|ConvertTo-Json -Depth 8 -Compress;"
    ran = subprocess.run(['powershell.exe', '-NoProfile', '-NonInteractive', '-Command', script], capture_output=True, text=True, timeout=120)
    require(ran.returncode == 0, 'Canonical full STA failed: '+ran.stderr[-2500:])
    return json.loads(ran.stdout.strip())


def check(args):
    out = args.outdir.resolve()
    receipt = {'schema': 'controls_affected_reset_sta_receipt/v1', 'result': 'FAIL',
               'hardware': 'NOT_TESTED', 'bitgen': False, 'groups': {}}
    try:
        manifest_path = out/'expected_endpoints.json'
        plan = json.loads(manifest_path.read_text(encoding='utf-8'))
        receipt['plan'] = record(manifest_path)
        for name, info in plan['inputs'].items():
            require(sha(info['path']) == info['sha256'], 'Input changed after preparation: '+name)
        require(plan['inputs']['db']['sha256'] == DB_SHA, 'Wrong DB identity')
        marker = (out/'completed.txt').read_text(encoding='utf-8')
        require('AFFECTED_RESET_STA_COMPLETE=1' in marker and 'DB_SHA256='+DB_SHA in marker, 'Missing genuine completion marker')
        expected_files = ['affected_dup13.rpt', 'affected_dup27.rpt', 'final_timing.rpt',
                          'final_timing_violations.rpt', 'shengsheng_board_b_exception.timing',
                          'shengsheng_board_b_phy.area', 'final_timing.ts', 'sta_snapshot.pnl', 'completed.txt']
        for name in expected_files:
            path = out/name
            require(path.stat().st_size > 0 and path.stat().st_mtime >= plan['prepared_epoch'], 'Missing/stale output '+name)
        initial = pnl_parser.parse_pnl(Path(plan['inputs']['pnl']['path']).read_text(encoding='utf-8-sig'))
        snapshot = pnl_parser.parse_pnl((out/'sta_snapshot.pnl').read_text(encoding='utf-8-sig'))
        receipt['read_only_snapshot'] = pnl_parser.compare(initial, snapshot, targets=())
        require(receipt['read_only_snapshot']['result'] == 'PASS', 'STA snapshot differs from A793 PNL')
        receipt['full_sta'] = canonical_full_sta(out)
        total = 0
        for label, group in plan['groups'].items():
            text = (out/('affected_'+label+'.rpt')).read_text(encoding='utf-8-sig')
            require(re.search(r'^Top Model[ \t]*:[ \t]*shengsheng_board_b_top[ \t]*$', text, re.M), 'Wrong path-report top')
            require(re.search(r'^Device[ \t]*:[ \t]*EG4S20BG256[ \t]*$', text, re.M), 'Wrong path-report device')
            paths = parse_paths(text)
            selected = [x for x in paths if x['check'] in ('recovery', 'removal')]
            wanted = group['endpoints']
            checked = []
            for kind in ('recovery', 'removal'):
                observed = [x for x in selected if x['check'] == kind]
                require(Counter(x['endpoint'] for x in observed) == Counter(wanted.keys()), 'Incomplete/extra/duplicate '+label+' '+kind+' endpoints')
                for path in observed:
                    require(path['slack_ns'] >= 0, 'Negative '+kind+' slack at '+path['endpoint'])
                    require(path['begin'] == group['driver']+'.clk', 'Wrong launch cell')
                    require(group['driver']+'.'+group['driver_port'] in path['pins'], 'Wrong packed driver lane')
                    require(all(net in path['nets'] for net in wanted[path['endpoint']]['via_nets']),
                            'Path bypasses required target/hold-buffer net at '+path['endpoint'])
                    checked.append(path)
            receipt['groups'][label] = {'endpoints': len(wanted), 'checks': len(checked),
                'recovery_min_ns': min(x['slack_ns'] for x in checked if x['check'] == 'recovery'),
                'removal_min_ns': min(x['slack_ns'] for x in checked if x['check'] == 'removal'),
                'indirect_endpoints': sum(v['indirect_hold_buffer'] for v in wanted.values()),
                'other_setup_hold_paths_reported': len(paths)-len(selected), 'paths': checked}
            total += len(checked)
        require(total == 108, 'Expected exactly 108 affected recovery/removal checks')
        receipt['checks_total'] = total
        receipt['artifacts'] = {name: record(out/name) for name in expected_files}
        for name, info in plan['inputs'].items():
            require(sha(info['path']) == info['sha256'], 'Input changed during checking: '+name)
        receipt['result'] = 'PASS_ALL54_SR_108_CHECKS_AND_FULL9GROUP_STA'
    except Exception as exc:
        receipt['error'] = str(exc)
    destination = args.out or out/'affected_reset_sta_receipt.json'
    require(ROOT in destination.resolve().parents, 'Receipt must stay inside candidate')
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(json.dumps(receipt, ensure_ascii=False, indent=2), encoding='utf-8')
    print(receipt['result'], str(destination))
    return 0 if receipt['result'].startswith('PASS_') else 1


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--prepare', action='store_true')
    p.add_argument('--db', type=Path, default=ROOT/'evidence/student_seed1_route_only/student_route_only_pr.db')
    p.add_argument('--pnl', type=Path, default=ROOT/'evidence/student_seed1_route_only/after.pnl')
    p.add_argument('--outdir', type=Path, default=DEFAULT_OUT)
    p.add_argument('--out', type=Path)
    args = p.parse_args()
    if args.prepare:
        prepare(args)
        return 0
    return check(args)


if __name__ == '__main__':
    raise SystemExit(main())
