"""Fail-closed, offline two-net route-only comparison; never invokes TD/bitgen.

All PNL nodes are retained, including unknown fields. Only the recognized
export timestamp and route/feedthrough bodies of the two exact target nets
may differ. The existing reset gate is run without a target override. A
historical RESET-03 mismatch requires separate semantic review (exit 2).
"""
import argparse
from collections import Counter
from dataclasses import dataclass
import datetime
import gzip
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
WORKSPACE = ROOT.parent
PHY = ROOT/'student_B/td_shengsheng_b_run/shengsheng_board_b_Runs/phy_1'
PREFIX = 'u_hdmi14_core/u_hdmi_edid_wrapper/u_iic_master_wrapper/u_iic_receiver_controller/'
TARGETS = (PREFIX+'I_rst_dup_13', PREFIX+'I_rst_dup_27')
BEFORE_DB_SHA = '606EF84D275E617B8F22A1916975BC7BE9A91ECF60C25C76F1092A8ADEC686E7'
BEFORE_PNL_SHA = 'A05838F37B9D8FBC4BA1E0942779FD81994FAF9FC0B1C2F302486501EE71966C'
HISTORICAL_BASELINE_SHA = '0B4D4B29F3652CF3B010588DAC1D5B9D969AF5FEF10A0400FAF14B404879BB75'
GATE = WORKSPACE/'_deliveries/gates_20261025/gate_reset_branch.py'
BASELINE = WORKSPACE/'2026_topic1_shengsheng_sm_f1c/evidence/seed1_implementation_audit/reset24_feedthrough_branch_review.json'
TIMESTAMP = re.compile(r'^// (?:Mon|Tue|Wed|Thu|Fri|Sat|Sun) '
                       r'(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) '
                       r'\s*\d{1,2} \d{2}:\d{2}:\d{2} \d{4}$')


@dataclass
class Node:
    label: str
    children: list


def digest(data):
    return hashlib.sha256(data).hexdigest().upper()


def file_info(path):
    path = Path(path).resolve()
    data = path.read_bytes()
    payload = gzip.decompress(data) if data[:2] == b'\x1f\x8b' else data
    return {'path': str(path), 'bytes': len(data), 'sha256': digest(data),
            'content_bytes': len(payload), 'content_sha256': digest(payload)}, payload


def canonical(item):
    if isinstance(item, str):
        return ('line', item)
    return ('block', item.label, tuple(canonical(child) for child in item.children))


def parse_pnl(text):
    """Retain every nonblank token line, with balanced and unambiguous braces."""
    root = Node('<document>', [])
    stack = [root]
    for number, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if not line:
            continue
        if line == '{':
            if not stack[-1].children or not isinstance(stack[-1].children[-1], str):
                raise ValueError('Unlabelled opening brace at line %d' % number)
            node = Node(stack[-1].children.pop(), [])
            stack[-1].children.append(node)
            stack.append(node)
        elif line == '}':
            if len(stack) == 1:
                raise ValueError('Unmatched closing brace at line %d' % number)
            stack.pop()
        else:
            stack[-1].children.append(line)
    if len(stack) != 1:
        raise ValueError('Unclosed PNL block(s)')
    # Only TD's precisely recognized creation-time header is metadata.
    # Every other header, comment and unknown body node remains comparable.
    timestamps = [i for i, value in enumerate(root.children)
                  if isinstance(value, str) and TIMESTAMP.fullmatch(value)]
    if timestamps != [2]:
        raise ValueError('Expected exactly one known TD export timestamp at header line 3')
    created = root.children.pop(2)
    designs = [x for x in root.children if isinstance(x, Node) and x.label.startswith('design ')]
    if len(designs) != 1 or 'Pnl Version: 2.0' not in root.children:
        raise ValueError('Expected one PNL 2.0 design')
    design = designs[0]
    instances, nets, misc = {}, {}, []
    for item in design.children:
        destination = None
        if isinstance(item, Node) and item.label.startswith('instance '):
            destination = instances
        elif isinstance(item, Node) and item.label.startswith('net '):
            destination = nets
        if destination is None:
            misc.append(item)
            continue
        name = item.label.split(' ', 1)[1].strip()
        if not name or name in destination:
            raise ValueError('Empty/duplicate named object: '+item.label)
        destination[name] = item
    if not instances or not nets:
        raise ValueError('Empty instance/net discovery is not a comparison')
    for name, instance in instances.items():
        for field in ('model ', 'location '):
            values = [x for x in instance.children if isinstance(x, str) and x.startswith(field)]
            if len(values) != 1 or not values[0].endswith(';'):
                raise ValueError('Missing/ambiguous '+field+'in instance '+name)
    header = Node(root.label, [Node(design.label, misc) if x is design else x for x in root.children])
    return {'instances': instances, 'nets': nets, 'header_misc': canonical(header),
            'created': created}


