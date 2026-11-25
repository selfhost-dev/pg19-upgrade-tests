#!/bin/bash
# Longest outage in a probe file, in ms: first OK after the outage minus last OK before it.
# Usage: gap.sh <probe.csv>    -> prints "<gap_ms> <fail_samples>"
awk -F, '
  $2=="ok"   { if (infail && last_ok) { g=$1-last_ok; if (g>max) {max=g; n=cnt} } infail=0; cnt=0; last_ok=$1 }
  $2=="fail" { infail=1; cnt++ }
  END { print (max+0), (n+0) }
' "$1"
