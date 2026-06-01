---
name: vexplain
description: Generate documentation for any RTL module from Verilog source files
effort: medium
allowed-tools: Read, Write
---

# Verilog Reader

## Overview

This guide defines the workflow for generating documentation for a Verilog RTL module from its source files.

## Step 1 - Analyze the Design

Read the target Verilog source file and determine the function of the RTL module.

Use `.claude/skills/shared/CodingStyle.md` to correctly interpret signal names, bus interfaces, and FSM patterns found in the code. For example:
- Signal suffix `_ff` indicates a flip-flop or register.
- Signal prefix `s0_`, `s1_` indicates pipeline stage.
- Port prefix `s_` / `m_` / `b_` indicates slave / master / monitor bus interface.

If the module instantiates submodules, follow this order:

1. Check whether each submodule already has documentation.
2. If documentation exists, use it to understand the submodule behavior.
3. If documentation does not exist, read the submodule RTL code only as needed to understand the behavior of the target module.

After the analysis is complete, generate a new Markdown file according to the following output rules:

Output file rules:

- The output file must use the same base name as the Verilog file.
- The output file must use the `.md` extension.
- If the target file is under `./rtl`, place the output in `./doc/`.
- If the target file is under `./lib`, place the output in the same folder as the Verilog file.

## Required and Excluded Content

The generated documentation must follow the module documentation contract defined
in `.claude/skills/shared/ModuleDocContract.md`, including its Excluded Content
rules.

Populate every required section of that contract by reading the Verilog source:
extract the port table (name, direction, width, reset value) and parameters
directly from the module declaration, and derive reset behavior, timing
characteristics, and any FSM/algorithm from the implemented logic.
