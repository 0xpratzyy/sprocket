#!/bin/zsh
# Times every engine on every scene: 1 warm-up + 3 timed runs, wall clock of the whole command. Writes out/results.csv.
cd "${0:A:h}"
mkdir -p out
S=$PWD/../.build/release/sprocket-render
R=out/results.csv; echo "engine,scene,run,seconds,exit" > $R
T() { python3 -c "import time;print(time.time())"; }
cfg() { local name=$1 scene=$2; shift 2
  for run in 0 1 2 3; do local a=$(T); ( eval "$@" ) > out/$name-$scene-$run.log 2>&1; local e=$?
    echo "$name,$scene,$run,$(python3 -c "print(round($(T)-$a,2))"),$e" >> $R; done; }
for s in title cards video; do
  C=${(C)s}; ast=""; [[ $s == video ]] && ast="--asset clip=remotion/public/clip.mp4"
  cfg sprocket $s "$S sprocket/$s.js $ast --out out/sprocket-$s.mp4"
  cfg kinetograph-tsx $s "cd remotion && npx kinetograph render src/index.ts --comp $C -o ../out/kin-$s.mp4"
  cfg kinetograph-html $s "cd hyperframes/$s && ../node_modules/.bin/kinetograph render index.html -o ../../out/kinhf-$s.mp4"
  cfg remotion $s "cd remotion && npx remotion render src/index.ts $C ../out/rem-$s.mp4"
  cfg hyperframes $s "cd hyperframes/$s && ../node_modules/.bin/hyperframes render -o ../../out/hf-$s.mp4 --quiet"
done
python3 - <<'PY'
import csv, statistics as st
rows = list(csv.DictReader(open("out/results.csv")))
for s in ["title", "cards", "video"]:
    print(s)
    for e in ["sprocket", "kinetograph-tsx", "kinetograph-html", "remotion", "hyperframes"]:
        t = [float(r["seconds"]) for r in rows if r["scene"] == s and r["engine"] == e and r["run"] != "0"]
        if t: print(f"  {e:18} {st.median(t):6.2f} s")
PY
