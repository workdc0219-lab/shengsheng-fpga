#!/usr/bin/env python3
"""Offline causal reset-branch gate for a placed Anlogic PNL / report_nets dump.

Why this exists
---------------
P1-03 was not an RTL bug.  The placer routed the HDMI-core reset branch
``I_rst_dup_24`` through the combinational output of the KEY3 long-hold
counter LUT (``u_key_router/key3_hold_count_reg[24]_syn_4`` at ``x19y6_3``).
When the counter entered its bit-24 window the LUT term ``~C & D`` pulled the
reset branch high and reset the HDMI lock/pause, ACR and tone registers.
RTL simulation and normal STA cannot see this: the path only exists in the
*placed* netlist.  Every re-place (F6, UI work, a new seed) draws new routing
and may recreate the same class of defect.

This script is the build-time, fail-closed gate for that class of defect.  It
does not import TD, does not route, does not program hardware and does not
model electrical coupling.  It reads a placed PNL or a ``report_nets`` log and
answers one causal question:

    Is any reset net physically passed through a functional key/counter LUT?

It additionally checks that the reset branch still has the same driver and the
same 27 SR loads as the reviewed route-only/F1 baseline.

Accepted inputs
---------------
1. TD ``write_pnl`` text (``*.pnl``, optionally gzip-compressed).
   Structure used::

       net <full hierarchical name>
       {
           pin
           {
               <instance>, <port>;
               ...
           }
           feedthroughs
           {
               x19y6_3(a1.f1)
               ...
           }
           route
           {
               x19y6.a7,x19y6.f7;
               ...
           }
       }

   and the flat instance section::

       instance <full hierarchical name>
       {
           model lslice;
           ...
           attribute
           {
               REG1_SD:F
               LUTG1=(~C*D)
               ...
           }
           location x19y6_3;
       }

2. TD ``report_nets`` text (``report_nets ... -dr``), including the
   BEFORE/AFTER snapshots captured in one TD process.  Relevant lines::

       RUN-1001 : Net: <name>
       RUN-1001 : Driver pin(s):
       RUN-1001 :   1 | u_seg7/mux5_syn_316.q[0] | EG_PHY_LSLICE (SLICE) | [ 17 8]
       RUN-1001 : Load pin(s):
       RUN-1001 :   1 | ..._reg[23]_syn_4.sr
       RUN-1001 : Detail Route:
       RUN-1001 :   x19y6_a7 | x19y6_f7

   report_nets has no instance/attribute data.  Pass ``--placement`` with the
   matching PNL so feed-through hosts can still be classified; without it the
   key-LUT check is reported INCOMPLETE rather than silently passing.

Gate rules
----------
* A reset net is any net whose leaf name matches ``I_rst``, ``I_rst_dup_<n>``
  or contains ``reset24`` (case-insensitive).
* A PASS requires: at least one reset net found; no reset net passed through
  ``u_key_router/*``; no functional counter LUT on a reset path; every
  feed-through host resolved (or an empty slice bridge outside a key tile);
  and, when the baseline JSON is present, the target branch driver and all
  27 SR endpoints identical to the baseline.
* Empty LUT lanes and empty (unoccupied) slice bridge locations are allowed.
  That is exactly what the accepted route-only repair uses (``x17y11_1``).
* Functional *non-key* bridges are allowed with a warning; pass
  ``--strict-functional`` to reject them too.
* No reset nets found is a FAIL, not a vacuous PASS.

CLI
---
    python gate_reset_branch.py --pnl route_only.pnl.gz \
        --out route_only.reset_gate.json

    python gate_reset_branch.py --pnl f6.pnl --baseline \
        .../reset24_feedthrough_branch_review.json \
        --out f6_seed1.reset_gate.json

    python gate_reset_branch.py --self-test --out selftest_receipt.json

Exit codes: 0 = PASS, 1 = FAIL, 2 = INCOMPLETE (missing placement / bad input).

Limits
------
Placement route topology is not a transistor-level model of the LUT F/G/E
mux.  This gate proves "the reset wire is not routed through this functional
cell", not "the board boots".  It must be followed by STA, a same-DB bitgen
and board tests.
"""

from __future__ import print_function

import argparse
import gzip
import hashlib
import io
import json
import os
import re
import sys
from collections import OrderedDict

GATE_NAME = "reset_branch_causal"
GATE_VERSION = "1.0.0"

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
DEFAULT_BASELINE = os.path.join(
    REPO,
    "2026_topic1_shengsheng_sm_f1c",
    "evidence",
    "seed1_implementation_audit",
    "reset24_feedthrough_branch_review.json",
)

DEFAULT_F1_PNL = os.path.join(
    REPO,
    "2026_topic1_shengsheng_sm_f1c",
    "evidence",
    "seed1_implementation_audit",
    "serial_capture",
    "original_f1.pnl",
)
DEFAULT_ECO_PNL = os.path.join(
    REPO,
    "2026_topic1_shengsheng_sm_f1c",
    "evidence",
    "seed1_implementation_audit",
    "reset_feedthrough_out.pnl",
)
DEFAULT_SNAPSHOT = os.path.join(
    REPO,
    "2026_topic1_shengsheng_sm_f1c",
    "evidence",
    "seed1_implementation_audit",
    "route_only_20261025_2225",
    "snapshot_before_after.log.gz",
)
DEFAULT_ROUTE_ONLY_PNL_CANDIDATES = [
    "<EXTERNAL_ROUTE_ECO>/sealed/routeD_after.pnl.gz",
    os.path.join(
        REPO,
        "2026_topic1_shengsheng_sm_f1c",
        "evidence",
        "seed1_implementation_audit",
        "route_only_20261025_2225",
        "routeD_after.pnl.gz",
    ),
]

