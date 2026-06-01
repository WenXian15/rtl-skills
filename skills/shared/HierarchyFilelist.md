# Hierarchy Filelist Construction

This procedure builds the complete list of Verilog source files required to
compile a module or IP, by walking its instantiation hierarchy. `vsynth`,
`vtestgen`, and `vdoc` all use it so the walk logic stays identical across skills.

## Walk Procedure

Starting from the top module file:

1. Add the top module source file to the list.
2. Parse the file for instantiated submodules.
3. For each instantiated submodule, locate its source file by searching
   recursively in `./rtl/` first, then `./lib/`.
4. Add each located file to the list and repeat from step 2 for it.
5. Stop when every reachable module has been added. De-duplicate: a file shared
   by multiple parents appears in the list once.

A module whose source cannot be found in `./rtl/` or `./lib/` is a hard error —
report the missing module and the parent that instantiates it; do not silently
drop it.

## Path Expression

The list itself is base-directory independent. Each consuming skill expresses the
paths relative to the directory the tool runs from:

| Skill     | Consumer                      | Path form                  | Example                          |
|-----------|-------------------------------|----------------------------|----------------------------------|
| vsynth    | `read_verilog` in `vsynth.tcl`, run from `synth/<module>/` | literal `../../` prefix | `../../rtl/foo_top.v`            |
| vtestgen  | `script/rtl.f` make fragment, `include`d by the bench Makefiles | `$(RTL_FOLDER)` / `$(LIB_FOLDER)` | `RTL_FILES += $(RTL_FOLDER)/foo_top.v` |

When writing a persisted filelist (e.g. `tb/<ip>/script/rtl.f`, a make fragment
that defines `RTL_FILES`), dependency order is not required — the order does not
matter to `xvlog` or `read_verilog` — but keep the top module first for readability.
