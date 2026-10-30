"""Save exact routed DB/PNL/Verilog bytes, with an independently readable manifest."""
import argparse
import gzip
import hashlib
import json
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("directory", choices=("student_seed1_route_only", "student_seed1_no_lut_bridge"))
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
source_root = root / "evidence" / args.directory
out = source_root / "archive"
out.mkdir(exist_ok=True)
records = []
for name in ("before.pnl", "after.pnl", "after.v", "student_route_only_pr.db"):
    source = source_root / name
    raw = source.read_bytes()
    destination = out / (name + ".gz")
    if destination.exists():
        assert gzip.decompress(destination.read_bytes()) == raw
    else:
        destination.write_bytes(gzip.compress(raw, compresslevel=6, mtime=0))
    packed = destination.read_bytes()
    assert gzip.decompress(packed) == raw
    records.append({"source": source.relative_to(root).as_posix(), "bytes": len(raw),
                    "sha256": hashlib.sha256(raw).hexdigest().upper(),
                    "archive": destination.relative_to(root).as_posix(),
                    "archive_bytes": len(packed),
                    "archive_sha256": hashlib.sha256(packed).hexdigest().upper()})
(out / "manifest.json").write_text(json.dumps({"schema": "controls_routed_archive/v1",
    "bitgen": False, "hardware": "NOT_TESTED", "files": records}, indent=2) + "\n", encoding="utf-8")
print(json.dumps({"files": len(records), "archive_bytes": sum(r["archive_bytes"] for r in records)}))