def section(net, label, optional=False):
    found = [x for x in net.children if isinstance(x, Node) and x.label == label]
    if not found and optional:
        return Node(label, [])
    if len(found) != 1:
        raise ValueError('Missing/duplicate '+label+' in '+net.label)
    if any(not isinstance(x, str) for x in found[0].children):
        raise ValueError('Unknown nested content in '+label+' in '+net.label)
    return found[0]


def net_fields(net):
    pins, edges, feedthroughs = [], [], []
    for label, destination in [('pin', pins), ('route', edges)]:
        for value in section(net, label, optional=label != 'pin').children:
            if not value.endswith(';') or value[:-1].count(',') != 1:
                raise ValueError('Unknown '+label+' syntax in '+net.label+': '+value)
            pair = tuple(part.strip() for part in value[:-1].split(','))
            if not all(pair):
                raise ValueError('Empty '+label+' endpoint in '+net.label)
            destination.append(pair)
    for value in section(net, 'feedthroughs', optional=True).children:
        if not re.fullmatch(r'x\d+y\d+_\d+\([^()\s]+\)', value):
            raise ValueError('Unknown feedthrough syntax in '+net.label+': '+value)
        feedthroughs.append(value)
    other = [canonical(x) for x in net.children if not isinstance(x, Node)
             or x.label not in ('pin', 'route', 'feedthroughs')]
    return {'pins': Counter(pins), 'route': Counter(edges),
            'feedthroughs': Counter(feedthroughs), 'other': tuple(other),
            'section_presence': {label: any(isinstance(x, Node) and x.label == label for x in net.children)
                                 for label in ('route', 'feedthroughs')}}


def counter_rows(counter):
    return [{'value': list(key) if isinstance(key, tuple) else key, 'count': count}
            for key, count in sorted(counter.items())]


def pin_details(fields, output_port_bases):
    def base(port):
        found = re.match(r'([A-Za-z_]+)', port)
        return found.group(1).lower() if found else ''
    rows = [{'instance': cell, 'port': port, 'count': count}
            for (cell, port), count in sorted(fields['pins'].items())]
    return {'all_pins': rows,
            'drivers': [r for r in rows if base(r['port']) in output_port_bases],
            'sr_sinks': [r for r in rows if base(r['port']) == 'sr'],
            'other_loads': [r for r in rows if base(r['port']) not in output_port_bases and base(r['port']) != 'sr'],
            'driver_classification': 'Same explicit output-port-base rule as the SHA-bound existing reset gate.'}


