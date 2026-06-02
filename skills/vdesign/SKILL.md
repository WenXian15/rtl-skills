---
name: vdesign
description: Generate a design proposal, documentation, and RTL backbone from a requirement file
model: opus
allowed-tools: Read, Write, Grep
---

# Verilog Designer

## Overview

This guide defines the workflow for generating a design proposal, documentation, and a skeleton RTL module from a Markdown requirement file.

The input is a `.md` requirement file that describes what the module should do, typically `./ddoc/<module>_req.md` produced by `varch`. The output is:

1. A proposal file with function description, architecture and algorithm if applicable
2. A design documentation file
3. A backbone Verilog file with `//@` direction comments, ready for implementation by `vfill`

`vdesign` runs once per **new submodule**. Reused `lib` modules have no `_req.md` (they are already designed and documented), so there is nothing here to drive — `vdesign` simply skips them; `varch` still instantiates them in the skeleton.

### Module Name Derivation

All output file names are derived from the **module name**, not the raw requirement file name. The module name is the requirement file base name with any trailing `_req` removed.

Example:

- requirement `./ddoc/foo_ctrl_req.md` → module name `foo_ctrl`

Use this module name consistently for the proposal, documentation, and RTL backbone file names below.

### Before You Start — Re-run Safety

`vdesign` overwrites three artifacts. Two of them carry hand-owned downstream content once the flow has progressed past `vfill`:

- `rtl/<module>.v` — after `vfill`, this holds the real implementation and **every `//@` marker has been converted away**. A blind re-generate destroys the implementation.
- `ddoc/<module>_proposal.md` — `vfill` appends design updates and debug notes here. A blind re-generate clobbers them.

So before writing anything, classify the current state of the backbone:

| State | How to detect | Action |
|-------|---------------|--------|
| **Fresh** | `rtl/<module>.v` does not exist | Generate all three outputs normally. |
| **Backbone only** | `rtl/<module>.v` exists and still contains `//@` markers, no real logic | Safe to regenerate — the requirement changed and nothing downstream depends on it yet. |
| **Filled** | `rtl/<module>.v` has no `//@` markers (the same marker `vflow` uses to detect completion, CodingStyle §18) / contains implemented logic, or the proposal carries vfill notes | **Stop and confirm with the user before overwriting.** Re-running discards `vfill`'s implementation and notes. The safe path is to re-run `vdesign` *before* `vfill`; after that, requirement changes must be reconciled into the filled RTL by hand. |

This mirrors how `varch` guards `<ip>_top.v` against clobbering integration edits.

## Step 1 - Read Requirements and Generate Proposal

Read the target requirement `.md` file and extract the design intent.

A `varch`-generated `_req.md` has **two parts** separated by the marker line
`<!-- functional-spec: hand-owned below this line -->`:

- **Structural section (above the marker)** — overview, parameters, and the port/interface table. This is the **authoritative interface contract**: `varch` already fixed these port and parameter names, widths, defaults, and directions and wired `<ip>_top.v` to them by name. Carry them through verbatim — **do not rename, re-width, re-default, or re-derive a port or parameter.** Renaming a port or parameter here breaks the skeleton wiring three phases later.
- **Hand-owned functional section (below the marker)** — `## Functional Description`. This is the real design intent the proposal and documentation must stay faithful to.

(If the requirement has no marker line — e.g. it was hand-written — treat the whole file as intent and take ports from whatever port table it provides.)

**If the design genuinely needs a port or parameter the requirement does not
list, that is an architecture change, not a local fix.** Do not invent it here —
adding a port that `<ip>_top.v` does not wire breaks integration. Stop and flag
the gap to the user so it can be resolved in `varch` (which updates the
architecture document, the `_req.md`, and the skeleton together), then re-run
`vdesign` against the corrected requirement.

Based on the requirements, generate a design proposal. The proposal must include:

