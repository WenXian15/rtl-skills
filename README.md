# rtl-skills

A collection of [Claude Code](https://claude.com/claude-code) **skills** and **agents** that automate a full RTL/Verilog design flow — from a one-page IP requirement all the way to synthesized, tested, and documented hardware.

Drop these into a Verilog project and Claude can architect an IP, write the RTL, lint and simulate it, build a self-checking testbench, run regressions, debug failures, synthesize with Vivado, and produce documentation — each step driven by a focused, reviewable skill.

## What's in here

| Path | Contents |
|------|----------|
| `skills/` | One folder per skill, each a `SKILL.md` defining the workflow, inputs, and outputs |
| `agents/` | Agent definitions (`*.yaml`) that bundle skills into roles with a model and turn budget |
| `skills/shared/` | Cross-skill contracts: coding style, module-doc format, hierarchy filelist rules |
| `CLAUDE.md` | Project instructions describing the directory layout and conventions a consuming project should follow |

## The design flow

```
ip_req.md
  │
  ├─[varch]────► ddoc/<submodule>_req.md   (one per submodule) + rtl/<ip>_top.v skeleton
  ├─[vdesign]──► rtl/<module>.v backbone + ddoc/<module>_proposal.md + doc/<module>.md
  ├─[vfill]────► rtl/<module>.v full implementation + tb/<module>/ (lint + sim)
  ├─[vflow]────► flow_status.md            (live phase-completion snapshot, orchestration)
  ├─[vsynth]───► synth/<module>/           (Vivado: utilization, Fmax, power)
  ├─[vtestgen]─► tb/<ip>/                   (CPU-bus bench project + self-checking testcases)
  ├─[vtestrun]─► issue/<ip>/               (regression results + per-failure reports)
  ├─[vdebug]───► issue/<ip>/debug_*.md     (root-cause diagnosis, no fix proposed)
  └─[vdoc]─────► doc/<ip>.md               (full IP integration document)
```

## Skills

| Skill | Purpose |
|-------|---------|
| `varch` | Decompose an IP requirement into submodules, define interfaces, generate an architecture doc, per-module requirement files, and a top-level skeleton |
| `vdesign` | Generate a design proposal, module documentation, and an RTL backbone with `//@` direction markers from a requirement file |
| `vfill` | Implement the Verilog from an approved proposal, then lint and simulate |
| `vexplain` | Generate documentation for any RTL module from its Verilog source |
| `vdoc` | Aggregate per-module documentation into a single IP-level document |
| `vsynth` | Synthesize a module or full IP with Vivado; report utilization, Fmax, and power |
| `vtestgen` | Scaffold a Makefile-driven, CPU-bus-controlled bench project and generate self-checking testcases |
| `vtestrun` | Run all testcases from `tc_list.md`, capture results, write per-failure issue reports |
| `vdebug` | Trace failing signals through the RTL hierarchy, classify root cause, write a debug report |
| `vflow` | Scan project state, write `flow_status.md`, and orchestrate the full flow end-to-end |

## Agents

Agents bundle one or more skills into a role with a fixed model and turn budget.

| Agent | Model | Skills | Purpose |
|-------|-------|--------|---------|
| `rtl-architect` | Opus | varch, vexplain | Decompose an IP requirement into submodules |
| `rtl-designer` | Opus | vdesign | Generate proposal, docs, and RTL backbone |
| `rtl-coder` | Opus | vfill | Implement code, lint, and simulate |
| `rtl-documentation` | Opus | vdoc, vexplain | Build complete IP documentation |
| `rtl-synthesizer` | Sonnet | vsynth | Synthesize a module or IP and produce a report |
| `rtl-tester` | Opus | vtestgen, vtestrun | Generate IP testcases, run them, report failures |
| `rtl-debugger` | Opus | vdebug, vexplain | Trace RTL signal paths to root cause |
| `rtl-orchestrator` | Opus | vflow + all skills | Drive the complete flow with checkpoints and a debug loop |

## Conventions

- **`//@` markers** in RTL are design-direction comments for `vfill`; their grammar and lifecycle live in `skills/shared/CodingStyle.md`.
- **Synthesizable RTL** (`rtl/`, `lib/`) must be Verilog-2005 (IEEE 1364-2005). Testbenches under `tb/` may use SystemVerilog (`.sv`).
- **Reset** is always synchronous, active-low by default; use the `RS_LV` parameter when configurable.
- **Module docs** follow `skills/shared/ModuleDocContract.md` so they're usable without reading the RTL.
- **Testcase verdicts** end with `[FINISH] PASS` / `[FINISH] FAIL`; pass/fail is decided from that token only.
- Each skill lists its required external tools (Verilator, xvlog/xelab/xsim, Vivado) in a Prerequisites table. If a tool is missing, the skill stops and reports it rather than fabricating results.

## Prerequisites

- Claude Code
- A simulator: **Verilator** and/or Xilinx **xvlog/xelab/xsim**
- **Vivado** (for `vsynth`)

Skills degrade gracefully: if a required tool isn't installed, the affected phase is marked blocked and the flow continues.

## Getting started

1. Make these skills and agents available to Claude Code (e.g. copy `skills/` and `agents/` into your project's `.claude/` directory, or reference this repo from your setup).
2. Copy `CLAUDE.md` into your RTL project so the directory layout and conventions are picked up.
3. Write a top-level IP requirement (`ip_req.md`) and run `varch` to begin — or hand the whole thing to `vflow` / the `rtl-orchestrator` agent to drive end-to-end.

## Quick walkthrough

Skills are invoked inside Claude Code (type `/<skill>` or just ask Claude to run it). A typical IP goes:

1. **Write the requirement.** Drop a plain-English spec for the IP in `ddoc/<ip>_req.md` — interfaces, registers, behavior. This is the only file you author by hand.

2. **Architect** — `/varch ddoc/<ip>_req.md`
   Splits the IP into submodules and produces `ddoc/<ip>_arch.md` (the structural source of truth), a `ddoc/<submodule>_req.md` per block, and the `rtl/<ip>_top.v` skeleton. Edit the arch doc and re-run to reshape the design.

3. **Design each submodule** — `/vdesign ddoc/<module>_req.md`
   Generates a proposal (`ddoc/<module>_proposal.md`), module docs, and an RTL backbone with `//@` direction markers. **Review the proposal before continuing.**

4. **Implement** — `/vfill rtl/<module>.v`
   Fills in the Verilog from the approved proposal, then lints and unit-simulates it under `tb/<module>/`.

5. **Test the IP** — `/vtestgen` then `/vtestrun`
   `vtestgen` scaffolds a CPU-bus-driven bench in `tb/<ip>/` with self-checking testcases; `vtestrun` runs them all and writes pass/fail plus per-failure reports to `issue/<ip>/`.

6. **Debug failures** — `/vdebug issue/<ip>/issue_NNN_<name>.md`
   Traces the failing signal to a root cause and writes a debug report (it diagnoses; it doesn't auto-fix). Loop back to `vfill` to apply the fix, then re-run `vtestrun`.

7. **Synthesize** — `/vsynth <module>`
   Runs Vivado and reports utilization, Fmax, and power under `synth/<module>/`.

8. **Document** — `/vdoc`
   Aggregates every per-module doc into a single `doc/<ip>.md`.

### Let an agent drive it

Instead of running each step yourself, point the orchestrator at the IP and let it manage the dependencies and the debug→fix→retest loop:

```
Use the rtl-orchestrator agent to take ddoc/<ip>_req.md through the full flow.
```

It runs `vflow` to scan project state, writes `flow_status.md`, and calls each skill in order, pausing at the review checkpoints. You can also run `/vflow` on its own at any time to see what's done and what's next.

> Tip: skills are resumable and mostly idempotent — re-running a step picks up from the current state rather than starting over, so it's safe to iterate.

## License

Licensed under the [Apache License 2.0](LICENSE).