RESET_NET_RE = re.compile(r"(?:^|/)(?:I_rst(?:_dup_\d+)?|reset24\w*)$", re.IGNORECASE)
HARD_KEY_RE = re.compile(r"(?:^|/)u_key_router/", re.IGNORECASE)
COUNTER_RE = re.compile(r"(hold_count|debounce_count|_count|counter|cnt)", re.IGNORECASE)
KEY_ANY_RE = re.compile(
    r"(?:^|/)u_key_router/|(?:^|/)[^/]*(?:key\d*_|button|chord|debounce|hold_count|_count|counter|cnt)",
    re.IGNORECASE,
)

INSTANCE_RE = re.compile(r"^instance (\S+)$")
MODEL_RE = re.compile(r"^model (\S+);$")
LOCATION_RE = re.compile(r"^location (\S+);$")
NET_RE = re.compile(r"^net (.+)$")
PNL_FEEDTHROUGH_RE = re.compile(r"^(x\d+y\d+_\d+)\(([^)]*)\)$")
PIN_NODE_RE = re.compile(r"^(x\d+y\d+)[._]([a-z]+?)(\d+)$")
PIN_PAIR_RE = re.compile(r"^([a-z]+\d*)\.([a-z]+\d*)$", re.IGNORECASE)

OUTPUT_PORT_BASES = {
    "q",
    "f",
    "fx",
    "fco",
    "doa",
    "dob",
    "clko",
    "clkout",
    "p",
    "di",
    "diq",
    "opad",
    "bpad",
    "dq",
}

SLICE_MODELS = {"lslice", "mslice"}
# Routing-only primitives that may legitimately bridge a wire.  Anything else
# (I/O, BRAM, PLL, DSP, ...) is failed closed: a reset branch must not be
# routed through a functional hard block.
ALLOWED_SPECIAL_MODELS = {"plb", "lslb"}

LIMITS = [
    "PNL route topology is not a transistor-level model of the LUT F/G/E mux.",
    "A key-named empty LUT lane is reported as a warning, not silently allowed; "
    "u_key_router hosts and functional counter lanes are fatal.",
    "Driver/endpoint comparison is netlist-level identity; coordinates may move.",
    "This gate is necessary but not sufficient: STA, same-DB bitgen, SRAM and "
    "cold-boot tests remain required.",
    "No TD invocation, no place/route, no bitgen, no hardware access.",
]


# --------------------------------------------------------------------------
# small helpers
# --------------------------------------------------------------------------


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest().upper()


def is_gzip(path):
    with open(path, "rb") as source:
        return source.read(2) == b"\x1f\x8b"


def open_text(path):
    if is_gzip(path):
        return gzip.open(path, "rt", encoding="utf-8-sig", errors="replace")
    return open(path, "rt", encoding="utf-8-sig", errors="replace")


def read_head(path, size=4096):
    if is_gzip(path):
        with gzip.open(path, "rt", encoding="utf-8-sig", errors="replace") as source:
            return source.read(size)
    with open(path, "rt", encoding="utf-8-sig", errors="replace") as source:
        return source.read(size)


def detect_format_from_head(head):
    if "Pnl Version:" in head or re.search(r"(?m)^\s*net \S+", head):
        return "pnl"
    if "Net: " in head or "NET_BEGIN_" in head or "Detail Route:" in head or "CELLS_BEGIN_" in head:
        return "report_nets"
    return None


def parse_pin_name(text):
    """Split ``cell.port`` into (cell, port); tolerate no dot."""
    text = text.strip()
    if "." in text:
        cell, port = text.rsplit(".", 1)
        return cell, port
    return text, ""


def port_base(port):
    match = re.match(r"([A-Za-z_]+)", port or "")
    return match.group(1).lower() if match else ""


def is_output_port(port):
    return port_base(port) in OUTPUT_PORT_BASES


def normalize_pin_number(out_name):
    """Return (slice_index, lane, pin_kind) for f3/fx5/a7 style pins."""
    match = re.match(r"^(fx|f)(\d+)$", out_name, re.IGNORECASE)
    if not match:
        return None
    number = int(match.group(2))
    return number // 2, number % 2, match.group(1).lower()


def external_pin_pair(feedthrough_pins):
    """Parse ``a1.f1`` / ``a1.fx1``; return (in_pin, out_pin) or None."""
    match = PIN_PAIR_RE.match(feedthrough_pins.strip())
    if not match:
        return None
    return match.group(1).lower(), match.group(2).lower()


# --------------------------------------------------------------------------
# PNL / report_nets parsers
# --------------------------------------------------------------------------


def new_design(fmt):
    return {
        "format": fmt,
        "instances": {},  # name -> dict
        "instances_by_location": {},  # location -> dict
        "nets": OrderedDict(),  # name -> net
        "net_occurrences": {},  # report_nets only: name -> [occurrence]
        "counts": {"instances": 0, "nets": 0, "lines": 0},
    }


def add_instance(design, inst):
    if not inst.get("name") or not inst.get("location"):
        return
    design["instances"][inst["name"]] = inst
    design["instances_by_location"][inst["location"]] = inst


