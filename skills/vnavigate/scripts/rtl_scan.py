#!/usr/bin/env python3
"""Heuristic first-pass scanner for Verilog/SystemVerilog codebases.

Reports modules, instantiation hierarchy, top candidates, clocks/resets,
multi-clock modules, parameters, generate blocks, FSM/FIFO/arbiter
candidates, and bus-protocol port groups.

Regex-based: it does not elaborate, resolve macros, or evaluate ifdefs.
Treat its output as leads to verify, not ground truth.

Usage:
    python rtl_scan.py <path> [<path> ...] [--top MODULE] [--depth N] [--json OUT]
    python rtl_scan.py -f design.f
"""
import argparse
import json
import os
import re
import sys
from collections import defaultdict

RTL_EXT = (".v", ".sv", ".vh", ".svh")

KEYWORDS = {
    "module", "endmodule", "input", "output", "inout", "wire", "reg", "logic",
    "assign", "always", "always_ff", "always_comb", "always_latch", "initial",
    "begin", "end", "if", "else", "case", "casez", "casex", "endcase", "for",
    "generate", "endgenerate", "genvar", "function", "endfunction", "task",
    "endtask", "localparam", "parameter", "typedef", "enum", "struct", "return",
    "integer", "bit", "byte", "int", "import", "export", "package", "endpackage",
    "interface", "endinterface", "modport", "default", "unique", "priority",
    "while", "repeat", "forever", "foreach", "string", "class", "endclass",
    "virtual", "property", "endproperty", "assert", "assume", "cover", "sequence",
    "endsequence", "bind", "covergroup", "endgroup", "real", "time", "event",
    "posedge", "negedge", "or", "and", "not", "buf", "supply0", "supply1",
    "tri", "wand", "wor", "signed", "unsigned", "var", "automatic", "static",
    "const", "ref", "return", "fork", "join", "join_any", "join_none", "wait",
}

PROTOCOLS = [
    ("AXI4 (write addr)", re.compile(r"\w*awvalid\b|\w*awready\b", re.I)),
    ("AXI4 (read addr)", re.compile(r"\w*arvalid\b|\w*arready\b", re.I)),
    ("AXI-Stream", re.compile(r"\w*tvalid\b|\w*tready\b", re.I)),
    ("APB", re.compile(r"\w*psel\w*\b|\w*penable\b", re.I)),
    ("AHB", re.compile(r"\w*htrans\b|\w*hready\w*\b", re.I)),
    ("Wishbone", re.compile(r"\bwb_\w*(cyc|stb|ack)\b|\b(cyc|stb)_[io]\b", re.I)),
    ("DFI / DDR PHY", re.compile(r"\bdfi_\w+", re.I)),
    ("PCIe", re.compile(r"\bpcie\w*|\btlp\w*", re.I)),
    ("JTAG", re.compile(r"\btck\b|\btms\b|\btdi\b|\btdo\b", re.I)),
    ("valid/ready handshake", re.compile(r"\w*_valid\b|\w*_ready\b", re.I)),
    ("req/ack handshake", re.compile(r"\w*_req\b|\w*_ack\b", re.I)),
]


def strip_comments(text):
    text = re.sub(r"/\*.*?\*/", lambda m: "\n" * m.group(0).count("\n"), text, flags=re.S)
    text = re.sub(r"//[^\n]*", "", text)
    return text


def read_filelist(path, seen=None):
    seen = seen or set()
    files = []
    base = os.path.dirname(os.path.abspath(path))
    for raw in open(path, errors="replace"):
        line = raw.split("//")[0].strip()
        if not line or line.startswith("#") or line.startswith("+"):
            continue
        line = os.path.expandvars(line)
        if line.startswith("-f ") or line.startswith("-F "):
            sub = line[3:].strip()
            sub = sub if os.path.isabs(sub) else os.path.join(base, sub)
            if sub not in seen:
                seen.add(sub)
                files += read_filelist(sub, seen)
            continue
        if line.startswith("-"):
            continue
        p = line if os.path.isabs(line) else os.path.join(base, line)
        if p.endswith(RTL_EXT):
            files.append(p)
    return files


