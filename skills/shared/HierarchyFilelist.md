# Hierarchy Filelist Construction

This procedure builds the complete list of Verilog source files required to
compile a module or IP, by walking its instantiation hierarchy. `vsynth`,
`vtestgen`, and `vdoc` all use it so the walk logic stays identical across skills.

## Walk Procedure

Starting from the top module file:

1. Add the top module source file to the list.
2. Extract the names of instantiated submodules **with `grep`, not by reading the
   whole file** (see below) — the walk only needs instance type names, so a full
   `Read` of each RTL file wastes tokens, especially on a deep hierarchy.
3. For each instantiated submodule, locate its source file by searching
   recursively in `./rtl/` first, then `./lib/`.
4. Add each located file to the list and repeat from step 2 for it.
5. Stop when every reachable module has been added. De-duplicate: a file shared
   by multiple parents appears in the list once.

A module whose source cannot be found in `./rtl/` or `./lib/` is a hard error —
report the missing module and the parent that instantiates it; do not silently
drop it.

### Extracting instantiations with grep

An instantiation header is `<module_name> [#(...)] <instance_name> (`, with the
module name in column 0/indented at statement level. Pull the candidate type
names without reading the file body, e.g.:

```bash
# instantiated-module names in one file (drops keywords, ports, and `// comments`)
grep -oE '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]+(#|[A-Za-z_])' rtl/foo_top.v \
  | grep -oE '[A-Za-z_][A-Za-z0-9_]*' | head -1   # the leading token per match
```

Then resolve each candidate name to a file (`rtl/` then `lib/`). Treat the leading
token as a *candidate* — discard the Verilog keywords that can also start a
statement at that position (`module`, `wire`, `reg`, `assign`, `always`, `input`,
`output`, `localparam`, `parameter`, `generate`, `genvar`, `if`, `for`, `case`,
`begin`, `end`, …). A name that resolves to a source file under `rtl/`/`lib/` is a
real submodule; one that does not and is not a known keyword is the hard error
above. **Only open a file with `Read` when grep is genuinely ambiguous** (e.g. a
macro-built instance name, or instantiation spread across unusual line breaks).

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
