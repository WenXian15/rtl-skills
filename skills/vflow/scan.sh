#!/usr/bin/env bash
# vflow project-state scanner.
# Usage: bash scan.sh <ip>   (run from the project root)
# Emits one compact line per phase signal; reads no file body except the
# `| Failed | N |` row of run_summary.md. See SKILL.md Step 1 for the
# status-mapping table that interprets this output.
set -u

ip=${1:?usage: scan.sh <ip> (run from project root)}
have(){ [ -e "$1" ]; }

# Fail loudly if the standard layout is missing — do not emit misleading PENDINGs.
[ -d rtl ] && [ -d ddoc ] || { echo "ERR: not at a project root (need ./rtl and ./ddoc)"; exit 2; }

reqs=$(ls ddoc/*_req.md 2>/dev/null | sed 's#.*/##; s/_req\.md$//')

# Phase 1 — Architecture
if have "ddoc/${ip}_arch.md" && [ -n "$reqs" ] && have "rtl/${ip}_top.v"; then
  echo "P1 DONE"
else
  echo "P1 PENDING"
fi

# Phase 2 — Design  (every <module>_req.md has rtl/<module>.v)
d=0; n=0
for m in $reqs; do n=$((n+1)); have "rtl/$m.v" && d=$((d+1)); done
echo "P2 $d/$n"

# Phase 3 — Implementation  (no rtl/*.v except _top.v has //@)
left=$(grep -rl '//@' rtl/ 2>/dev/null | grep -vc "_top\.v$")
echo "P3 left=$left"

# Phase 4 — Synthesis  (full-IP target is the top module <ip>_top, so the
# report lands in synth/<ip>_top/, not synth/<ip>/)
have "synth/${ip}_top/synth_report.md" && echo "P4 DONE" || echo "P4 PENDING"

# Phase 5 — IP Testing  (run > scaffolded > none)
if have "issue/${ip}/run_summary.md"; then
  echo "P5 RUN"
elif have "tb/${ip}/Makefile" && have "tb/${ip}/tc_list.md"; then
  echo "P5 SCAFFOLDED"
else
  echo "P5 NONE"
fi

# Failed count + debug currency
if have "issue/${ip}/run_summary.md"; then
  failed=$(awk -F'|' '/\| *Failed *\|/ {gsub(/ /,"",$3); print $3}' "issue/${ip}/run_summary.md")
  echo "FAILED=${failed:-?}"
  if have "issue/${ip}/debug_summary.md"; then
    if [ "issue/${ip}/debug_summary.md" -nt "issue/${ip}/run_summary.md" ]; then
      echo "DEBUG=current"
      # Open RTL_BUG count, from the classification breakdown in debug_summary's
      # Results section (the first RTL_BUG line carrying a number). Reading the
      # count this way keeps Phase 6 DONE computable without a body Read.
      rb=$(awk '/RTL_BUG/ {for(i=1;i<=NF;i++) if($i ~ /^[0-9]+$/){print $i; exit}}' \
             "issue/${ip}/debug_summary.md")
      echo "RTLBUG=${rb:-?}"
    else
      echo "DEBUG=stale"
    fi
  else
    echo "DEBUG=none"
  fi
fi

# Phase 7 — Documentation
have "doc/${ip}.md" && echo "P7 DONE" || echo "P7 PENDING"
