"""Run the manual-start discriminator and selected existing RTL regressions.

This is not the full canonical single-mic runner and never starts TD/hardware.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import subprocess
import sys


STUDENT = Path(__file__).resolve().parents[1]
CANDIDATE = STUDENT.parent
WORKSPACE = CANDIDATE.parent
SRC = STUDENT / 'board_b/src'
BASE = WORKSPACE / '2026_topic1_shengsheng_sm_f1_audioreg/board_b/src/shengsheng_game.v'
EVIDENCE = CANDIDATE / 'evidence'
CACHE = STUDENT / '.sim_cache' / 'train_checks'
IVERILOG = Path('E:/Verilog/iverilog/bin/iverilog.exe')
VVP = Path('E:/Verilog/iverilog/bin/vvp.exe')
CASES = {
    'manual_candidate': ('tb_train_manual_start', [], 'TRAIN_MANUAL_START_PASS', False),
    'manual_base_red': ('tb_train_manual_start', [], 'TRAIN_STANDBY_MOVED', True),
    'legacy_game': ('tb_child_game_v7', [], 'CHILD_GAME_V7_PASS', False),
    'single_mic_game': ('tb_single_mic_game', ['tone_scorer.v'], 'SINGLE_MIC_GAME_PASS', False),
    'teacher_demo': ('tb_game_teacher', [], 'SS_GAME_TEACHER_PASS', False),
    'summary': ('tb_game_summary', [], 'SS_SUM_PASS', False),
    'physical_keys': ('tb_child_completed_questions_v7',
                      ['dual_key_chord_router.v', 'dual_key_long_hold_guard.v'],
                      'CHILD_COMPLETED_V7_PASS', False),
}


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest().upper()


def run_case(name):
    top, extra, marker, expect_failure = CASES[name]
    bench = STUDENT / 'sim' / (top + '.v')
    game = BASE if expect_failure else SRC / 'shengsheng_game.v'
    sources = [bench, game] + [SRC / item for item in extra]
    input_hashes = {str(p.relative_to(WORKSPACE)).replace('\\', '/'): sha(p) for p in sources + [SRC / 'ss_phrases.vh']}
    binary = CACHE / (name + '.vvp')
    compile_command = [str(IVERILOG), '-g2012', '-Wall', '-I', str(SRC), '-s', top,
                       '-o', str(binary)] + [str(p) for p in sources]
    compiled = subprocess.run(compile_command, cwd=str(STUDENT), stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT, timeout=60)
    runtime = None
    if compiled.returncode == 0:
        runtime = subprocess.run([str(VVP), str(binary)], cwd=str(STUDENT), stdout=subprocess.PIPE,
                                 stderr=subprocess.STDOUT, timeout=180)
    output = (compiled.stdout + (runtime.stdout if runtime else b'')).decode('utf-8', errors='replace')
    passed = (compiled.returncode == 0 and runtime is not None and marker in output and
              ((runtime.returncode != 0) if expect_failure else (runtime.returncode == 0)))
    log = EVIDENCE / ('train_' + name + '.log')
    log.write_text('COMPILE_COMMAND=' + json.dumps(compile_command) + '\n' +
                   'COMPILE_EXIT=' + str(compiled.returncode) + '\n' +
                   'RUNTIME_EXIT=' + str(runtime.returncode if runtime else None) + '\n' + output,
                   encoding='utf-8')
    result = {'result': 'PASS' if passed else 'FAIL', 'top': top,
              'compile_exit': compiled.returncode, 'runtime_exit': runtime.returncode if runtime else None,
              'expected_failure': expect_failure, 'required_marker': marker,
              'input_sha256': input_hashes, 'log': log.relative_to(CANDIDATE).as_posix(),
              'log_sha256': sha(log)}
    print(name + '=' + result['result'])
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('cases', nargs='*', metavar='CASE',
                        help='Optional cases: ' + ', '.join(CASES))
    args = parser.parse_args()
    unknown = sorted(set(args.cases) - set(CASES))
    if unknown:
        parser.error('unknown case(s): ' + ', '.join(unknown))
    EVIDENCE.mkdir(exist_ok=True)
    CACHE.mkdir(parents=True, exist_ok=True)
    receipt_path = EVIDENCE / 'train_checks_20261026.json'
    selected = list(args.cases or CASES)
    results = {}
    if receipt_path.exists():
        previous = json.loads(receipt_path.read_text(encoding='utf-8'))
        for name, result in previous.get('cases', {}).items():
            if name in selected or name not in CASES or result['result'] != 'PASS':
                continue
            inputs_match = all((WORKSPACE / relative).is_file() and sha(WORKSPACE / relative) == expected
                               for relative, expected in result['input_sha256'].items())
            log = CANDIDATE / result['log']
            log_matches = log.is_file() and sha(log) == result['log_sha256']
            if inputs_match and log_matches and result['required_marker'] == CASES[name][2]:
                results[name] = result
    retained = list(results)
    results.update({name: run_case(name) for name in selected})
    receipt = {
        'schema': 'train_manual_start_selected_rtl_checks/v1',
        'completed_at_utc': datetime.now(timezone.utc).isoformat(),
        'scope': 'Six selected candidate RTL simulations plus a baseline-failing discriminator; not the full canonical 15-case runner.',
        'td_or_board_operations': False,
        'tools': {'iverilog': str(IVERILOG), 'vvp': str(VVP)},
        'cases_run_this_invocation': selected,
        'cases_retained_with_matching_inputs_and_logs': retained,
        'selected_suite_complete': set(results) == set(CASES),
        'cases': results,
        'result': 'PASS' if all(item['result'] == 'PASS' for item in results.values()) else 'FAIL',
    }
    receipt_path.write_text(json.dumps(receipt, indent=2) + '\n', encoding='utf-8')
    sys.exit(0 if receipt['result'] == 'PASS' else 1)


if __name__ == '__main__':
    main()
