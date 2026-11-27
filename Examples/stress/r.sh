#!/bin/bash
# usage: CLIPS=/path/to/folder/of/mp4s Examples/stress/r.sh sheet|export|still|check name [N]
# Build first: swift build -c release. Clips are passed in order as assets c1, c2, ... (the stress scripts use c1..c18).
cd "$(dirname "$0")"
BIN=../../.build/release/sprocket-render
mkdir -p sheets out
A=""; i=1
for f in "${CLIPS:-.}"/*.mp4; do [ -f "$f" ] && A="$A --asset c$i=$f" && i=$((i+1)); done
mode=$1; name=$2; n=$3
G="perl -e 'alarm 900; exec @ARGV' --"
case $mode in
 check) perl -e 'alarm 120; exec @ARGV' nice -n 10 $BIN stress/$name.js --check ;;
 sheet) perl -e 'alarm 300; exec @ARGV' nice -n 10 $BIN stress/$name.js $A --sheet ${n:-16} --out sheets/$name.jpg; echo "exit=$?" ;;
 still) perl -e 'alarm 120; exec @ARGV' nice -n 10 $BIN stress/$name.js $A --still $n --out sheets/$name-$n.png; echo "exit=$?" ;;
 export)
  rm -f out/$name.mp4
  perl -e 'alarm 900; exec @ARGV' /usr/bin/time -l nice -n 10 $BIN stress/$name.js $A --out out/$name.mp4 2> out/$name.err; echo "exit=$?"
  grep -E "real|maximum resident|elapsed" out/$name.err; grep -v -E "^ +[0-9]+ +[a-z ]|real|user|sys" out/$name.err | head -5
  if [ -f out/$name.mp4 ]; then
   FP=/opt/homebrew/bin/ffprobe
   $FP -v error -count_frames -select_streams v:0 -show_entries stream=codec_name,width,height,r_frame_rate,nb_read_frames,duration -of csv=p=0 out/$name.mp4
   echo "audio: $($FP -v error -select_streams a -show_entries stream=codec_name,duration -of csv=p=0 out/$name.mp4 | tr '\n' ' ')"
   ls -l out/$name.mp4 | awk '{print "size",$5}'
   rm -f out/$name.mp4; echo "mp4 deleted"
  else echo "NO MP4"; fi ;;
esac
