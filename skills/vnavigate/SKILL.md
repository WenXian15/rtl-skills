---
name: vnavigate
description: Systematically understand an unfamiliar RTL / VLSI / ASIC / FPGA codebase the way an experienced chip designer does — map the module hierarchy and structural skeleton (clocks, resets, interfaces, parameters, generate blocks), trace one transaction end to end, find the key control structures (FSMs, arbiters, FIFOs, credit/flow control), and mine constraints and waivers (SDC, CDC/RDC, lint, timing reports) for hints about risky areas. Use this skill whenever the user shares or points at Verilog, SystemVerilog, or VHDL source, filelists, SDC files, or tool reports and wants to understand, onboard onto, review, document, or debug the design — even if they just say "explain this RTL", "where do I start with this repo", "what does this block do", "walk me through this design", or "help me ramp up on this chip".
---

# RTL Codebase Orientation

Experienced VLSI engineers do not read a new design line by line. They build a model from the outside in — skeleton first, then one real transaction, then the control logic, then the designers' own warnings in the constraints — and only go deep where it matters. This skill turns that habit into a repeatable workflow.

Work through the four phases in order. Each phase produces notes that feed the final orientation report. If the user only asks about one aspect (e.g. "what are the clock domains?"), run the relevant phase and skip the report template.

## Phase 0: Inventory the files

Before analysing, find out what you actually have:

- RTL sources: `*.v`, `*.sv`, `*.svh`, `*.vh`, `*.vhd`, `*.vhdl`
- Filelists (`*.f`, `*.flist`) — these define what is really compiled, in what order, with which `+define+` and `+incdir+`. Trust the filelist over the directory tree; directories often contain dead or alternate versions.
- Constraints and reports: `*.sdc`, `*.xdc`, `*.tcl`, CDC/RDC/lint waiver files, timing/synthesis/CDC reports.
- Testbench code — useful for later phases, but keep it separate from the design hierarchy.

Run the bundled scanner to get a fast first pass (it is regex-based and heuristic, so verify anything surprising by reading the code):

```bash
python scripts/rtl_scan.py <path-to-repo-or-files> [--top <module>] [--json out.json]
```

It reports module definitions, the instantiation tree, likely top modules, clock/reset signals used in sequential blocks, clock-crossing hints, parameters, generate blocks, FSM candidates, FIFO/arbiter candidates, and bus-protocol port prefixes. It handles Verilog/SystemVerilog only; for VHDL, do the equivalent with `grep` (`entity`, `port map`, `rising_edge`, `generic`, `type .* is (`).

## Phase 1: Map the hierarchy and the skeleton

Goal: a one-page picture of what blocks exist and how they connect.

1. **Identify the top.** Modules defined but never instantiated are top candidates. Testbench tops, wrappers, and unused modules will also show up — use the filelist and naming to pick the real design top, and ask the user if it is ambiguous.
2. **Build the hierarchy tree** two or three levels deep. Classify each major block as *custom logic*, *third-party / vendor IP* (look for vendor prefixes, encrypted or `protected` regions, black boxes), *memory wrapper* (`*_ram`, `*_mem`, `sram`, `rf_`), or *glue/infrastructure* (sync cells, clock gates, reset controllers).
3. **Clocks and resets** — this reveals more about the architecture than almost anything else:
   - List every clock that drives `always_ff` / `always @(posedge ...)` blocks, and where each is generated (ports, PLL/MMCM instances, dividers, clock muxes, ICG/clock-gate cells).
   - List resets: synchronous vs asynchronous, active level, and where they are synchronised (look for two-flop reset synchronisers).
   - Group modules by clock domain. Any module using more than one clock is a clock-domain-crossing site and deserves attention later.
4. **External interfaces.** Recognise protocols from port names (`awvalid/arready` → AXI, `psel/penable` → APB, `htrans/hready` → AHB, `tvalid/tready` → AXI-Stream, `dfi_` → DDR PHY, etc.). For each boundary, note the protocol and direction — the protocol spec tells you the expected behaviour at that edge without reading the logic. Flag custom valid/ready or req/ack handshakes, since those have no external spec.
5. **Parameters and generate blocks.** Record top-level parameters and their defaults, and every `generate` / `for` / `if` generate region. Note which configuration the filelist or top-level actually selects — generate blocks can make large chunks of code dead for a given build, or replicate a block N times.

Produce a hierarchy diagram (indented tree or Mermaid `graph TD`) annotated with clock domains and interface protocols.

## Phase 2: Follow one transaction end to end

Goal: understand the main datapath by tracing a single representative operation, rather than reading every block.

