"""Standalone package entry: check, test, teacher build, or sealed student export.

Windows, Python 3 and Tang Dynasty 6.2.168116. No programmer is invoked.
Product sources and supplied bitstreams are never overwritten.
"""
from pathlib import Path
import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent
WORK = ROOT / 'work'
TD = Path('C:/Anlogic/TD_6.2.1_Engineer_6.2.168.116/bin/td_commands_prompt.exe')
IV = Path('E:/Verilog/iverilog/bin/iverilog.exe')
STUDENT = '3BFB9883867FB6C69A715D842745E3B474EB3E545ACEE3A4226CDAA41248EDA6'
TEACHER = 'C9650B431325012498D52A917820F9C726D90FB49F02EF1E0FDEB924E536C4AF'


def require(ok, message):
    if not ok:
        raise RuntimeError(message)


def sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest().upper()


def save(path, data):
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')


def contained(root, rel):
    path = (root / rel).resolve()
    require(root.resolve() in path.parents, 'Path escapes package: ' + rel)
    return path


def check():
    manifest = json.loads((ROOT/'MANIFEST.json').read_text(encoding='utf-8'))
    for name, record in manifest['files'].items():
        p = contained(ROOT, name)
        require(p.is_file() and p.stat().st_size == record['bytes'] and sha(p) == record['sha256'],
                'Package file missing or changed: ' + name)
    require(len(manifest['authenticated_build_inputs']) == 163, 'Build input inventory mismatch')
    for name, expected in manifest['authenticated_build_inputs'].items():
        require(sha(contained(ROOT, name)) == expected, 'Product input changed: ' + name)
    bits = {sha(p) for p in (ROOT/'02_bitstreams').glob('*.bit')}
    require(bits == {STUDENT, TEACHER}, 'Supplied bitstream identity mismatch')
    print('PACKAGE_CHECK_PASS inputs=163', flush=True)
    return manifest


def environment():
    env = dict(os.environ)
    env['PATH'] = str(Path(sys.executable).parent) + os.pathsep + env.get('PATH', '')
    for name in ('TD_RUN_DIR', 'TD_PLACE_SEED', 'TD_KEEP_DR_HOLDFIX'):
        env.pop(name, None)
    # PowerShell 7 can export its module search path to Python. Windows
    # PowerShell must reconstruct its own module path for Get-FileHash, etc.
    env.pop('PSModulePath', None)
    return env


def run(command, cwd, log, marker=None, timeout=2400):
    started = time.monotonic()
    with log.open('wb') as stream:
        r = subprocess.run([p.as_posix() if isinstance(p, Path) else str(p) for p in command],
                           cwd=cwd, env=environment(), stdout=stream,
                           stderr=subprocess.STDOUT, timeout=timeout)
    text = log.read_text(encoding='utf-8', errors='replace')
    require(r.returncode == 0, 'Command failed; see ' + str(log))
    if marker:
        require(marker in text, 'Native completion marker missing; see ' + str(log))
    return {'exit_code': r.returncode, 'seconds': round(time.monotonic()-started, 2),
            'log': str(log.relative_to(ROOT)), 'log_sha256': sha(log)}


def reserve(name):
    dest = contained(WORK, name)
    require(not dest.exists(), 'Output already exists; use a fresh extraction: ' + str(dest))
    WORK.mkdir(exist_ok=True)
    dest.mkdir()
    return dest


def idle():
    require(os.name == 'nt', 'TD build entries require Windows')
    command = "@(Get-Process -Name td_commands_prompt,bw_commands_prompt -ErrorAction SilentlyContinue).Count"
    r = subprocess.run(['powershell.exe', '-NoProfile', '-NonInteractive', '-Command', command],
                       capture_output=True, text=True, check=True)
    require(r.stdout.strip() == '0', 'Another TD/programmer process is active; finish it before starting this build')


def teacher():
    require(TD.is_file(), 'Install TD 6.2.168116 at: ' + str(TD))
    require(Path('C:/Windows/Fonts/Dengb.ttf').is_file(), 'Canonical teacher gate requires Dengb.ttf')
    idle()
    out = reserve('teacher')
    run(['powershell.exe','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass',
         '-File',ROOT/'BUILD_TEACHER.ps1','-CheckOnly'],ROOT,out/'bootstrap.log','POWERSHELL_BUILD_BOOTSTRAP_PASS')
    project = out/'teacher_A'
    shutil.copytree(ROOT/'01_source/teacher_A', project)
    receipt = {'action': 'teacher', 'status': 'RUNNING', 'place_seed': 1,
               'hardware_accessed': False, 'source': '01_source/teacher_A'}
    save(out/'result.json', receipt)
    try:
        print('TEACHER_FULL_BUILD_START', flush=True)
        receipt['command'] = run(['powershell.exe', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
                                  '-File', ROOT/'BUILD_TEACHER.ps1', '-ProjectRoot', project],
                                 project, out/'build_console.log', 'TD_SHENGSHENG_A_WRAPPER_PASS')
        built = project/'board_a/output'
        canonical = json.loads((built/'shengsheng_board_a_build_receipt.json').read_text(encoding='utf-8-sig'))
        require(canonical['gate_version'] == 7 and canonical['timing']['violation_report_verified'], 'Canonical gate missing')
        require(canonical['place_seed'] == 1, 'Place seed changed')
        receipt.update(status='PASS', bit_sha256=sha(built/'shengsheng_board_a.bit'),
                       timing=canonical['timing'], tmds_delays_ns=canonical['tmds_reported_endpoint_delays_ns'])
        receipt['bit_byte_identical_to_supplied'] = receipt['bit_sha256'] == TEACHER
        check()
        print('TEACHER_FULL_BUILD_PASS', flush=True)
    except Exception as exc:
        receipt.update(status='FAIL', error=str(exc))
        raise
    finally:
        save(out/'result.json', receipt)