def parse_pnl(lines, design):
    current_instance = None
    in_attributes = False
    in_net = False
    current_net = None
    section = None

    for raw in lines:
        design["counts"]["lines"] += 1
        s = raw.strip()
        if not s:
            continue
        if in_net:
            if s == "{":
                continue
            if s in ("pin", "feedthroughs", "route"):
                section = s
                continue
            if s == "}":
                if section is not None:
                    section = None
                else:
                    finalize_net(design, current_net)
                    current_net = None
                    in_net = False
                continue
            if current_net is None:
                continue
            if section == "pin" and s.endswith(";"):
                body = s[:-1]
                if "," in body:
                    cell, port = body.rsplit(",", 1)
                    current_net["pins"].append((cell.strip(), port.strip()))
            elif section == "feedthroughs":
                match = PNL_FEEDTHROUGH_RE.match(s)
                if match:
                    current_net["feedthroughs"].append(
                        {"location": match.group(1), "pins": match.group(2).strip(),
                         "source": "explicit"}
                    )
            elif section == "route" and s.endswith(";"):
                body = s[:-1]
                if "," in body:
                    src, dst = body.split(",", 1)
                    current_net["edges"].append((src.strip(), dst.strip()))
            continue

        match = INSTANCE_RE.match(s)
        if match:
            if current_instance:
                add_instance(design, current_instance)
            current_instance = {
                "name": match.group(1),
                "model": None,
                "location": None,
                "attrs": {},
            }
            in_attributes = False
            continue
        if current_instance is not None:
            match = MODEL_RE.match(s)
            if match:
                current_instance["model"] = match.group(1)
                continue
            if s == "attribute":
                in_attributes = True
                continue
            if in_attributes:
                if s == "}":
                    in_attributes = False
                    continue
                if ":" in s:
                    key, value = s.split(":", 1)
                    current_instance["attrs"][key.strip()] = value.strip()
                elif "=" in s:
                    key, value = s.split("=", 1)
                    current_instance["attrs"][key.strip()] = value.strip()
                continue
            match = LOCATION_RE.match(s)
            if match:
                current_instance["location"] = match.group(1)
                add_instance(design, current_instance)
                current_instance = None
                in_attributes = False
                continue
            continue

        match = NET_RE.match(s)
        if match:
            current_net = {
                "name": match.group(1).strip(),
                "pins": [],
                "feedthroughs": [],
                "edges": [],
                "source": "pnl",
            }
            in_net = True
            section = None
            continue

    if current_instance:
        add_instance(design, current_instance)
    if current_net:
        finalize_net(design, current_net)
    design["counts"]["instances"] = len(design["instances"])
    design["counts"]["nets"] = len(design["nets"])


def finalize_net(design, net):
    if not net:
        return
    if net["name"] in design["nets"]:
        # A malformed/concatenated dump: keep the last complete definition.
        pass
    design["nets"][net["name"]] = net


def parse_report_nets(lines, design, section_choice="first"):
    stage = None
    current = None
    section = None

    def flush():
        nonlocal current
        if current is not None:
            design["net_occurrences"].setdefault(current["name"], []).append(current)
            current = None

    for raw in lines:
        design["counts"]["lines"] += 1
        s = raw.strip()
        if not s:
            continue
        if s.startswith("RUN-1001 :"):
            s = s[len("RUN-1001 :"):].strip()
        elif s.startswith("RUN-1002 :") or s.startswith("RUN-1003 :") or s.startswith("RUN-1004 :"):
            continue
        match = re.match(r"^NET_BEGIN_(BEFORE|AFTER)_", s)
        if match:
            flush()
            stage = match.group(1).lower()
            section = None
            continue
        if s.startswith("NET_END_"):
            flush()
            section = None
            continue
        if s.startswith("Net: "):
            flush()
            current = {
                "name": s[5:].strip(),
                "stage": stage,
                "pins": [],
                "drivers": [],
                "loads": [],
                "feedthroughs": [],
                "edges": [],
                "source": "report_nets",
            }
            section = None
            continue
        if current is None:
            continue
        if s in ("Driver pin(s):", "Load pin(s):", "Detail Route:", "Attributes:"):
            section = s
            continue
        if "|" not in s:
            continue
        columns = [item.strip() for item in s.split("|")]
        if section == "Driver pin(s):":
            if len(columns) >= 2 and columns[0].isdigit():
                current["drivers"].append(parse_pin_name(columns[1]))
        elif section == "Load pin(s):":
            if len(columns) >= 2 and columns[0].isdigit():
                current["loads"].append(parse_pin_name(columns[1]))
        elif section == "Detail Route:":
            if len(columns) >= 2 and columns[0] and columns[0] != "from":
                current["edges"].append((columns[0], columns[1]))
    flush()

    for name, occurrences in design["net_occurrences"].items():
        chosen = choose_occurrence(occurrences, section_choice)
        if chosen is not None:
            net = {
                "name": name,
                "pins": list(chosen["drivers"]) + [p for p in chosen["loads"]],
                "drivers": list(chosen["drivers"]),
                "loads": list(chosen["loads"]),
                "feedthroughs": [],
                "edges": list(chosen["edges"]),
                "source": "report_nets",
                "stage": chosen["stage"],
            }
            design["nets"][name] = net
    design["counts"]["instances"] = len(design["instances"])
    design["counts"]["nets"] = len(design["nets"])


def choose_occurrence(occurrences, choice):
    if not occurrences:
        return None
    if choice == "last":
        return occurrences[-1]
    if choice in ("before", "after"):
        for occurrence in occurrences:
            if occurrence.get("stage") == choice:
                return occurrence
        return None
    return occurrences[0]


