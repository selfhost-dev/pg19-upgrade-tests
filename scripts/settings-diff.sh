#!/bin/bash
# Compare built-in defaults (boot_val) of every setting in 18 and 19.
# Output: added, removed and changed settings -> results/raw/settings-diff/
source /lab/lib.sh
out=$RESULTS/raw/settings-diff; rm -rf -- "${out:?}"; mkdir -p "$out"
for v in 18 19; do
  d=/data/tmp-settings-$v; rm -rf -- "${d:?}"
  port=$((5440 + v - 18))
  init_cluster "$v" "$d" "$port"
  pg_start "$v" "$d"
  q "$v" "$port" -F $'\t' -c "select name, coalesce(boot_val,''), coalesce(unit,'') from pg_settings order by 1" > "$out/boot-$v.tsv"
  pg_stop "$v" "$d"; rm -rf -- "${d:?}"
done
cd "$out" || exit 1
cut -f1 boot-18.tsv > n18; cut -f1 boot-19.tsv > n19
comm -13 n18 n19 > added.txt
comm -23 n18 n19 > removed.txt
join -t $'\t' boot-18.tsv boot-19.tsv | awk -F'\t' '$2!=$4 || $3!=$5 {print $1": "$2$3" -> "$4$5}' > changed.txt
rm n18 n19
for f in added removed changed; do echo "== $f"; cat $f.txt; done
