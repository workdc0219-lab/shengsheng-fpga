"""Run candidate word-label and ROM checks; no TD or board operations.

The immutable Q6 renderer supplies independent literal-word pixel expectations.
The unmodified Q6 console must fail the same behavioral test. Output binaries
are kept in a unique E: cache; evidence stays in candidate/evidence/card_*.
"""
from pathlib import Path
from hashlib import sha256
from datetime import datetime
import importlib.util
import json
import re
import subprocess
import sys
import uuid

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
WORKSPACE = ROOT.parents[1]
BASE = WORKSPACE / '2026_topic1_shengsheng_wave_q6'
SRC = ROOT / 'board_a/src'
EVIDENCE = ROOT.parent / 'evidence'
IVERILOG = Path('E:/Verilog/iverilog/bin/iverilog.exe')
VVP = IVERILOG.with_name('vvp.exe')
CARDS = [('CARD_MAO', 'māo 猫'), ('CARD_YU', 'yú 鱼'),
         ('CARD_GOU', 'gǒu 狗'), ('CARD_TU', 'tù 兔')]
SHORTENED = {'CUE_DEMO': '请示范', 'CMP': '归一化对比',
             'DEMO_ON': '真人', 'DEMO_OFF': '合成', 'NONE': '待首题'}


def digest(path):
    return sha256(Path(path).read_bytes()).hexdigest().upper()