def student():
    require(TD.is_file(), 'Install TD 6.2.168116 at: ' + str(TD))
    idle()
    out = reserve('student')
    impl = out/'student_impl'
    # Only the portable database export path is used. The archived historical
    # source/re-route workflows are never silently substituted for this path.
    shutil.copytree(ROOT/'05_build_support/student_impl', impl,
                    ignore=shutil.ignore_patterns('archive_recipes'))
    receipt = {'action':'student','status':'RUNNING','hardware_accessed':False,
               'mode':'sealed_database_export_no_synthesis_or_reroute'}
    save(out/'result.json', receipt)
    try:
        print('STUDENT_SEALED_EXPORT_START', flush=True)
        run([sys.executable, '-B', 'prepare_impl.py', '--extract'], impl, out/'prepare.log', 'PASS_MATERIAL_IDENTITIES')
        receipt['command'] = run([TD, impl/'export_student_db.tcl'], impl, out/'export_console.log',
                                 'CONTROLS_STUDENT_PORTABLE_EXPORT_COMPLETE=1')
        exported = impl/'work/export'
        run([sys.executable, '-B', 'prepare_impl.py', '--compare-fuse', exported/'student.fuse'],
             impl, out/'compare_fuse.json', 'PASS_MATERIAL_IDENTITIES')
        comparison = json.loads((out/'compare_fuse.json').read_text(encoding='utf-8'))['fuse_comparison']
        require(comparison['binary_data_equal'], 'Exported configuration differs from supplied implementation')
        receipt.update(status='PASS', bit_sha256=sha(exported/'shengsheng_board_b.bit'), fuse_comparison=comparison)
        receipt['bit_byte_identical_to_supplied'] = receipt['bit_sha256'] == STUDENT
        check()
        print('STUDENT_SEALED_EXPORT_PASS', flush=True)
    except Exception as exc:
        receipt.update(status='FAIL', error=str(exc))
        raise
    finally:
        save(out/'result.json', receipt)


def tests(iverilog):
    require(iverilog.is_file() and iverilog.with_name('vvp.exe').is_file(), 'Icarus Verilog tools missing')
    out = reserve('tests')
    a = ROOT/'01_source/teacher_A/board_a/src'
    b = ROOT/'01_source/student_B/board_b/src'
    # All seven benches and HEX inputs are supplied; no historical negative
    # controls or package-external RTL references are used by this entry.
    cases = [
        ('manual_start','tb_train_manual_start', [], 'TRAIN_MANUAL_START_PASS'),
        ('legacy_game','tb_child_game_v7', [], 'CHILD_GAME_V7_PASS'),
        ('single_mic_game','tb_single_mic_game',['tone_scorer.v'],'SINGLE_MIC_GAME_PASS'),
        ('teacher_demo','tb_game_teacher',[],'SS_GAME_TEACHER_PASS'),
        ('summary','tb_game_summary',[],'SS_SUM_PASS'),
        ('physical_keys','tb_child_completed_questions_v7',['dual_key_chord_router.v','dual_key_long_hold_guard.v'],'CHILD_COMPLETED_V7_PASS')]
    results=[]
    for name,top,extra,marker in cases:
        srcs=[ROOT/'01_source/student_B/sim'/(top+'.v'),b/'shengsheng_game.v']+[b/n for n in extra]
        binary=out/(name+'.vvp')
        run([iverilog,'-g2012','-Wall','-I',b,'-s',top,'-o',binary,*srcs],ROOT/'01_source/student_B',out/(name+'_compile.log'))
        results.append(run([iverilog.with_name('vvp.exe'),binary],ROOT/'01_source/student_B',out/(name+'.log'),marker,180))
        print(name+'=PASS',flush=True)
    binary=out/'teacher_cards.vvp'
    srcs=[a/n for n in ('teacher_console.v','console_text_rom.v','video_timing_ctrl.v','v7_link_a.v',
                       'v7_packet_tx.v','v7_packet_rx.v','uart_tx_byte.v','uart_rx_byte.v')]
    run([iverilog,'-g2012','-I',a,'-s','tb_console_cards','-o',binary,*srcs,ROOT/'01_source/teacher_A/sim/tb_console_cards.v'],
        ROOT/'01_source/teacher_A',out/'teacher_cards_compile.log')
    results.append(run([iverilog.with_name('vvp.exe'),binary],ROOT/'01_source/teacher_A',out/'teacher_cards.log','CONSOLE_CARDS_PASS',180))
    save(out/'result.json',{'status':'PASS','cases':7,'commands':results,'hardware_accessed':False})
    check()
    print('PACKAGE_TESTS_PASS cases=7',flush=True)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action',choices=['check','test','teacher','student','all'])
    parser.add_argument('--iverilog',type=Path,default=IV,help='Icarus executable path, for test only')
    args=parser.parse_args()
    check()
    if args.action=='teacher': teacher()
    elif args.action=='student': student()
    elif args.action=='test': tests(args.iverilog)
    elif args.action=='all':
        teacher()
        student()


if __name__=='__main__':
    try:
        main()
    except Exception as exc:
        print('BUILD_FAILED: '+str(exc),file=sys.stderr)
        raise SystemExit(1)