def collect_files(paths):
    files = []
    for p in paths:
        if os.path.isdir(p):
            for root, _, names in os.walk(p):
                for n in sorted(names):
                    if n.endswith(RTL_EXT):
                        files.append(os.path.join(root, n))
        elif p.endswith((".f", ".flist")):
            files += read_filelist(p)
        elif p.endswith(RTL_EXT):
            files.append(p)
    return files


MODULE_RE = re.compile(r"^\s*module\s+(?:automatic\s+|static\s+)?(\w+)", re.M)
ENDMODULE_RE = re.compile(r"\bendmodule\b")
INST_RE = re.compile(
    r"^\s*(\w+)\s*(?:#\s*\((?:[^()]|\([^()]*\))*\)\s*)?(\w+)\s*(?:\[[^\]]*\]\s*)?\(",
    re.M | re.S,
)
SEQ_RE = re.compile(r"always(?:_ff)?\s*@\s*\(([^)]*)\)")
EDGE_RE = re.compile(r"(posedge|negedge)\s+([\w.\[\]]+)")
PARAM_RE = re.compile(r"\b(parameter|localparam)\b\s*(?:\w+\s+)?(?:\[[^\]]*\]\s*)?(\w+)\s*=\s*([^,;)]+)")
GEN_RE = re.compile(r"\bgenerate\b|\bfor\s*\(\s*genvar\b|\bif\s*\([^)]*\)\s*begin\s*:\s*\w+")
ENUM_RE = re.compile(r"typedef\s+enum[^{]*\{([^}]*)\}\s*(\w+)", re.S)
STATE_REG_RE = re.compile(r"\b(\w*(?:state|_cs|_ns|_st)\w*)\b", re.I)
CASE_RE = re.compile(r"\bcase[zx]?\s*\(\s*(\w+)\s*\)")
PORT_RE = re.compile(r"\b(input|output|inout)\b\s*(?:wire|reg|logic|var)?\s*(?:signed\s*)?(?:\[[^\]]*\]\s*)*(\w+)")
FIFO_HINT = re.compile(r"\b(\w*(?:wr_ptr|rd_ptr|wptr|rptr|full|empty|almost_full|almost_empty)\w*)\b", re.I)
GRAY_HINT = re.compile(r"\b\w*gray\w*\b", re.I)
ARB_HINT = re.compile(r"\b(\w*(?:grant|gnt|arb|rr_ptr|priority)\w*)\b", re.I)
CREDIT_HINT = re.compile(r"\b(\w*credit\w*)\b", re.I)
SYNC_HINT = re.compile(r"\b\w*(?:sync|synchronizer|cdc|_meta|_ff[12])\w*\b", re.I)
CLKGATE_HINT = re.compile(r"\b\w*(?:icg|clk_gate|clock_gate|cg_cell|latch_gate)\w*\b", re.I)
PROTECT_HINT = re.compile(r"`protect|pragma\s+protect", re.I)
VENDOR_NAME = re.compile(r"^(?:DW_|DW0\d|xpm_|altera_|altsyncram|MMCM|PLLE|BUFG|IBUF|OBUF|sky130_|tsmc|gf\d+|sc\d*_)", re.I)


def is_reset(name):
    return bool(re.search(r"rst|reset|clr|resetn|rstn", name, re.I))


def analyse(files):
    modules = {}
    for f in files:
        try:
            text = strip_comments(open(f, errors="replace").read())
        except OSError as e:
            print(f"warn: cannot read {f}: {e}", file=sys.stderr)
            continue
        starts = [(m.start(), m.group(1)) for m in MODULE_RE.finditer(text)]
        for i, (pos, name) in enumerate(starts):
            end_m = ENDMODULE_RE.search(text, pos)
            end = end_m.end() if end_m else (starts[i + 1][0] if i + 1 < len(starts) else len(text))
            body = text[pos:end]
            modules[name] = parse_module(name, body, f)
    return modules


