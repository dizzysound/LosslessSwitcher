#!/bin/zsh
# lsvcheck.sh <name>: checks a trial_lsv.sh run (data/<name>.*):
# 1. vsegcheck.py: what B played == what A read, per rate segment (holds and flushes allowed)
# 2. outcheck.py: what B played vs the sources (every local file in data/<name>.watch.txt, by rate)
# 3. clock: phase error per lock (after 5 s), fill, under/overruns
cd "${0:A:h}"
n=data/$1
python3 vsegcheck.py $n | tail -1
srcs=()
while IFS=$'\t' read -r head rate pos tname fpath; do
  # the file's own rate (Music's metadata can be wrong: I Hear A Rhapsody says 44100, the file is 96k)
  [[ -n "$fpath" && -f "$fpath" ]] && srcs+=("$(afinfo "$fpath" | sed -nE 's/.*Data format: +2 ch, +([0-9]+) Hz.*/\1/p' | head -1)=$fpath")
done < $n.watch.txt
python3 ../outcheck.py $n "${srcs[@]}"
python3 - $n <<'EOF'
import sys, csv
rows = list(csv.DictReader(open(sys.argv[1] + ".clock.csv")))
locks, cur = [], None
for r in rows:
    t, err, rate = float(r["t"]), float(r["err"]), r["rate"]
    if cur is None or err == 0.0 and (rate != cur["rate"] or t - cur["t1"] > 1):
        cur = {"rate": rate, "t0": t, "t1": t, "errs": []}; locks.append(cur)
    cur["t1"] = t
    if t - cur["t0"] >= 5: cur["errs"].append(err)
for l in locks:
    e = l["errs"]
    print(f"clock lock {int(l['rate'])} Hz, {l['t0']:.1f}-{l['t1']:.1f} s: " + (f"max|err| after 5 s {max(abs(x) for x in e):.2f} frames ({len(e)} samples)" if e else "shorter than 5 s"))
print(f"underruns {rows[-1]['underruns']} frames, overruns {rows[-1]['overruns']} frames")
EOF
grep -E "switch [0-9]+:|DAC ready|DAC NOT ready|NOT latched|MUTED|not settled|re-locking|stray|NOT" $n.log | sed 's/^/  /'