def load_renderer(path):
    spec = importlib.util.spec_from_file_location('immutable_q6_font_renderer', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def decode(path):
    vh = (path / 'console_phrases.vh').read_text(encoding='ascii')
    ids = {n: int(i) for n, i in re.findall(r'CP_(\w+) = 6\'d(\d+);', vh)}
    descs = {int(i): tuple(map(int, (b, s, w))) for i, b, s, w in re.findall(
        r"6'd(\d+): cphrase = \{14'd(\d+), 6'd(\d+), 9'd(\d+)\};", vh)}
    text = (path / 'console_text_rom.v').read_text(encoding='ascii')
    assert 'rom [0:16383]' in text and 'input  wire [13:0] addr' in text
    rom = [0] * 16384
    for address, value in re.findall(r"rom\[(\d+)\] = 8'h([0-9a-fA-F]+);", text):
        rom[int(address)] = int(value, 16)
    return ids, descs, rom


def bitmap(desc, rom):
    base, stride, width = desc
    return [[(rom[base + y * stride + (x >> 2)] >> (6 - 2 * (x & 3))) & 3
             for x in range(width)] for y in range(20)]


def reference_bitmap(rows, width):
    return [[(rows[y][x >> 2] >> (6 - 2 * (x & 3))) & 3
             for x in range(width)] for y in range(20)]


def main():
    EVIDENCE.mkdir(exist_ok=True)
    renderer = load_renderer(BASE / 'tools/make_console_rom.py')
    ids, descs, rom = decode(SRC)
    old_ids, old_descs, old_rom = decode(BASE / 'board_a/src')
    assert all(ids[name] == value for name, value in old_ids.items())
    assert len(ids) == 57 and sorted(ids.values()) == list(range(57))
    assert all(ids[name] == 53 + q for q, (name, _) in enumerate(CARDS))
    used = max(b + stride * 20 for b, stride, width in descs.values())
    assert used == 16320 and used <= len(rom)
    preserved = []
    for name, ident in old_ids.items():
        if name not in SHORTENED:
            assert bitmap(descs[ident], rom) == bitmap(old_descs[ident], old_rom), name
            preserved.append(name)
    for name, text in SHORTENED.items():
        width, rows = renderer.render(text, renderer.SIZE, None)
        assert bitmap(descs[ids[name]], rom) == reference_bitmap(rows, width), name
    expected = []
    card_details = []
    for q, (name, text) in enumerate(CARDS):
        width, rows = renderer.render(text, renderer.SIZE, None)
        actual = bitmap(descs[ids[name]], rom)
        assert actual == reference_bitmap(rows, width), name
        # Test the Chinese portion as well as the Latin/diacritic portion.
        assert any(actual[y][x] for y in range(20) for x in range(width - 20, width))
        expected.extend(byte for row in rows for byte in row)
        card_details.append({'q': q, 'id': ids[name], 'text': text, 'width': width,
                             'stride': len(rows[0]), 'bytes': sum(map(len, rows)),
                             'pixel_oracle': 'immutable Q6 render(), explicit requested full word'})
    assert len(expected) == 1160
    oracle = ROOT / 'sim/card_expected_glyphs.hex'
    oracle.write_text(''.join(f'{b:02x}\n' for b in expected), encoding='ascii')

    cache_root = (ROOT / '.sim_cache').resolve()
    build = cache_root / ('controls_card_teacher_' + uuid.uuid4().hex)
    assert build.parent == cache_root and not build.exists()
    build.mkdir(parents=True)
    extra = [SRC / n for n in ('console_text_rom.v', 'video_timing_ctrl.v',
                              'v7_link_a.v', 'v7_packet_tx.v', 'v7_packet_rx.v',
                              'uart_tx_byte.v', 'uart_rx_byte.v')]
    tests = {}

    def run(name, console, testbench, must_fail=False, expected_failure=None):
        binary = build / (name + '.vvp')
        compile_cmd = [str(IVERILOG), '-g2012', '-I', str(SRC), '-s',
                       testbench.stem, '-o', str(binary), str(console),
                       *map(str, extra), str(testbench)]
        compiled = subprocess.run(compile_cmd, cwd=ROOT, capture_output=True, text=True)
        if compiled.returncode != 0:
            raise RuntimeError(compiled.stdout + compiled.stderr)
        executed = subprocess.run([str(VVP), str(binary)], cwd=ROOT,
                                  capture_output=True, text=True, timeout=90)
        log = EVIDENCE / ('card_' + name + '.log')
        log.write_text('COMPILE\n' + compiled.stdout + compiled.stderr +
                       '\nSIMULATION\n' + executed.stdout + executed.stderr,
                       encoding='utf-8')
        if must_fail:
            assert executed.returncode != 0 and expected_failure in executed.stdout, executed.stdout
        else:
            assert executed.returncode == 0, executed.stdout
        tests[name] = {'result': 'EXPECTED_FAIL' if must_fail else 'PASS',
                       'compile_command': compile_cmd, 'exit_code': executed.returncode,
                       'log': str(log.relative_to(ROOT.parent)), 'log_sha256': digest(log),
                       'output': executed.stdout.strip()}

    cards_tb = ROOT / 'sim/tb_console_cards.v'
    run('teacher_cards', SRC / 'teacher_console.v', cards_tb)
    run('original_q6_negative', BASE / 'board_a/src/teacher_console.v', cards_tb,
        must_fail=True, expected_failure='CARD_HEADER_ID')
    run('teacher_existing_console', SRC / 'teacher_console.v', BASE / 'sim/tb_console_v7.v')
    files = [SRC / 'teacher_console.v', ROOT / 'tools/make_console_rom.py',
             SRC / 'console_phrases.vh', SRC / 'console_text_rom.v',
             ROOT / 'sim/card_console_phrases.png', cards_tb, oracle,
             Path(__file__).resolve()]
    result = {
        'schema': 'controls_r1_teacher_cards/v1',
        'generated_at': datetime.now().astimezone().isoformat(timespec='seconds'),
        'status': 'SOURCE_AND_SIMULATION_PASS_NOT_BOARD_TESTED',
        'rom': {'bytes_used': used, 'depth': len(rom), 'spare_bytes': len(rom)-used,
                'font_rows': 20, 'bpp': 2, 'ids': len(ids),
                'existing_ids_0_to_52_unchanged': True,
                'unchanged_old_bitmap_phrases': len(preserved),
                'storage_error_read_write_count_cap_preserved': True},
        'full_card_words': card_details, 'concise_labels': SHORTENED,
        'tests': tests, 'build_cache': str(build),
        'original_q6_console_sha256': digest(BASE / 'board_a/src/teacher_console.v'),
        'font_sha256': digest(renderer.FONT),
        'files': {str(p.relative_to(ROOT)): {'sha256': digest(p), 'bytes': p.stat().st_size}
                  for p in files},
        'limits': 'No TD synthesis/place/route, no new bitstream, no programmer or board operation. The existing v7 protocol, scorer and Q6 source are unchanged.',
    }
    target = EVIDENCE / 'card_teacher_regression.json'
    target.write_text(json.dumps(result, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
    print(json.dumps({'result': 'PASS', 'rom_used': used, 'rom_depth': len(rom),
                      'full_card_words': card_details, 'tests': {k:v['result'] for k,v in tests.items()},
                      'evidence': str(target)}, ensure_ascii=False))


if __name__ == '__main__':
    main()