def parse_module(name, body, path):
    info = {"file": path, "instances": [], "clocks": set(), "resets": set(),
            "params": [], "generate_blocks": 0, "fsm": [], "fifo_hints": set(),
            "gray": False, "arb_hints": set(), "credit_hints": set(),
            "sync_hints": set(), "clkgate_hints": set(), "vendor": False,
            "ports": [], "protocols": set()}

    for m in INST_RE.finditer(body):
        mod, inst = m.group(1), m.group(2)
        if mod in KEYWORDS or inst in KEYWORDS or mod == name:
            continue
        info["instances"].append((mod, inst))

    for m in SEQ_RE.finditer(body):
        for edge, sig in EDGE_RE.findall(m.group(1)):
            (info["resets"] if is_reset(sig) else info["clocks"]).add(sig)
    # synchronous resets used inside sequential blocks
    for sig in re.findall(r"if\s*\(\s*!?\s*(\w*(?:rst|reset)\w*)\s*\)", body, re.I):
        info["resets"].add(sig)

    for kind, pname, val in PARAM_RE.findall(body):
        info["params"].append({"kind": kind, "name": pname, "default": val.strip()})

    info["generate_blocks"] = len(GEN_RE.findall(body))

    enum_states = {}
    for states, tname in ENUM_RE.findall(body):
        labels = [s.split("=")[0].strip() for s in states.split(",") if s.strip()]
        enum_states[tname] = labels
    case_sigs = set(CASE_RE.findall(body))
    state_like = {s for s in case_sigs if STATE_REG_RE.fullmatch(s)}
    for tname, labels in enum_states.items():
        if re.search(r"state|st_t|fsm", tname, re.I) or any(re.search(r"idle|wait|done|busy", l, re.I) for l in labels):
            info["fsm"].append({"type": tname, "states": labels})
    if not info["fsm"]:
        for s in sorted(state_like):
            info["fsm"].append({"case_on": s})

    info["fifo_hints"] = set(FIFO_HINT.findall(body))
    info["gray"] = bool(GRAY_HINT.search(body))
    info["arb_hints"] = set(ARB_HINT.findall(body))
    info["credit_hints"] = set(CREDIT_HINT.findall(body))
    info["sync_hints"] = set(SYNC_HINT.findall(body)) | ({name} if SYNC_HINT.fullmatch(name) else set())
    info["clkgate_hints"] = set(CLKGATE_HINT.findall(body))
    info["vendor"] = bool(PROTECT_HINT.search(body) or VENDOR_NAME.search(name))

    for d, p in PORT_RE.findall(body):
        info["ports"].append((d, p))
    port_names = " ".join(p for _, p in info["ports"])
    for label, rx in PROTOCOLS:
        if rx.search(port_names):
            info["protocols"].add(label)
    # Collapse generic handshakes when a named protocol was found
    named = {p for p in info["protocols"] if "handshake" not in p}
    if named:
        info["protocols"] -= {"valid/ready handshake"} if any(x.startswith(("AXI", "AXI-Stream")) for x in named) else set()
    return info


def classify(name, info):
    n = name.lower()
    if info["vendor"]:
        return "vendor/IP"
    if re.search(r"ram|mem|sram|rf_|regfile|rom", n):
        return "memory"
    if re.search(r"sync|cdc|icg|clk_gate|rst_ctrl|reset", n):
        return "infra"
    if re.search(r"^tb_|_tb$|testbench|^test_", n):
        return "testbench"
    return "custom"


def describe(modules, mod):
    info = modules.get(mod)
    if not info:
        kind = "vendor IP/cell" if VENDOR_NAME.search(mod) else "external IP/cell/blackbox"
        return f"{mod} [UNDEFINED: {kind}]"
    extra = []
    if info["clocks"]:
        extra.append("clk:" + ",".join(sorted(info["clocks"])))
    if info["protocols"]:
        extra.append("if:" + ",".join(sorted(info["protocols"])))
    if len(info["clocks"]) > 1:
        extra.append("MULTI-CLOCK")
    return f"{mod} [{classify(mod, info)}]" + (f"  ({'; '.join(extra)})" if extra else "")