def parse_design_from_lines(lines, fmt, section_choice="first"):
    design = new_design(fmt)
    if fmt == "pnl":
        parse_pnl(lines, design)
    elif fmt == "report_nets":
        parse_report_nets(lines, design, section_choice)
    else:
        raise ValueError("unknown format: {}".format(fmt))
    classify_pins(design)
    return design


def parse_design(path, section_choice="first"):
    head = read_head(path)
    fmt = detect_format_from_head(head)
    if fmt is None:
        raise ValueError("cannot detect PNL or report_nets format in {}".format(path))
    with open_text(path) as source:
        design = parse_design_from_lines(source, fmt, section_choice)
    design["path"] = path
    design["sha256"] = sha256_file(path)
    return design


def parse_instances(path):
    """Parse only the instance section of a PNL file (for --placement)."""
    design = new_design("pnl")
    current = None
    in_attributes = False
    with open_text(path) as source:
        for raw in source:
            s = raw.strip()
            if not s:
                continue
            match = INSTANCE_RE.match(s)
            if match:
                if current:
                    add_instance(design, current)
                current = {"name": match.group(1), "model": None,
                           "location": None, "attrs": {}}
                in_attributes = False
                continue
            if current is None:
                continue
            match = MODEL_RE.match(s)
            if match:
                current["model"] = match.group(1)
                continue
            if s == "attribute":
                in_attributes = True
                continue
            if in_attributes:
                if s == "}":
                    in_attributes = False
                    continue
                if ":" in s:
                    key, value = s.split(":", 1)
                    current["attrs"][key.strip()] = value.strip()
                elif "=" in s:
                    key, value = s.split("=", 1)
                    current["attrs"][key.strip()] = value.strip()
                continue
            match = LOCATION_RE.match(s)
            if match:
                current["location"] = match.group(1)
                add_instance(design, current)
                current = None
    if current:
        add_instance(design, current)
    design["counts"]["instances"] = len(design["instances"])
    design["path"] = path
    design["sha256"] = sha256_file(path)
    return design


def classify_pins(design):
    for net in design["nets"].values():
        if net.get("drivers") is not None and net.get("loads") is not None:
            # report_nets already has explicit direction.
            if net["source"] == "report_nets":
                continue
        drivers, loads = [], []
        for cell, port in net["pins"]:
            if is_output_port(port):
                drivers.append((cell, port))
            else:
                loads.append((cell, port))
        net["drivers"] = drivers
        net["loads"] = loads


# --------------------------------------------------------------------------
# feed-through classification
# --------------------------------------------------------------------------


