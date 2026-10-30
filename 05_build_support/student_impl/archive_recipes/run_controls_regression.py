"""Run canonical single-mic regressions against the two isolated candidate roots.

No TD, programmer, baseline writes, or source-generation commands are used.
Fixtures live only in sim_regression. Per-case receipts identify actual inputs.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
A = ROOT / 'teacher_A/board_a/src'
B = ROOT / 'student_B/board_b/src'
SIM = ROOT / 'sim_regression'
IV = Path('E:/Verilog/iverilog/bin/iverilog.exe')
VVP = Path('E:/Verilog/iverilog/bin/vvp.exe')
LINK = [A / (name + '.v') for name in
        ('v7_packet_rx', 'v7_packet_tx', 'uart_rx_byte', 'uart_tx_byte', 'v7_link_a')]
LINK += [B / 'v7_link_b.v']

CASES = {
    'control': ('tb_single_mic_control', [A/'single_mic_control.v', A/'console_scope_v8.v'], 'SINGLE_MIC_CONTROL_PASS'),
    'result_packer': ('tb_result_packer_serial', LINK, 'RESULT_PACKER_SERIAL_PASS'),
    'protocol_codec': ('tb_v7_codec', LINK, 'V7_CODEC_PASS'),
    'protocol_link': ('tb_v7_link', LINK, 'V7_LINK_PASS'),
    'protocol_boundaries': ('tb_v7_boundaries', LINK, 'V7_BOUNDARIES_PASS'),
    'legacy_game': ('tb_child_game_v7', [B/'shengsheng_game.v'], 'CHILD_GAME_V7_PASS'),
    'legacy_teacher': ('tb_game_teacher', [B/'shengsheng_game.v'], 'SS_GAME_TEACHER_PASS'),
    'legacy_summary': ('tb_game_summary', [B/'shengsheng_game.v'], 'SS_SUM_PASS'),
    'legacy_console': ('tb_console_v7', [A/'teacher_console.v', A/'console_text_rom.v', A/'video_timing_ctrl.v'], 'CONSOLE_V7_PASS'),
    'legacy_scope': ('tb_console_scope_v8', [A/'console_scope_v8.v', A/'goertzel_8band.v'], 'CONSOLE_SCOPE_V8_PASS'),
    'game': ('tb_single_mic_game', [B/'shengsheng_game.v', B/'tone_scorer.v'], 'SINGLE_MIC_GAME_PASS'),
    'protocol': ('tb_single_mic_link', LINK, 'SINGLE_MIC_LINK_PASS'),
    'scope': ('tb_single_mic_scope', [A/'console_scope_v8.v'], 'SINGLE_MIC_SCOPE_PASS'),
}
CASES['top'] = ('tb_single_mic_top',
    [B/'v7_link_b.v', SIM/'models/adc_multichannel_v7.v',
     SIM/'models/hdmi_stubs.v', SIM/'models/sys_pll_stub.v'] +
    [p for p in sorted(A.glob('*.v')) if not re.search(
        r'\.enc\.v$|^(sys_pll_promax_40|hdmi_phy_warpper|lane_lvds_10_1)\.v$', p.name)],
    'SINGLE_MIC_TOP_PASS')
CASES['legacy_b_top'] = ('tb_board_b_controls_v7',
    [SIM/'models/shengsheng_top_stubs.v'] +
    [p for p in sorted(B.glob('*.v')) if not re.search(
        r'\.enc\.v$|^(sdram|sys_pll_promax_40|hdmi_phy_warpper|lane_lvds_10_1)\.v$', p.name)],
    'BOARD_B_CONTROLS_V7_PASS')


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest().upper()


def source_snapshot(sources):
    dependencies = set(sources)
    queue = list(sources)
    while queue:
        source = queue.pop()
        for name in re.findall(r'`include\s+"([^"]+)"', source.read_text(encoding='utf-8')):
            options = [source.parent/name, A/name, B/name, SIM/name]
            include = next((p.resolve() for p in options if p.is_file()), None)
            if include is None:
                raise FileNotFoundError('Missing include %s from %s' % (name, source))
            if include not in dependencies:
                dependencies.add(include)
                queue.append(include)
    return {str(p.relative_to(ROOT)): sha(p) for p in sorted(dependencies)}


def run_case(name, output):
    top, design_sources, marker = CASES[name]
    sources = [(SIM/(top+'.v')).resolve()] + [p.resolve() for p in design_sources]
    receipt = {'case': name, 'started': time.time(), 'hardware': 'NOT_TESTED',
               'status': 'running', 'runner_sha256': sha(Path(__file__).resolve()),
               'source_roots': {'teacher': str(A), 'student': str(B)}}
    receipt_path = output/(name+'.json')
    try:
        runtime_tables = [A/'hann_w260.hex', B/'classifier_lut.hex']
        before = source_snapshot(sources+runtime_tables)
        receipt['sources'] = before
        binary = output/(name+'.vvp')
        cmd = [str(IV), '-g2012', '-Wall', '-I', str(A), '-I', str(B),
               '-I', str(SIM), '-s', top, '-o', str(binary)] + [str(p) for p in sources]
        receipt['compile_command'] = cmd
        compiled = subprocess.run(cmd, cwd=str(ROOT), capture_output=True,
                                  text=True, timeout=120)
        (output/(name+'_compile.log')).write_text(compiled.stdout+compiled.stderr,
                                                 encoding='utf-8')
        if compiled.returncode:
            raise RuntimeError('Compile failed: '+compiled.stderr[-3000:])
        simulation_cwd = B if name in ('game', 'legacy_game', 'legacy_teacher', 'legacy_summary', 'legacy_b_top') else A
        receipt['simulation_cwd'] = str(simulation_cwd)
        with (output/(name+'.log')).open('w', encoding='utf-8') as log:
            ran = subprocess.run([str(VVP), str(binary)], cwd=str(simulation_cwd), stdout=log,
                                 stderr=subprocess.STDOUT,
                                 timeout=3600 if name == 'top' else 1200)
        log = (output/(name+'.log')).read_text(encoding='utf-8')
        if ran.returncode or not re.search(r'^'+re.escape(marker)+r'\b', log, re.M) or re.search(r'FATAL:|^ERROR\b|_FAIL\b', log, re.M):
            raise RuntimeError('Simulation failed: '+log[-3000:])
        if before != source_snapshot(sources+runtime_tables):
            raise RuntimeError('Input changed during test; result rejected')
        receipt.update(status='passed', marker=marker, binary_sha256=sha(binary),
                       log_sha256=sha(output/(name+'.log')))
        print(name+': '+marker, flush=True)
    except Exception as exc:
        receipt.update(status='failed', error=str(exc))
        print(name+': FAIL '+str(exc), flush=True)
    finally:
        receipt['completed'] = time.time()
        receipt_path.write_text(json.dumps(receipt, ensure_ascii=False, indent=2), encoding='utf-8')
    return receipt['status'] == 'passed'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('cases', nargs='*', metavar='CASE')
    parser.add_argument('--all', action='store_true', help='run all 15 canonical cases')
    parser.add_argument('--list', action='store_true')
    parser.add_argument('--keep-going', action='store_true')
    parser.add_argument('--out', default='evidence/regression_canonical')
    args = parser.parse_args()
    unknown = [name for name in args.cases if name not in CASES]
    if unknown:
        parser.error('Unknown case(s): '+', '.join(unknown))
    if args.list:
        print('\n'.join(CASES))
        return 0
    selected = list(CASES) if args.all else args.cases
    if not selected:
        parser.error('Select cases or --all; --list prints available cases')
    output = (ROOT/args.out).resolve()
    if ROOT not in output.parents:
        parser.error('--out must remain inside the isolated candidate')
    output.mkdir(parents=True, exist_ok=True)
    for role in ('student_B', 'teacher_A'):
        checked = subprocess.run([sys.executable, str(ROOT/role/'tools/generate_contracts.py'), '--check'],
                                 cwd=str(ROOT/role), capture_output=True, text=True)
        print(role+': '+checked.stdout.strip()+checked.stderr.strip(), flush=True)
        if checked.returncode:
            return checked.returncode
    ok = True
    for name in selected:
        passed = run_case(name, output)
        ok = ok and passed
        if not passed and not args.keep_going:
            break
    print('CONTROLS_R1_REGRESSION_'+('PASS' if ok else 'FAIL'), flush=True)
    return 0 if ok else 1


if __name__ == '__main__':
    raise SystemExit(main())
