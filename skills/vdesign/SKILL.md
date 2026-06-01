---
name: vdesign
description: Generate a design proposal, documentation, and RTL backbone from a requirement file
---

# Verilog Designer

## Overview

This guide defines the workflow for generating a design proposal, documentation, and a skeleton RTL module from a Markdown requirement file.

The input is a `.md` requirement file that describes what the module should do, typically `./ddoc/<module>_req.md` produced by `varch`. The output is:

1. A proposal file with function description, architecture and algorithm if applicable
2. A design documentation file
3. A backbone Verilog file with `//@` direction comments, ready for implementation by `vfill`

### Module Name Derivation

All output file names are derived from the **module name**, not the raw requirement file name. The module name is the requirement file base name with any trailing `_req` removed.

Example:

- requirement `./ddoc/foo_ctrl_req.md` → module name `foo_ctrl`

Use this module name consistently for the proposal, documentation, and RTL backbone file names below.

## Step 1 - Read Requirements and Generate Proposal

Read the target requirement `.md` file and extract the design intent.

Based on the requirements, generate a design proposal. The proposal must include:

- Functional description of the module
- Port list with signal names, directions, and widths
- Algorithm description, if applicable
- Module architecture description, if the design is large, complex, or algorithmically non-trivial

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

## Required Content for the Design Documentation

The design documentation must follow the module documentation contract defined in
`.claude/skills/shared/ModuleDocContract.md`. Populate every required section of
that contract from the proposal and the requirement file.

The functional description must be consistent with the proposal. Because the RTL
is not yet implemented at this stage, derive the port table, reset values, and
timing characteristics from the proposal's port list and architecture; if a value
is not yet decided, state the intended value from the proposal rather than leaving
it blank.

## Step 3 - Create Backbone RTL Module

Create a skeleton Verilog file in the `./rtl` folder.

Output file rules:

- Use the module name as the base name
- Use the `.v` extension

Example:

- requirement `foo_req.md` → `./rtl/foo.v`

This skill generates backbones for submodules only. The top-level integration skeleton `./rtl/<ip>_top.v` is owned by `varch`; do not create or overwrite it here.

### Backbone Structure

The backbone must include:

- Module declaration with all ports from the proposal
- `//@` direction comments that guide `vfill` on what to implement in each section
- Section dividers using the standard comment block format
- Empty logic bodies — no implementation

Port signal names must follow the naming conventions in the project coding style:
- Use `s_` prefix for slave interfaces, `m_` prefix for master interfaces, `b_` prefix for monitor interfaces
- Use `_ff` suffix for signals intended as flip-flops
- Use `s0_`, `s1_` prefixes for pipeline stage signals

Example backbone structure:

```verilog
module foo #(
    parameter DATA_W = 8
) (
    input  wire              clk,
    input  wire              rst_n,
    input  wire [DATA_W-1:0] s_data,
    input  wire              s_valid,
    output reg  [DATA_W-1:0] m_data,
    output reg               m_valid
);

//@ implement the input handshake logic here

//==============================================================================
// Stage 0 - Input Register
//==============================================================================

//@ register s_data and s_valid into s0_data_ff and s0_valid_ff

//==============================================================================
// Stage 1 - Output
//==============================================================================

//@ compute m_data from s0_data_ff and drive m_valid

endmodule
```

The `//@` comments must be specific enough for `vfill` to implement the correct behavior without further design decisions. They must follow the marker grammar and lifecycle defined in `.claude/skills/shared/CodingStyle.md` — in particular, a marker must never contain Verilog code.