def compare(before, after, targets=TARGETS, output_port_bases=frozenset(('q', 'f', 'fx', 'fco'))):
    errors, changes = [], []
    if before['header_misc'] != after['header_misc']:
        errors.append('Design/header/interface/unknown top-level fields changed')
    for kind in ('instances', 'nets'):
        missing = sorted(set(before[kind])-set(after[kind]))
        extra = sorted(set(after[kind])-set(before[kind]))
        if missing or extra:
            errors.append({'object_set_changed': kind, 'missing': missing, 'extra': extra})
    changed_instances = [name for name in sorted(set(before['instances']) & set(after['instances']))
                         if canonical(before['instances'][name]) != canonical(after['instances'][name])]
    if changed_instances:
        errors.append({'instances_any_field_changed': changed_instances})
    changed_routes, target_pins = [], {}
    for name in sorted(set(before['nets']) & set(after['nets'])):
        old, new = net_fields(before['nets'][name]), net_fields(after['nets'][name])
        if name in targets:
            target_pins[name] = {'before': pin_details(old, output_port_bases),
                                 'after': pin_details(new, output_port_bases)}
        if old['pins'] != new['pins']:
            errors.append({'net_pin_connections_changed': name,
                           'removed': counter_rows(old['pins']-new['pins']),
                           'added': counter_rows(new['pins']-old['pins'])})
        if old['other'] != new['other']:
            errors.append({'net_unknown_or_nonrouting_fields_changed': name})
        changed = [field for field in ('route', 'feedthroughs') if old[field] != new[field]
                   or old['section_presence'][field] != new['section_presence'][field]]
        if changed:
            changed_routes.append(name)
            if name not in targets:
                errors.append({'unauthorized_net_route_or_feedthrough_change': name})
            changes.append({'net': name, 'fields': changed,
                'pin_count_before': sum(old['pins'].values()), 'pin_count_after': sum(new['pins'].values()),
                'route_edges_before': sum(old['route'].values()), 'route_edges_after': sum(new['route'].values()),
                'feedthroughs_before': counter_rows(old['feedthroughs']),
                'feedthroughs_after': counter_rows(new['feedthroughs'])})
    if set(changed_routes) != set(targets):
        errors.append({'expected_exactly_two_changed_target_routes': list(targets),
                       'actual_changed_routes': changed_routes})
    return {'result': 'PASS' if not errors else 'FAIL', 'errors': errors,
            'instances_before': len(before['instances']), 'instances_after': len(after['instances']),
            'nets_before': len(before['nets']), 'nets_after': len(after['nets']),
            'changed_instances': changed_instances, 'net_route_changes': changes,
            'target_pin_lists': target_pins,
            'export_timestamp_metadata': {'before': before['created'], 'after': after['created'],
                'policy': 'Only the recognized TD header creation timestamp is nonsemantic; raw hashes still bind it.'},
            'unknown_fields_policy': 'Preserved recursively and compared; unknown pin/route/feedthrough syntax fails closed.'}


def load_existing_gate():
    spec = importlib.util.spec_from_file_location('controls_existing_reset_gate', str(GATE))
    gate = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(gate)
    return gate


def existing_gate(after, baseline, gate):
    # A functional non-key data LUT is also rejected for this reset repair.
    report = gate.run_gate(str(after), str(baseline), strict_functional=True)
    checks = {}
    for item in report['checks']:
        if item['id'] in checks:
            raise ValueError('Duplicate existing-gate check '+item['id'])
        checks[item['id']] = item
    mandatory = ['RESET-01-DISCOVERY', 'RESET-02-KEY-LUT-PATH', 'RESET-03-BASELINE-DRIVER-AND-27-SR']
    if any(name not in checks for name in mandatory):
        raise ValueError('Existing gate omitted a required check')
    path_pass = all(checks[name]['status'] == 'PASS' for name in mandatory[:2])
    baseline_check = checks[mandatory[2]]
    if baseline_check['status'] not in ('PASS', 'FAIL'):
        raise ValueError('Baseline check may not be skipped or incomplete')
    return {'path_and_discovery_pass': path_pass, 'report': report,
            'historical_identity': {'exact_match': baseline_check['status'] == 'PASS',
                'check': baseline_check, 'semantic_review_required': baseline_check['status'] != 'PASS',
                'automatic_waiver': False}}


