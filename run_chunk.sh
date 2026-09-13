#!/usr/bin/env bash
# One simulation chunk: run the SPH flyby for up to BUDGET_MIN minutes, render every saved
# state file to PNG as it appears (and delete it to save disk), keep the newest .ssf for resume.
# Env: MASS N BY VINF END DT MAXDT BUDGET_MIN W H ITERS CAM_Y CAM_Z TEXTURE RESUME(optional path)
set -u
BHTOOL=${BHTOOL:-./bhtool}
SIM=sim; FRAMES=frames; mkdir -p $SIM $FRAMES
MASS=${MASS:-1}; N=${N:-500000}; BY=${BY:-14000}; VINF=${VINF:-8}
END=${END:-40000}; DT=${DT:-40}; MAXDT=${MAXDT:-10}
BUDGET_MIN=${BUDGET_MIN:-270}; W=${W:-1920}; H=${H:-1080}; ITERS=${ITERS:-6}
CAM_Y=${CAM_Y:--70000}; CAM_Z=${CAM_Z:-20000}; TEXTURE=${TEXTURE:-}
RESUME=${RESUME:-}

args=(sim --n "$N" --mass "$MASS" --by "$BY" --vinf "$VINF" --end "$END" --dt "$DT" --maxdt "$MAXDT" --out "$SIM")
[ -n "$TEXTURE" ] && args+=(--texture "$TEXTURE")
[ -n "$RESUME" ] && args+=(--resume "$RESUME")

echo "== chunk: ${args[*]}  budget=${BUDGET_MIN}min"
xvfb-run -a "$BHTOOL" "${args[@]}" > sim.log 2>&1 &
SIMPID=$!
START=$(date +%s)

render_one() {  # $1 = path to ssf
  local f=$1 idx; idx=$(basename "$f" .ssf); idx=${idx#bh_}
  [ -f "$FRAMES/frame_$idx.png" ] && return 0
  xvfb-run -a "$BHTOOL" render --single "$f" --out "$FRAMES" --mask "frame_$idx.png" \
      --w "$W" --h "$H" --iters "$ITERS" --cy "$CAM_Y" --cz "$CAM_Z" > /dev/null 2>&1
}

while true; do
  # all state files except the newest are complete -> render + delete
  mapfile -t files < <(ls -1 $SIM/bh_*.ssf 2>/dev/null | sort)
  cnt=${#files[@]}
  if [ "$cnt" -gt 1 ]; then
    for f in "${files[@]:0:$((cnt-1))}"; do
      render_one "$f" && rm -f "$f"
    done
  fi
  if ! kill -0 $SIMPID 2>/dev/null; then
    echo "== sim finished"; break
  fi
  if [ $(( ($(date +%s) - START) / 60 )) -ge "$BUDGET_MIN" ]; then
    echo "== budget reached, stopping sim"; kill $SIMPID; sleep 5; break
  fi
  sleep 20
done

# render whatever complete files remain, keep the newest one for resume
mapfile -t files < <(ls -1 $SIM/bh_*.ssf 2>/dev/null | sort)
cnt=${#files[@]}
if [ "$cnt" -gt 1 ]; then
  for f in "${files[@]:0:$((cnt-1))}"; do render_one "$f" && rm -f "$f"; done
fi
if [ "$cnt" -ge 1 ]; then
  last=${files[$((cnt-1))]}
  if kill -0 $SIMPID 2>/dev/null; then :; else render_one "$last"; fi
  mkdir -p resume && cp "$last" resume/
  echo "== resume file: $last"
fi
tail -3 sim.log
echo "== frames: $(ls $FRAMES | wc -l)"
