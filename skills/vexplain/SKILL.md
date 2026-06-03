---
name: vexplain
description: Generate documentation for any RTL module from Verilog source files
effort: medium
model: opus
allowed-tools: Read, Write, Grep, Glob
---

# Verilog Reader

## Overview

This guide defines the workflow for generating documentation for a Verilog RTL
module from its source files. The RTL is the ground truth: the generated document
describes the module **as implemented**, accurately enough that another skill can
instantiate, drive, and reason about it without reading the source (see
`.claude/skills/shared/ModuleDocContract.md`).

### Target Resolution & Name Derivation

The input is a single target module, identified by a file path or a module name.
Resolve it to one top-level Verilog source file:

- A path under `./rtl` or `./lib` is the target directly.
- A bare module name resolves to `./rtl/<module>.v`, or to a `./lib` module —
  either `./lib/<module>.v` (single-file) or `./lib/<module>/<module>.v`
  (multi-file, where the top file shares the module's name).

The **module name** is the source file's base name. All output names derive from
it, not from any partial path. Other `.v` files inside a multi-file `./lib/<mod>/`
folder are submodules, not separate targets (see analysis order below).

If a single `.v` file declares more than one module, the target is the module
whose name matches the file base name; the others are treated as submodules.

### Before You Start — Re-run Safety

`vexplain` overwrites the module document. Two cases need care:

- **Existing doc — confirm first.** An `rtl/` `doc/<module>.md` may be a
  pre-implementation `vdesign` draft, and a `lib/<module>.md` is the canonical
  reference for a reusable module. Generating a *missing* doc is the intended
  use; overwriting an *existing* one is destructive — confirm with the user
  first, then regenerate wholesale from the RTL (now ground truth).
- **Unfilled backbone — stop.** If the target RTL still contains `//@` markers
  (`vflow`'s incompleteness marker, `CodingStyle §18`), it is a `vdesign`
  backbone that `vfill` has not implemented. Stop and report; do not document
  empty logic. Pre-implementation intent is `vdesign`'s job.

## Step 1 - Analyze the Design

Read the target Verilog source file and determine the function of the RTL module.

Use `.claude/skills/shared/CodingStyle.md` to interpret signal names, bus interface prefixes, and FSM patterns in the code.

If the module instantiates submodules, follow this order:

1. Check whether each submodule already has documentation.
2. If documentation exists, use it to understand the submodule behavior.
3. If documentation does not exist, read the submodule RTL code only as needed to understand the behavior of the target module.

Document only the target module. Do not duplicate documentation for submodules
that are documented elsewhere — link to their `<module>.md` instead
(`ModuleDocContract` Excluded Content).

After the analysis is complete, generate a new Markdown file according to the following output rules:

Output file rules:

- The output file must use the same base name as the Verilog file (the module name).
- The output file must use the `.md` extension.
- If the target file is under `./rtl`, place the output in `./doc/`.
- If the target file is under `./lib`, place the output in the same folder as the Verilog file.

## Step 2 - Required and Excluded Content

The generated documentation must follow the module documentation contract defined
in `.claude/skills/shared/ModuleDocContract.md`, including its Excluded Content
rules.

Populate every required section of that contract by reading the Verilog source:
extract the port table (name, direction, width, reset value) and parameters
directly from the module declaration, and derive reset behavior, timing
characteristics, and any FSM/algorithm from the implemented logic.

## Step 3 - Self-check the Document

Before finishing, verify the document is an instantiation-accurate contract for
the RTL — downstream skills drive the module from it without re-reading the
source. Walk each port and parameter and confirm:

| Check | Pass condition |
|-------|----------------|
| Ports complete & exact | Every port in the module declaration appears in the Ports table with matching name, direction, and width; none added, dropped, renamed, or re-widthed (`ModuleDocContract §3`). |
| Parameters complete & exact | Every parameter appears in the Parameters table with its actual default and a legal range; section omitted only if the module has none (`§2`). |
| Reset values consistent | Each output's Reset Value column agrees with the reset logic in the RTL and with the Reset Behavior section (`§3`, `§5`). |
| Reset convention | Reset is described as synchronous, active level stated against `RS_LV` where applicable (`§5`). |
| Timing derived from RTL | Latency, pipeline depth, and throughput match the implemented register stages, not assumptions (`§6`). |
| Submodules linked, not duplicated | Documented submodules are referenced by link; none re-documented inline (Excluded Content). |
| No excluded content | No line-by-line code walkthrough or implementation internals (Excluded Content). |

If any check fails, fix the document and re-run the check — do not leave the doc
disagreeing with the RTL it describes.