def self_test():
    def fixture(routes=('x1y1.a0,x1y1.f0;', 'x2y2.a0,x2y2.f0;'), extra=''):
        nets = []
        for name, route in zip(TARGETS+('third_net',), routes+('x3y3.a0,x3y3.f0;',)):
            nets.append('net '+name+'\n{\npin\n{\ni, q[0];\ni, sr;\n}\nfeedthroughs\n{\n}\nroute\n{\n'+route+'\n}\n'+extra+'\n}')
        return '// Copyright\n// Created by TD\n// Mon Oct 26 23:00:00 2026\nPnl Version: 2.0\ndesign d\n{\ninstance i\n{\nmodel lslice;\nattribute\n{\nLUT=1\n}\nlocation x1y1_0;\n}\n'+'\n'.join(nets)+'\n}'
    before = fixture()
    after = fixture(('x1y1.a1,x1y1.f1;', 'x2y2.a1,x2y2.f1;'))
    mutations = {'valid_two_routes': (after, True),
        'attribute_changed': (after.replace('LUT=1', 'LUT=2'), False),
        'pin_changed': (after.replace('i, sr;', 'i, d;'), False),
        'third_net_changed': (after.replace('x3y3.a0,x3y3.f0;', 'x3y3.a1,x3y3.f1;'), False),
        'unknown_field_added': (after.replace('location x1y1_0;', 'unknown danger;\nlocation x1y1_0;'), False),
        'unknown_net_field_added': (after.replace('net third_net\n{', 'net third_net\n{\nunknown danger;'), False),
        'target_unchanged': (before, False)}
    for name, (value, expected) in mutations.items():
        assert (compare(parse_pnl(before), parse_pnl(value))['result'] == 'PASS') == expected, name
        print('SELFTEST_PASS', name)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--before-pnl', type=Path, default=PHY/'controls_student.pnl')
    p.add_argument('--before-db', type=Path, default=PHY/'shengsheng_board_b_pr.db')
    p.add_argument('--after-pnl', type=Path, default=ROOT/'evidence/student_seed1_route_only/after.pnl')
    p.add_argument('--after-db', type=Path, default=ROOT/'evidence/student_seed1_route_only/after.db')
    p.add_argument('--baseline', type=Path, default=BASELINE,
                   help='Exact original historical baseline; replacement bytes are rejected')
    p.add_argument('--after-db-sha256', help='Optional caller-pinned full SHA of after DB content')
    p.add_argument('--out', type=Path, help='Receipt destination inside this candidate')
    p.add_argument('--self-test', action='store_true')
    args = p.parse_args()
    if args.self_test:
        self_test()
        return 0
    if not args.out:
        p.error('--out is required')
    out = args.out.resolve()
    if ROOT not in out.parents:
        p.error('--out must remain inside this candidate')
    receipt = {'schema': 'controls_student_two_net_route_only/v1',
               'recorded_local': datetime.datetime.now().isoformat(),
               'result': 'INCOMPLETE', 'bitgen': False, 'hardware': 'NOT_TESTED',
               'targets_exact_full_names': list(TARGETS), 'inputs': {},
               'limits': ['File hashes bind DB/PNL pairs; same-export provenance is separately required.',
                          'This does not waive historical net identity, prove STA, or authorize a bitstream.']}
    code = 2
    try:
        payloads = {}
        for name, path in [('before_pnl', args.before_pnl), ('before_db', args.before_db),
                           ('after_pnl', args.after_pnl), ('after_db', args.after_db),
                           ('baseline', args.baseline), ('existing_gate', GATE),
                           ('verifier', Path(__file__))]:
            receipt['inputs'][name], payloads[name] = file_info(path)
        if receipt['inputs']['before_db']['content_sha256'] != BEFORE_DB_SHA:
            raise ValueError('Before DB is not the certified Stage1 606EF84D database')
        if receipt['inputs']['before_pnl']['content_sha256'] != BEFORE_PNL_SHA:
            raise ValueError('Before PNL is not the certified Stage1 A05838F3 export')
        if receipt['inputs']['baseline']['content_sha256'] != HISTORICAL_BASELINE_SHA:
            raise ValueError('Historical baseline bytes changed; semantic review cannot replace the exact-identity check')
        if args.after_db_sha256 and receipt['inputs']['after_db']['content_sha256'] != args.after_db_sha256.upper():
            raise ValueError('After DB SHA differs from caller-pinned identity')
        before = parse_pnl(payloads['before_pnl'].decode('utf-8-sig', errors='strict'))
        after = parse_pnl(payloads['after_pnl'].decode('utf-8-sig', errors='strict'))
        gate = load_existing_gate()
        receipt['comparison'] = compare(before, after, output_port_bases=gate.OUTPUT_PORT_BASES)
        receipt['after_reset_gate'] = existing_gate(args.after_pnl, args.baseline, gate)
        for name, info in receipt['inputs'].items():
            if file_info(info['path'])[0]['sha256'] != info['sha256']:
                raise ValueError('Input changed during verification: '+name)
        if receipt['comparison']['result'] != 'PASS' or not receipt['after_reset_gate']['path_and_discovery_pass']:
            receipt['result'], code = 'FAIL', 1
        elif receipt['after_reset_gate']['historical_identity']['semantic_review_required']:
            receipt['result'], code = 'ROUTE_AND_PATH_PASS_SEMANTIC_REVIEW_REQUIRED', 2
        else:
            receipt['result'], code = 'PASS_ROUTE_PATH_AND_EXACT_HISTORICAL_IDENTITY', 0
    except FileNotFoundError as exc:
        receipt['error'] = str(exc)
    except Exception as exc:
        receipt['result'], receipt['error'], code = 'FAIL', str(exc), 1
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(receipt, ensure_ascii=False, indent=2), encoding='utf-8')
    print(receipt['result'], str(out))
    return code


if __name__ == '__main__':
    raise SystemExit(main())
