"""Preserve the completed fixed-seed Stage1 DB/netlists without altering them."""
import gzip
import hashlib
import json
from pathlib import Path

root = Path(__file__).resolve().parents[1]
run = json.loads((root / "evidence/student_stage1_run.json").read_text(encoding="utf-8-sig"))
timing = json.loads((root / "evidence/student_stage1_timing.json").read_text(encoding="utf-8-sig"))
assert run["state"] == "STAGE1_COMPLETE_REQUIRES_GATES" and not run["bitgen"]
assert timing["result"] == "PASS_CANONICAL_TIMING_PARSERS"
out = root / "evidence/student_seed1_stage1"
out.mkdir(exist_ok=True)
records = []
for record in timing["artifacts"]:
    source = Path(record["path"])
    raw = source.read_bytes()
    assert hashlib.sha256(raw).hexdigest().upper() == record["sha256"]
    destination = out / (source.name + ".gz")
    if destination.exists():
        assert gzip.decompress(destination.read_bytes()) == raw
    else:
        destination.write_bytes(gzip.compress(raw, compresslevel=6, mtime=0))
    packed = destination.read_bytes()
    assert gzip.decompress(packed) == raw
    records.append({"source": str(source), "bytes": len(raw),
                    "sha256": record["sha256"],
                    "archive": destination.relative_to(root).as_posix(),
                    "archive_bytes": len(packed),
                    "archive_sha256": hashlib.sha256(packed).hexdigest().upper()})
manifest = {"schema": "controls_student_stage1_archive/v1",
            "place_seed": 1, "bitgen": False, "hardware": "NOT_TESTED",
            "identity": "Exact decompressed bytes match the post-fix_hold Stage1 timing receipt",
            "artifacts": records}
(out / "archive.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
print(json.dumps({"archived_files": len(records),
                  "compressed_bytes": sum(r["archive_bytes"] for r in records)}))