def derive_route_feedthroughs(net):
    """Find one-hop LUT pass-throughs (a7 -> f7) in the recorded route.

    This is a cross-check / report_nets fallback.  It over-approximates a
    normal combinational LUT output as a pass-through when the same internal
    node is both a destination and a source, so results are labelled
    ``route_inferred`` and the explicit PNL ``feedthroughs`` section wins when
    both exist.
    """
    edges = set(net.get("edges", []))
    destinations = {}
    sources = {}
    for src, dst in edges:
        destinations.setdefault(dst, set()).add(src)
        sources.setdefault(src, set()).add(dst)
    found = []
    for node, incoming in destinations.items():
        if node not in sources:
            continue
        match = PIN_NODE_RE.match(node)
        if not match:
            continue
        tile, pin_kind, number = match.group(1), match.group(2).lower(), int(match.group(3))
        if pin_kind not in ("f", "fx"):
            continue
        for previous in incoming:
            previous_match = PIN_NODE_RE.match(previous)
            if not previous_match or previous_match.group(1) != tile:
                continue
            if previous_match.group(2).lower() not in ("a", "b", "c", "d", "e"):
                continue
            found.append({
                "location": "{}_{}".format(tile, number // 2),
                "pins": "{}.{}".format(previous_match.group(2).lower() + previous_match.group(3),
                                       pin_kind + match.group(3)),
                "lane": number % 2,
                "out_kind": pin_kind,
                "source": "route_inferred",
            })
    return found


def normalize_feedthrough_list(net):
    """Merge explicit PNL feedthroughs with route-derived pass-throughs.

    Deduplicate on (location, lane, output kind): PNL spells the same physical
    pass-through as ``x19y6_3(a1.f1)`` while the route dump spells it
    ``x19y6.a7 -> x19y6.f7``.  The explicit PNL entry wins.
    """
    merged = OrderedDict()
    for item in net.get("feedthroughs", []):
        pair = external_pin_pair(item["pins"])
        lane = None
        out_kind = None
        if pair:
            out = pair[1]
            match = re.match(r"^(fx|f)(\d+)$", out)
            if match:
                lane = int(match.group(2)) % 2
                out_kind = match.group(1)
        key = (item["location"], lane, out_kind)
        merged[key] = {
            "location": item["location"],
            "pins": item["pins"],
            "lane": lane,
            "out_kind": out_kind,
            "source": item.get("source", "explicit"),
        }
    for item in derive_route_feedthroughs(net):
        key = (item["location"], item.get("lane"), item.get("out_kind"))
        if key not in merged:
            merged[key] = item
    return list(merged.values())


def lane_function_used(model, attrs, lane, out_kind):
    """Return True when the indicated LUT/FF lane is functionally occupied."""
    ff_mode = attrs.get("REG{}_SD".format(lane), "MI").strip('"')
    ff_uses_lut = ff_mode in ("F", "FX")
    macro = attrs.get("MACRO", "")
    if model == "lslice":
        lut_present = any(
            key in attrs
            for key in ("LUT{}".format(lane), "LUTF{}".format(lane), "LUTG{}".format(lane))
        )
        func5 = attrs.get("LSFMUX{}".format(lane), "").strip('"') == "FUNC5"
        if out_kind == "fx":
            return lut_present or ff_uses_lut
        return ff_uses_lut or (lut_present and (func5 or bool(macro)))
    if model == "mslice":
        lut_present = "LUT{}".format(lane) in attrs
        return lut_present or ff_uses_lut
    return False


def classify_feedthrough(design, feedthrough, strict_functional):
    location = feedthrough["location"]
    tile = location.rsplit("_", 1)[0] if "_" in location else location
    instance = design["instances_by_location"].get(location)
    result = OrderedDict()
    result.update(feedthrough)
    result["tile"] = tile

    key_tiles = design.setdefault("key_tiles", set())
    if instance is None:
        result["host"] = None
        result["host_model"] = None
        result["lane_functional"] = None
        if tile in key_tiles:
            result["kind"] = "empty_bridge_in_key_tile"
            result["severity"] = "fail"
            result["reason"] = (
                "route-through at an unoccupied slice inside a tile that hosts "
                "a key/counter cell ({})".format(tile)
            )
        else:
            result["kind"] = "empty_slice_bridge"
            result["severity"] = "allow"
            result["reason"] = "unoccupied slice location used as a routing bridge"
        return result

    name = instance["name"]
    model = instance["model"]
    result["host"] = name
    result["host_model"] = model
    result["host_location"] = instance["location"]
    result["host_attributes_subset"] = {
        key: instance["attrs"][key]
        for key in (
            "REG0_SD", "REG1_SD", "LSFMUX0", "LSFMUX1",
            "LUT0", "LUT1", "LUTF0", "LUTF1", "LUTG0", "LUTG1", "MACRO",
        )
        if key in instance["attrs"]
    }
    lane = feedthrough.get("lane")
    out_kind = feedthrough.get("out_kind") or "f"
    if lane is None:
        # Fall back to the explicit pin string if a malformed line slipped in.
        pair = external_pin_pair(feedthrough.get("pins", ""))
        match = re.match(r"^(fx|f)(\d+)$", pair[1]) if pair else None
        lane = int(match.group(2)) % 2 if match else 0
        out_kind = match.group(1) if match else out_kind

    functional = model in SLICE_MODELS and lane_function_used(model, instance["attrs"], lane, out_kind)
    result["lane"] = lane
    result["lane_functional"] = functional

    if HARD_KEY_RE.search(name):
        result["kind"] = "u_key_router_host"
        result["severity"] = "fail"
        result["reason"] = "reset branch is routed through a u_key_router cell"
    elif COUNTER_RE.search(name):
        if functional:
            result["kind"] = "counter_lut_host"
            result["severity"] = "fail"
            result["reason"] = "reset branch is routed through a functional counter LUT"
        else:
            result["kind"] = "counter_host_empty_lane"
            result["severity"] = "warn"
            result["reason"] = "counter-named cell but the used lane is an empty bridge"
    elif model not in SLICE_MODELS:
        if model in ALLOWED_SPECIAL_MODELS:
            result["kind"] = "special_bridge"
            result["severity"] = "allow"
            result["reason"] = "routing-only special bridge ({})".format(model)
        else:
            result["kind"] = "unexpected_host_model"
            result["severity"] = "fail"
            result["reason"] = (
                "reset branch is routed through a non-slice functional block "
                "({})".format(model)
            )
    elif functional:
        result["kind"] = "functional_nonkey_bridge"
        result["severity"] = "fail" if strict_functional else "warn"
        result["reason"] = "functional non-key LUT/FF lane used as a routing bridge"
    else:
        result["kind"] = "empty_lane_bridge"
        result["severity"] = "allow"
        result["reason"] = "LUT lane is not used by logic or by the FF data path"
    return result


def build_key_tiles(design):
    tiles = set()
    for instance in design["instances"].values():
        if KEY_ANY_RE.search(instance["name"]):
            location = instance.get("location", "")
            if "_" in location:
                tiles.add(location.rsplit("_", 1)[0])
    design["key_tiles"] = tiles


# --------------------------------------------------------------------------
# baseline
# --------------------------------------------------------------------------


def load_baseline(path):
    if not path or path.lower() in ("none", "off"):
        return None
    if not os.path.exists(path):
        return None
    with open(path, "rt", encoding="utf-8-sig") as source:
        data = json.load(source)
    data["_path"] = path
    data["_sha256"] = sha256_file(path)
    return data


def baseline_expectations(baseline):
    target = baseline["target"]
    source_cell, source_port = parse_pin_name(target["source"])
    endpoints = set()
    for endpoint in target["all_sr_endpoints"]:
        cell = endpoint["cell"]
        route_endpoint = endpoint.get("route_endpoint", "")
        port = route_endpoint.rsplit(".", 1)[-1] if "." in route_endpoint else "sr"
        endpoints.add((cell, port))
    return {
        "net": target["net"],
        "driver": (source_cell, source_port),
        "endpoints": endpoints,
        "endpoint_count": len(endpoints),
        "declared_feedthrough": target.get("feedthrough"),
        "declared_key_cell": target.get("functional_cell"),
    }


def compare_baseline(design, baseline, target_net_name=None):
    expectations = baseline_expectations(baseline)
    wanted_net = target_net_name or expectations["net"]
    net = design["nets"].get(wanted_net)
    check = OrderedDict(id="RESET-03-BASELINE-DRIVER-AND-27-SR", status="FAIL")
    detail = OrderedDict()
    detail["baseline_path"] = baseline["_path"]
    detail["baseline_sha256"] = baseline["_sha256"]
    detail["baseline_target_net"] = wanted_net
    detail["expected_driver"] = ".".join(expectations["driver"])
    detail["expected_endpoint_count"] = expectations["endpoint_count"]
    if net is None:
        check["status"] = "FAIL"
        detail["error"] = "target reset net not found in input"
        check["detail"] = detail
        return check

    actual_driver = tuple(net["drivers"][0]) if len(net["drivers"]) == 1 else tuple()
    actual_drivers = [list(pin) for pin in net["drivers"]]
    actual_endpoints = set(net["loads"])
    detail["actual_drivers"] = actual_drivers
    detail["actual_load_count"] = len(actual_endpoints)
    detail["driver_match"] = actual_driver == expectations["driver"]
    missing = sorted(expectations["endpoints"] - actual_endpoints)
    extra = sorted(actual_endpoints - expectations["endpoints"])
    detail["missing_endpoints"] = [list(pin) for pin in missing]
    detail["extra_endpoints"] = [list(pin) for pin in extra]
    detail["endpoints_match"] = not missing and not extra
    if detail["driver_match"] and detail["endpoints_match"]:
        check["status"] = "PASS"
        check["detail"] = detail
        return check

    reasons = []
    if not detail["driver_match"]:
        reasons.append("driver mismatch")
    if missing:
        reasons.append("{} endpoint(s) missing".format(len(missing)))
    if extra:
        reasons.append("{} unexpected endpoint(s)".format(len(extra)))
    detail["reason"] = "; ".join(reasons)
    check["detail"] = detail
    return check


# --------------------------------------------------------------------------
# gate
# --------------------------------------------------------------------------


def evaluate(design, baseline, strict_functional=False, target_net_name=None):
    build_key_tiles(design)
    reset_nets = [
        net for name, net in design["nets"].items() if RESET_NET_RE.search(name)
    ]
    checks = []
    warnings = []

    discovery = OrderedDict(id="RESET-01-DISCOVERY", status="FAIL")
    discovery["detail"] = {
        "reset_net_pattern": RESET_NET_RE.pattern,
        "reset_nets": [net["name"] for net in reset_nets],
        "count": len(reset_nets),
    }
    if reset_nets:
        discovery["status"] = "PASS"
    else:
        discovery["detail"]["reason"] = (
            "no reset net found; a gate over an empty set is not evidence"
        )
    checks.append(discovery)

    net_reports = []
    key_violations = []
    unresolved_placement = False
    feedthrough_total = 0
    for net in reset_nets:
        feedthroughs = normalize_feedthrough_list(net)
        feedthrough_total += len(feedthroughs)
        rows = []
        for feedthrough in feedthroughs:
            if design["format"] == "report_nets" and not design["instances"]:
                unresolved_placement = True
                row = OrderedDict(feedthrough)
                row["kind"] = "unclassified_no_placement"
                row["severity"] = "incomplete"
                row["reason"] = "report_nets input has no instance/attribute data"
            else:
                row = classify_feedthrough(design, feedthrough, strict_functional)
            rows.append(row)
            if row["severity"] == "fail":
                key_violations.append({"net": net["name"], "row": row})
            elif row["severity"] == "warn":
                warnings.append({"net": net["name"], "row": row})
        net_reports.append({
            "name": net["name"],
            "driver": [list(pin) for pin in net["drivers"]],
            "load_count": len(net["loads"]),
            "feedthroughs": rows,
            "violations": [row for row in rows if row["severity"] == "fail"],
        })

    key_check = OrderedDict(id="RESET-02-KEY-LUT-PATH", status="PASS")
    if unresolved_placement:
        key_check["status"] = "INCOMPLETE"
        key_check["detail"] = {
            "reason": "report_nets has no placement; pass --placement <pnl>",
            "feedthroughs": feedthrough_total,
        }
    elif key_violations:
        key_check["status"] = "FAIL"
        key_check["detail"] = {
            "violation_count": len(key_violations),
            "violations": key_violations,
        }
    else:
        key_check["detail"] = {
            "feedthrough_count": feedthrough_total,
            "functional_nonkey_warnings": len(warnings),
        }
    checks.append(key_check)

    if baseline is not None:
        checks.append(compare_baseline(design, baseline, target_net_name))
    else:
        skipped = OrderedDict(id="RESET-03-BASELINE-DRIVER-AND-27-SR", status="SKIPPED")
        skipped["detail"] = {
            "reason": "baseline JSON not supplied or not found",
            "baseline_path": DEFAULT_BASELINE,
        }
        checks.append(skipped)

    statuses = [check["status"] for check in checks]
    if "FAIL" in statuses:
        result = "FAIL"
    elif "INCOMPLETE" in statuses:
        result = "INCOMPLETE"
    else:
        result = "PASS"

    report = OrderedDict()
    report["gate"] = GATE_NAME
    report["gate_version"] = GATE_VERSION
    report["result"] = result
    report["input"] = {
        "path": design.get("path"),
        "sha256": design.get("sha256"),
        "format": design["format"],
        "instances": len(design["instances"]),
        "nets": len(design["nets"]),
        "lines": design["counts"]["lines"],
    }
    if design.get("placement_path"):
        report["input"]["placement_path"] = design["placement_path"]
        report["input"]["placement_sha256"] = design.get("placement_sha256")
    report["baseline"] = (
        {
            "path": baseline["_path"],
            "sha256": baseline["_sha256"],
            "target_net": baseline["target"]["net"],
            "endpoint_count": len(baseline["target"]["all_sr_endpoints"]),
        }
        if baseline
        else None
    )
    report["summary"] = {
        "reset_nets": len(reset_nets),
        "feedthroughs_classified": feedthrough_total,
        "fatal_violations": len(key_violations),
        "warnings": len(warnings),
        "strict_functional": bool(strict_functional),
    }
    report["checks"] = checks
    report["reset_nets"] = net_reports
    report["warnings"] = warnings
    report["limits"] = LIMITS
    report["script"] = {
        "path": os.path.abspath(__file__),
        "sha256": sha256_file(os.path.abspath(__file__)),
    }
    return report


def run_gate(path, baseline_path, section="first", placement_path=None,
             strict_functional=False, target_net_name=None):
    design = parse_design(path, section_choice=section)
    if placement_path:
        placement = parse_instances(placement_path)
        design["instances"] = placement["instances"]
        design["instances_by_location"] = placement["instances_by_location"]
        design["placement_path"] = placement_path
        design["placement_sha256"] = placement["sha256"]
    baseline = load_baseline(baseline_path) if baseline_path else None
    return evaluate(design, baseline, strict_functional, target_net_name)


def write_report(report, output_path):
    text = json.dumps(report, indent=2) + "\n"
    if output_path == "-":
        sys.stdout.write(text)
        return
    directory = os.path.dirname(os.path.abspath(output_path))
    if directory and not os.path.isdir(directory):
        os.makedirs(directory)
    with open(output_path, "w", encoding="utf-8") as target:
        target.write(text)


# --------------------------------------------------------------------------
# self test / negative controls
# --------------------------------------------------------------------------


def text_of(path):
    with open_text(path) as source:
        return source.read()


def mutate_route_only(text):
    """Return a dict of synthetic PNL texts derived from the route-only PNL."""
    variants = {}
    variants["mut_key_feedthrough"] = text.replace(
        "x17y11_1(d1.f1)", "x19y6_3(a1.f1)", 1
    )
    variants["mut_endpoint_removed"] = text.replace(
        "u_media_tone/clamped[6]_syn_4, sr;", "", 1
    )
    variants["mut_driver_swapped"] = text.replace(
        "u_seg7/mux5_syn_316, q[0];", "u_seg7/mux5_syn_317, q[0];", 1
    )
    variants["mut_key_tile_empty_bridge"] = text.replace(
        "x17y11_1(d1.f1)", "x19y6_0(a0.f0)", 1
    )
    variants["mut_functional_nonkey"] = text.replace(
        "x17y11_1(d1.f1)", "x17y8_1(a1.f1)", 1
    )
    return variants


def find_route_only_pnl():
    for candidate in DEFAULT_ROUTE_ONLY_PNL_CANDIDATES:
        if os.path.exists(candidate):
            return candidate
    return None


def case_result(name, expected, report):
    actual = report["result"]
    checks = {check["id"]: check["status"] for check in report["checks"]}
    ok = actual == expected
    violations = []
    for net in report["reset_nets"]:
        for row in net["violations"]:
            violations.append({
                "net": net["name"],
                "location": row.get("location"),
                "host": row.get("host"),
                "kind": row.get("kind"),
                "reason": row.get("reason"),
            })
    return OrderedDict([
        ("case", name),
        ("expected", expected),
        ("actual", actual),
        ("case_ok", ok),
        ("checks", checks),
        ("summary", report["summary"]),
        ("fatal_violations", violations),
    ])


def self_test(output_path):
    baseline = DEFAULT_BASELINE if os.path.exists(DEFAULT_BASELINE) else None
    cases = []
    evidence = OrderedDict()

    def run_path(path, expected, section="first", placement=None,
                 strict=False, extra=None):
        report = run_gate(path, baseline, section=section,
                          placement_path=placement,
                          strict_functional=strict)
        row = case_result(os.path.basename(path) if not extra else extra,
                          expected, report)
        row["input_path"] = path
        row["input_sha256"] = report["input"]["sha256"]
        cases.append(row)
        return report

    if os.path.exists(DEFAULT_F1_PNL):
        report = run_path(DEFAULT_F1_PNL, "FAIL", extra="original_f1_pnl")
        evidence["original_f1_key_host"] = [
            violation.get("host")
            for net in report["reset_nets"]
            for violation in net["violations"]
        ]
    else:
        cases.append(OrderedDict([("case", "original_f1_pnl"), ("expected", "FAIL"),
                                  ("actual", "SKIP"), ("case_ok", None),
                                  ("reason", "file not found")]))

    if os.path.exists(DEFAULT_ECO_PNL):
        run_path(DEFAULT_ECO_PNL, "FAIL", extra="reset_split_eco_pnl")
    else:
        cases.append(OrderedDict([("case", "reset_split_eco_pnl"), ("expected", "FAIL"),
                                  ("actual", "SKIP"), ("case_ok", None),
                                  ("reason", "file not found")]))

    route_only = find_route_only_pnl()
    route_only_text = None
    if route_only:
        report = run_path(route_only, "PASS", extra="route_only_pnl")
        evidence["route_only_feedthroughs"] = [
            {"net": net["name"], "feedthroughs": net["feedthroughs"]}
            for net in report["reset_nets"]
            if net["feedthroughs"]
        ]
        route_only_text = text_of(route_only)
    else:
        cases.append(OrderedDict([("case", "route_only_pnl"), ("expected", "PASS"),
                                  ("actual", "SKIP"), ("case_ok", None),
                                  ("reason", "routeD_after.pnl.gz not found")]))

    if os.path.exists(DEFAULT_SNAPSHOT) and os.path.exists(DEFAULT_F1_PNL):
        run_path(DEFAULT_SNAPSHOT, "FAIL", section="before",
                 placement=DEFAULT_F1_PNL, extra="report_nets_before_f1")
        run_path(DEFAULT_SNAPSHOT, "PASS", section="after",
                 placement=DEFAULT_F1_PNL, extra="report_nets_after_route_only")
    else:
        cases.append(OrderedDict([("case", "report_nets_snapshot"), ("expected", "FAIL/PASS"),
                                  ("actual", "SKIP"), ("case_ok", None),
                                  ("reason", "snapshot or placement file not found")]))

    if route_only_text:
        variants = mutate_route_only(route_only_text)
        expectations = [
            ("mut_key_feedthrough", "FAIL", False),
            ("mut_endpoint_removed", "FAIL", False),
            ("mut_driver_swapped", "FAIL", False),
            ("mut_key_tile_empty_bridge", "FAIL", False),
            ("mut_functional_nonkey", "PASS", False),
            ("mut_functional_nonkey", "FAIL", True),
        ]
        for variant, expected, strict in expectations:
            text = variants[variant]
            design = parse_design_from_lines(io.StringIO(text), "pnl")
            design["path"] = "<synthetic:{}>".format(variant)
            design["sha256"] = hashlib.sha256(text.encode("utf-8")).hexdigest().upper()
            report = evaluate(design, load_baseline(baseline), strict)
            row = case_result(
                "{}{}".format(variant, "_strict" if strict else ""),
                expected,
                report,
            )
            row["input_path"] = "<synthetic:{}>".format(variant)
            row["input_sha256"] = design["sha256"]
            cases.append(row)

    empty = "Pnl Version: 2.0\ndesign empty;\n{\n}\n"
    design = parse_design_from_lines(io.StringIO(empty), "pnl")
    design["path"] = "<synthetic:no_reset_nets>"
    design["sha256"] = hashlib.sha256(empty.encode("utf-8")).hexdigest().upper()
    report = evaluate(design, load_baseline(baseline), False)
    cases.append(case_result("no_reset_nets", "FAIL", report))

    all_ok = all(row["case_ok"] for row in cases if row["case_ok"] is not None)
    receipt = OrderedDict()
    receipt["gate"] = GATE_NAME
    receipt["gate_version"] = GATE_VERSION
    receipt["kind"] = "self_test_and_negative_controls"
    receipt["result"] = "PASS" if all_ok else "FAIL"
    receipt["baseline"] = (
        {"path": DEFAULT_BASELINE, "sha256": sha256_file(DEFAULT_BASELINE)}
        if baseline else None
    )
    receipt["route_only_pnl"] = route_only
    receipt["cases"] = cases
    receipt["evidence"] = evidence
    receipt["limits"] = LIMITS + [
        "Synthetic mutations test the gate's parser/classifier, not any candidate bitstream.",
    ]
    receipt["script_sha256"] = sha256_file(os.path.abspath(__file__))
    write_report(receipt, output_path)
    print("SELFTEST", receipt["result"], "cases", len(cases))
    for row in cases:
        print(" ", row["case"], "expected", row["expected"], "actual", row["actual"],
              "ok" if row["case_ok"] else ("skip" if row["case_ok"] is None else "BAD"))
    return 0 if all_ok else 1


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Offline causal reset-branch gate (PNL / report_nets)."
    )
    parser.add_argument("--pnl", help="PNL or report_nets file (.gz accepted)")
    parser.add_argument("--baseline", default=DEFAULT_BASELINE,
                        help="baseline JSON (default: reset24_feedthrough_branch_review.json)")
    parser.add_argument("--out", default=None,
                        help="output JSON path; '-' prints to stdout")
    parser.add_argument("--section", default="first",
                        choices=["first", "last", "before", "after"],
                        help="report_nets occurrence selection (default first)")
    parser.add_argument("--placement", default=None,
                        help="PNL used only for instance/location data when input is report_nets")
    parser.add_argument("--strict-functional", action="store_true",
                        help="reject functional non-key bridges too")
    parser.add_argument("--target-net", default=None,
                        help="override the baseline target reset net")
    parser.add_argument("--self-test", action="store_true",
                        help="run built-in positive/negative controls")
    args = parser.parse_args(argv)

    if args.self_test:
        output = args.out or os.path.join(HERE, "selftest_receipt.json")
        return self_test(output)

    if not args.pnl:
        parser.error("--pnl is required unless --self-test is used")
    if not os.path.exists(args.pnl):
        parser.error("input not found: {}".format(args.pnl))

    report = run_gate(
        args.pnl,
        args.baseline,
        section=args.section,
        placement_path=args.placement,
        strict_functional=args.strict_functional,
        target_net_name=args.target_net,
    )
    output = args.out
    if output is None:
        stem, _ = os.path.splitext(args.pnl)
        output = stem + ".reset_gate.json"
    write_report(report, output)
    print("RESET_BRANCH_GATE", report["result"],
          "reset_nets", report["summary"]["reset_nets"],
          "fatal", report["summary"]["fatal_violations"],
          "warnings", report["summary"]["warnings"])
    for check in report["checks"]:
        print(" ", check["id"], check["status"])
    if output != "-":
        print("evidence", output)
    if report["result"] == "PASS":
        return 0
    if report["result"] == "INCOMPLETE":
        return 2
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
