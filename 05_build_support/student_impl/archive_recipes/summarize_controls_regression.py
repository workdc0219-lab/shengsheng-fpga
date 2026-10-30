"""Summarize only receipts whose complete input set still matches the candidate."""
import datetime
import json
from pathlib import Path
import run_controls_regression as run


def main():
    roots = [run.ROOT/'evidence/regression_canonical',
             run.ROOT/'evidence/regression_adapted_control']
    result = {'schema': 'controls_r1_canonical_regression_summary/v1',
              'recorded_local': datetime.datetime.now().isoformat(),
              'hardware': 'NOT_TESTED', 'physical_build': 'NOT_RUN_BY_THIS_REVIEW',
              'required_cases': len(run.CASES), 'cases': {},
              'original_control_red_ab': 'evidence/regression_control_ab/control_original_red_ab.json'}
    for name, (top, design, marker) in run.CASES.items():
        try:
            current = run.source_snapshot(
                [(run.SIM/(top+'.v')).resolve()] + [p.resolve() for p in design] +
                [run.A/'hann_w260.hex', run.B/'classifier_lut.hex'])
            history = []
            for root in roots:
                path = root/(name+'.json')
                if path.is_file():
                    receipt = json.loads(path.read_text(encoding='utf-8'))
                    history.append((path, receipt))
            matching = [(p, r) for p, r in history if r.get('sources') == current]
            if matching:
                path, receipt = max(matching, key=lambda pair: pair[1].get('completed', 0))
                result['cases'][name] = {'status': receipt['status'],
                    'receipt': str(path.relative_to(run.ROOT)),
                    'receipt_sha256': run.sha(path), 'input_files': len(current),
                    'current_inputs_match': True, 'marker': receipt.get('marker'),
                    'error': receipt.get('error')}
            else:
                result['cases'][name] = {'status': 'stale' if history else 'pending',
                    'current_inputs_match': False, 'input_files': len(current),
                    'old_receipts': [str(p.relative_to(run.ROOT)) for p, r in history]}
        except Exception as exc:
            result['cases'][name] = {'status': 'invalid_inputs', 'error': str(exc)}
    result['counts'] = {status: sum(r['status'] == status for r in result['cases'].values())
                        for status in ('passed', 'failed', 'pending', 'stale', 'invalid_inputs')}
    result['result'] = 'PASS' if result['counts']['passed'] == len(run.CASES) else 'INCOMPLETE_OR_FAILED'
    out = run.ROOT/'evidence/regression_summary_20261026.json'
    out.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding='utf-8')
    print(result['result'], result['counts'], str(out))
    return 0 if result['result'] == 'PASS' else 1


if __name__ == '__main__':
    raise SystemExit(main())