1. **Pick the transaction.** Choose the simplest operation that exercises the core function: a register write over APB, one packet through the datapath, one memory read. Ask the user if they have a preferred one; otherwise propose one and say why.
2. **Trace it from entry port to exit** (or to its side effect, like a register update). At each hop record: module, signal names carrying it, any FIFO it enters, any FSM state it causes, any arbitration point, any clock-domain crossing, and the cycle latency if you can infer it.
3. **Use simulation if available.** If the user can run simulation, suggest the specific signals to add to the waveform viewer for this transaction, and a smoke test that exercises it. A waveform confirms in minutes what static reading only guesses. If you can't simulate, state clearly which parts of the trace are inferred from the code.

Present the trace as a numbered hop-by-hop path, optionally as a Mermaid `sequenceDiagram`.

## Phase 3: Find the key control structures

Goal: locate the logic where complexity and bugs concentrate, now that the datapath is roughly clear.

- **State machines**: `typedef enum` state types, `state`/`next_state` (or `cs`/`ns`) register pairs, `case (state)` blocks. For each important FSM, extract the states and transitions and draw a Mermaid `stateDiagram-v2`. Note unreachable states, missing `default` branches, and states with no exit.
- **Arbiters**: round-robin pointers, priority encoders, `grant`/`req` vectors. Note the policy (fixed priority vs round-robin vs weighted) and starvation risks.
- **FIFOs and buffers**: write/read pointers, `full`/`empty`/`almost_full`, depth parameters. Distinguish synchronous FIFOs from asynchronous (dual-clock, Gray-coded pointers) ones — the latter are CDC points.
- **Credit / flow control**: credit counters, backpressure (`ready` deasserting), skid buffers. Check where backpressure originates and how far it propagates.
- **Counters and timers** that gate behaviour (timeouts, watchdogs, retry counters).

Rank these by how central they are to the traced transaction and how risky they look.

## Phase 4: Read the constraints and reports

Goal: learn what the original designers already knew was tricky.

- **SDC / XDC**: `create_clock` and `create_generated_clock` (confirm the clock list from Phase 1 and find any you missed), `set_clock_groups -asynchronous` (declared async domains), `set_false_path`, `set_multicycle_path`, `set_max_delay -datapath_only`. Every false path and multicycle path is a claim by the designer that some logic does not need normal timing — note where they cluster.
- **CDC / RDC waivers**: a pile of waivers around one block is a strong signal to look carefully there. Check whether each waived crossing actually has a synchroniser, Gray-coded bus, or handshake.
- **Lint waivers**: note recurring categories (width mismatch, latch inference, combinational loops, multiply-driven nets).
- **Synthesis / timing reports** if provided: worst negative slack paths and which blocks they pass through, inferred latches, removed or unconnected logic.

Cross-reference these against Phases 1–3. Disagreements are the most valuable findings — e.g. a crossing that the RTL scan found but the SDC never declares, or an async FIFO without a matching clock group.

## Output: the orientation report

When the user wants a full orientation, use this structure. Keep it skimmable and concrete — signal and module names, not generalities.

```markdown
# <Design name> — Orientation Notes

## Summary
Two or three sentences: what the design does, its top module, main clocks, main interfaces.

## Hierarchy
Annotated tree or Mermaid diagram (block type, clock domain, interface protocol).

## Clocks and resets
Table: clock | source | frequency (if known) | modules | notes.
Reset scheme and synchronisers.

## External interfaces
Table: port group | protocol | direction | notes.

## Configuration
Key parameters, defaults, and what the generate blocks build.

## Traced transaction: <name>
Numbered hop-by-hop path with modules, signals, FIFOs, FSM states, CDCs, latency.

## Key control structures
Each FSM / arbiter / FIFO / credit loop, with location, purpose, and a diagram for the important FSMs.

## Constraints and waivers
What the SDC and waivers reveal; clusters of exceptions.

## Risk hotspots and open questions
Ranked list of where to look carefully, and questions to ask the design owner.

## Suggested next steps
Specific signals to probe, tests to run, or a small change to make to validate the model.
```

## Guidance

- **Say what is inferred versus confirmed.** Regex scans and static reading miss macros, `ifdef` variants, and tool-specific behaviour. Mark uncertain findings and suggest how to confirm them (simulation, elaboration log, hierarchy browser in Verdi or Questa).
- **Respect `ifdef`s and defines.** Check which macros the filelist sets before concluding that code is live.
- **Scale to the codebase.** For a single module, compress the phases into a short walkthrough. For a large SoC, do Phase 1 at the top level, then ask the user which subsystem to go deeper on rather than tracing everything.
- **Prefer diagrams for structure.** Hierarchy, FSMs, and transaction paths are much easier to grasp as Mermaid diagrams than as prose.
- **End with open questions.** The best orientation notes include a short list of questions for the original designer — they save hours.
