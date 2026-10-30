"""Verify sealed implementation materials, optionally unpack to a new work tree.

Python standard library only. Never starts TD, synthesis, routing or a programmer.
"""
import argparse
import gzip
import hashlib
import json
from pathlib import Path
import re
import sys

BASE = Path(__file__).resolve().parent
MANIFEST = BASE / 'materials.json'


def require(ok, message):
    if not ok:
        raise ValueError(message)


def digest(data):
    return hashlib.sha256(data).hexdigest().upper()


def below(root, relative):
    root = root.resolve()
    require(not Path(relative).is_absolute(), 'Absolute material path rejected')
    path = (root / relative).resolve()
    require(root in path.parents, 'Material path escaped its root: ' + relative)
    return path


def check_bytes(data, expected_bytes, expected_sha, label):
    require(re.fullmatch(r'[0-9A-F]{64}', expected_sha) is not None, 'Invalid SHA256: ' + label)
    require(len(data) == expected_bytes and digest(data) == expected_sha, 'Identity mismatch: ' + label)


def verify(manifest, source_workspace=None, extracted=False):
    records, payloads = [], []
    names, destinations = set(), set()
    for item in manifest['materials']:
        require(item['name'] not in names and item['extracted_path'] not in destinations,
                'Duplicate material name or extraction destination')
        names.add(item['name'])
        destinations.add(item['extracted_path'])
        if extracted:
            path = below(BASE / 'work', item['extracted_path'])
            raw = path.read_bytes()
        else:
            path = below(source_workspace, item['source_path']) if source_workspace else below(BASE, item['package_path'])
            packed = path.read_bytes()
            check_bytes(packed, item['bytes'], item['sha256'], str(path))
            require(item['encoding'] in ('gzip', 'raw'), 'Unknown material encoding')
            raw = gzip.decompress(packed) if item['encoding'] == 'gzip' else packed
        check_bytes(raw, item['raw_bytes'], item['raw_sha256'], item['name'] + ' / raw')
        records.append({'name': item['name'], 'path': str(path), 'raw_bytes': len(raw),
                        'raw_sha256': digest(raw)})
        payloads.append((item, raw))
    require(len(records) == 12, 'Expected seven Stage1, four route-only and one fuse material')
    return records, payloads


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--extract', action='store_true', help='Verify, then create a new ./work; refuses overwrite')
    parser.add_argument('--verify-extracted', action='store_true', help='Read-only rehash of all prepared ./work inputs')
    parser.add_argument('--source-workspace', type=Path, help='Packaging audit only: read original source_path files instead of packaged materials')
    parser.add_argument('--compare-fuse', type=Path, help='Read-only comparison of an exported fuse with the sealed original (exact bytes and 0/1 data)')
    args = parser.parse_args()
    try:
        require(not (args.extract and args.verify_extracted), 'Choose extract or verify-extracted')
        require(not (args.source_workspace and args.verify_extracted), 'Extracted verification uses ./work only')
        manifest = json.loads(MANIFEST.read_text(encoding='utf-8-sig'))
        require(manifest['schema'] == 'controls_student_portable_materials/v1', 'Unexpected manifest schema')
        selected_db_sha = 'A79315D9825A88CAE151739381D3A3AFFBA5E27379B783101B7E6AAB4FACACC9'
        selected = [item for item in manifest['materials']
                    if item['extracted_path'] == 'route_only/student_route_only_pr.db']
        require(manifest['candidate_db_sha256'] == selected_db_sha and len(selected) == 1 and
                selected[0]['raw_sha256'] == selected_db_sha, 'Only the selected A793 database is accepted')
        records, payloads = verify(manifest, args.source_workspace, args.verify_extracted)
        result = {'result': 'PASS_MATERIAL_IDENTITIES', 'materials': records,
                  'td_invoked': False, 'hardware_accessed': False}
        if args.extract:
            work = BASE / 'work'
            require(not work.exists(), 'Refusing to overwrite existing ./work')
            # Validate every destination before creating any files.
            destinations = [(below(work, item['extracted_path']), raw) for item, raw in payloads]
            work.mkdir(exist_ok=False)
            for path, raw in destinations:
                path.parent.mkdir(parents=True, exist_ok=True)
                with path.open('xb') as stream:
                    stream.write(raw)
            verify(manifest, extracted=True)
            (work / 'verified_materials.json').write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
            result['work'] = str(work)
        if args.compare_fuse:
            reference = next(raw for item, raw in payloads if item['name'] == 'original_student_fuse')
            candidate = args.compare_fuse.read_bytes()
            bit_data = []
            for label, data in (('reference', reference), ('candidate', candidate)):
                normalized = b''.join(data.split())
                require(normalized and set(normalized) <= {48, 49}, 'Non-binary fuse data: ' + label)
                bit_data.append(normalized)
            result['fuse_comparison'] = {'exact_bytes_equal': candidate == reference,
                'binary_data_equal': bit_data[0] == bit_data[1], 'reference_sha256': digest(reference),
                'candidate_sha256': digest(candidate), 'reference_bits': len(bit_data[0]),
                'candidate_bits': len(bit_data[1])}
            require(bit_data[0] == bit_data[1], 'Fuse configuration data differs from sealed original')
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 0
    except Exception as exc:
        print(json.dumps({'result': 'FAIL', 'error': str(exc), 'td_invoked': False}, ensure_ascii=False), file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