def print_tree(modules, top, depth, indent=0, path=()):
    if indent == 0:
        print(describe(modules, top))
    info = modules.get(top)
    if not info or indent >= depth or top in path:
        return
    groups = defaultdict(list)
    for mod, inst in info["instances"]:
        groups[mod].append(inst)
    for mod, insts in groups.items():
        label = insts[0] if len(insts) == 1 else f"{insts[0]} (x{len(insts)})"
        print("  " * (indent + 1) + f"{label}: {describe(modules, mod)}")
        print_tree(modules, mod, depth, indent + 1, path + (top,))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("paths", nargs="*")
    ap.add_argument("-f", dest="filelist", action="append", default=[])
    ap.add_argument("--top")
    ap.add_argument("--depth", type=int, default=3)
    ap.add_argument("--json")
    a = ap.parse_args()

    files = collect_files(a.paths + a.filelist)
    if not files:
        sys.exit("No RTL files found.")
    modules = analyse(files)
    instantiated = {m for info in modules.values() for m, _ in info["instances"]}
    tops = sorted(m for m in modules if m not in instantiated)
    undefined = sorted(instantiated - set(modules))

    print(f"== Scanned {len(files)} files, {len(modules)} modules ==\n")
    print("Top candidates (defined, never instantiated):")
    for t in tops:
        print(f"  {t} [{classify(t, modules[t])}]  {modules[t]['file']}")
    if undefined:
        print("\nInstantiated but not defined (IP, cells, blackboxes, or missing files):")
        print("  " + ", ".join(undefined))

    roots = [a.top] if a.top else [t for t in tops if classify(t, modules[t]) != "testbench"] or tops
    print("\n== Hierarchy ==")
    for r in roots:
        print_tree(modules, r, a.depth)
        print()

    print("== Clocks and resets ==")
    clk_mods, rst_mods = defaultdict(list), defaultdict(list)
    for n, i in modules.items():
        for c in i["clocks"]:
            clk_mods[c].append(n)
        for r in i["resets"]:
            rst_mods[r].append(n)
    for c, ms in sorted(clk_mods.items()):
        print(f"  clock {c}: {', '.join(sorted(ms))}")
    for r, ms in sorted(rst_mods.items()):
        print(f"  reset {r}: {', '.join(sorted(ms))}")
    multi = [n for n, i in modules.items() if len(i["clocks"]) > 1]
    if multi:
        print("  Multi-clock modules (likely CDC sites): " + ", ".join(sorted(multi)))
    syncs = sorted({n for n, i in modules.items() if i["sync_hints"]})
    if syncs:
        print("  Modules with synchroniser/CDC naming: " + ", ".join(syncs))
    cgs = sorted({n for n, i in modules.items() if i["clkgate_hints"]})
    if cgs:
        print("  Modules with clock-gating hints: " + ", ".join(cgs))

    print("\n== Interfaces (by port naming) ==")
    for n, i in sorted(modules.items()):
        if i["protocols"]:
            print(f"  {n}: {', '.join(sorted(i['protocols']))}")

    print("\n== Parameters and generate blocks ==")
    for n, i in sorted(modules.items()):
        ps = [p for p in i["params"] if p["kind"] == "parameter"]
        if ps or i["generate_blocks"]:
            pstr = ", ".join(f"{p['name']}={p['default']}" for p in ps[:8])
            more = f" (+{len(ps)-8})" if len(ps) > 8 else ""
            print(f"  {n}: params[{pstr}{more}] generate_regions={i['generate_blocks']}")

    print("\n== Control-structure candidates ==")
    for n, i in sorted(modules.items()):
        bits = []
        for fsm in i["fsm"]:
            if "states" in fsm:
                bits.append(f"FSM enum {fsm['type']}: {', '.join(fsm['states'][:10])}")
            else:
                bits.append(f"FSM case on {fsm['case_on']}")
        if i["fifo_hints"]:
            bits.append(("ASYNC " if i["gray"] else "") + "FIFO signals: " + ", ".join(sorted(i["fifo_hints"])[:6]))
        if i["arb_hints"]:
            bits.append("arbiter signals: " + ", ".join(sorted(i["arb_hints"])[:6]))
        if i["credit_hints"]:
            bits.append("credit signals: " + ", ".join(sorted(i["credit_hints"])[:6]))
        if bits:
            print(f"  {n}:")
            for b in bits:
                print(f"    - {b}")

    if a.json:
        out = {n: {k: (sorted(v) if isinstance(v, set) else v) for k, v in i.items()} for n, i in modules.items()}
        json.dump({"tops": tops, "undefined": undefined, "modules": out}, open(a.json, "w"), indent=2)
        print(f"\nJSON written to {a.json}")


if __name__ == "__main__":
    main()