- Functional description of the module, consistent with the requirement's functional section
- Port list with signal names, directions, and widths — **taken verbatim from the requirement's structural port table**
- Parameter list with names and defaults — **taken verbatim from the requirement's structural parameter table** (including `RS_LV` for a clocked module)
- Algorithm description, if applicable
- Module architecture description, if the design is large, complex, or algorithmically non-trivial
- Intended timing — latency from input to output, pipeline depth, and throughput, if applicable (the doc's mandatory Timing Characteristics section is derived from this; see Step 2)

Algorithm flow diagrams, Architecture diagrams, FSM state diagrams must be written in mermaid format, if applicable.

If the design is small or simple, the architecture description may be omitted.

## Step 2 - Generate Proposal and Documentation Files

Generate the following files:

### Proposal File

Create a new Markdown file in the `./ddoc` folder, alongside the requirement file.

Output file rules:

- Use the module name as the base name
- Append `_proposal` before the extension
- Use the `.md` extension

Example:

- requirement `foo_req.md` → `./ddoc/foo_proposal.md`

### Design Documentation File

Create a new Markdown file in the `./doc` folder.

Output file rules:

- Use the module name as the base name
- Use the `.md` extension

Example:

- requirement `foo_req.md` → `./doc/foo.md`

#### Required Content for the Design Documentation

The design documentation must follow the module documentation contract defined in
`.claude/skills/shared/ModuleDocContract.md`. Populate every required section of
that contract from the proposal and the requirement file.

The functional description must be consistent with the proposal and with the
requirement's hand-owned functional section. Because the RTL is not yet
implemented at this stage, derive the port table, reset values, and timing
characteristics from the proposal's port list and architecture; if a value is
not yet decided, state the intended value from the proposal rather than leaving
it blank. The reset section must reflect the project convention: synchronous
reset, `rst_n` compared against `RS_LV` (default active-low).

## Step 3 - Create Backbone RTL Module

Create a skeleton Verilog file in the `./rtl` folder.

Output file rules:

- Use the module name as the base name
- Use the `.v` extension

Example:

- requirement `foo_req.md` → `./rtl/foo.v`

This skill generates backbones for submodules only. The top-level integration skeleton `./rtl/<ip>_top.v` is owned by `varch`; do not create or overwrite it here.

### Backbone Structure

The backbone must be **style-compliant from the start** — `vfill` fills it in
place, so the scaffold must already match `.claude/skills/shared/CodingStyle.md`,
not just the empty-logic shape. It must include:

- `` `default_nettype none `` at the top and `` `default_nettype wire `` at the end (`CodingStyle §14`).
- Module declaration with all ports from the proposal, ANSI style, with `//!` Doxygen doc-comments on every port and parameter (`CodingStyle §1`, `§10`).
- `RS_LV` as the **last parameter** of the (clocked) module, default `0` (`CodingStyle §1`, `§12`).
- `//@` direction comments that guide `vfill` on what to implement in each section.
- Section dividers using the standard banner format, indented to body level (4 spaces) (`CodingStyle §4`).
- Empty logic bodies — no implementation.

Port and signal naming follows `CodingStyle §3` (do not re-derive a partial copy
of those rules here): `s_`/`m_`/`b_` interface prefixes, `_ff` for flip-flops,
`s0_`/`s1_` pipeline-stage prefixes, etc. Port names themselves come straight from
the requirement's structural port table (see Step 1).

Example backbone structure:

```verilog
`default_nettype none

module foo #(
    parameter DATA_W = 8,   //! data bus width
    parameter RS_LV  = 0    //! reset active level (0 = active-low)
) (
    input  wire              clk,      //! clock
    input  wire              rst_n,    //! reset (asserted when == RS_LV)
    input  wire [DATA_W-1:0] s_data,   //! input data
    input  wire              s_valid,  //! input data valid
    output reg  [DATA_W-1:0] m_data,   //! output data
    output reg               m_valid   //! output data valid
);

    //@ implement the input handshake logic here

    //==========================================================================
    // Stage 0 - Input Register
    //==========================================================================

    //@ register s_data and s_valid into s0_data_ff and s0_valid_ff

    //==========================================================================
    // Stage 1 - Output
    //==========================================================================

    //@ compute m_data from s0_data_ff and drive m_valid

endmodule

`default_nettype wire
```

The `//@` comments must be specific enough for `vfill` to implement the correct behavior without further design decisions. They must follow the marker grammar and lifecycle defined in `.claude/skills/shared/CodingStyle.md §18` — in particular, a marker must never contain Verilog code.

## Step 4 - Self-check the outputs

Before finishing, verify the three outputs agree with each other and with the
requirement. The interface is the contract `vfill` and `varch`'s skeleton build
against, so a mismatch here surfaces as a wiring or compile bug downstream. Walk
each port and parameter of the module and confirm:

| Check | Pass condition |
|-------|----------------|
| Ports & params match the requirement | Every port and parameter in the backbone header matches the requirement's structural tables by name, width/default, and direction. None added, dropped, renamed, re-widthed, or re-defaulted (a needed-but-missing one is an architecture change — see Step 1). |
| Proposal agrees | The proposal's port and parameter lists are identical to the backbone header. |
| Doc agrees | The doc's Ports table (`ModuleDocContract §3`) and Parameters table (`§2`) list the same ports and parameters with the same widths, directions, and defaults. |
| Conventions hold | `clk`, `rst_n` are the first two ports; `RS_LV` is the last parameter (default 0) for a clocked module; reset is described as synchronous against `RS_LV`. |
| Markers legal | Every `//@` in the backbone is plain-English intent with no Verilog code, one direction per line (`CodingStyle §18`). |
| Functional fidelity | The doc and proposal functional descriptions are consistent with the requirement's hand-owned `## Functional Description`. |

If any check fails, fix the offending artifact and re-run the check — do not leave
the proposal, the documentation, and the backbone in disagreement.
