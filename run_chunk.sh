#!/usr/bin/env bash
# One simulation chunk: run the SPH flyby for up to BUDGET_MIN minutes, render every saved
# state file to PNG as it appears (and delete it to save disk), keep the newest .ssf for resume.
# Env: MASS N BY VINF END DT MAXDT BUDGET_MIN W H ITERS CAM_CLOSE CAM_WIDE TEXTURE RESUME(optional path)
set -u
BHTOOL=${BHTOOL:-./bhtool}
SIM=sim; FRAMES=frames; mkdir -p $SIM $FRAMES
MASS=${MASS:-1}; N=${N:-500000}; BY=${BY:-14000}; VINF=${VINF:-8}
END=${END:-40000}; DT=${DT:-40}; MAXDT=${MAXDT:-10}
BUDGET_MIN=${BUDGET_MIN:-270}; W=${W:-1920}; H=${H:-1080}; ITERS=${ITERS:-6}
CAM_CLOSE=${CAM_CLOSE:--34000}; CAM_CLOSE_Z=${CAM_CLOSE_Z:-8000}
CAM_WIDE=${CAM_WIDE:--90000}; CAM_WIDE_Z=${CAM_WIDE_Z:-24000}; TEXTURE=${TEXTURE:-}
SUN=${SUN:--0.5 1 0.3}; SUN_I=${SUN_I:-1.1}; AMBIENT=${AMBIENT:-0.12}; EMISSION=${EMISSION:-0.8}
read -r SX SY SZ <<< "$SUN"
RESUME=${RESUME:-}

# When resuming, OpenSPH restarts the clock at 0, so --end acts as *extra* duration.
# The frame index of the resume file tells us how far we already are (index * DT seconds).
RUN_END=$END
if [ -n "$RESUME" ]; then
  idx=$(basename "$RESUME" .ssf); idx=${idx#bh_}; idx=$((10#$idx))
  done_s=$(( idx * DT ))
  RUN_END=$(( END - done_s ))
  echo "== resume from frame $idx (~${done_s}s done), remaining ${RUN_END}s"
  if [ "$RUN_END" -le "$DT" ]; then
    echo "== nothing left to simulate"; echo done > chunk_status.txt; mkdir -p $FRAMES resume; exit 0
  fi
fi

args=(sim --n "$N" --mass "$MASS" --by "$BY" --vinf "$VINF" --end "$RUN_END" --dt "$DT" --maxdt "$MAXDT" --out "$SIM")
[ -n "$TEXTURE" ] && args+=(--texture "$TEXTURE")
[ -n "$RESUME" ] && args+=(--resume "$RESUME")

echo "== chunk: ${args[*]}  budget=${BUDGET_MIN}min"
xvfb-run -a "$BHTOOL" "${args[@]}" > sim.log 2>&1 &
SIMPID=$!
START=$(date +%s)

render_one() {  # $1 = path to ssf -> two frames: close_NNNN.png and wide_NNNN.png (transparent background)
  local f=$1 idx; idx=$(basename "$f" .ssf); idx=${idx#bh_}
  local common=(--w "$W" --h "$H" --iters "$ITERS" --transparent 1 \
      --sx "$SX" --sy "$SY" --sz "$SZ" --sun "$SUN_I" --ambient "$AMBIENT" --emission "$EMISSION")
  if [ ! -f "$FRAMES/close_$idx.png" ]; then
    xvfb-run -a "$BHTOOL" render --single "$f" --out "$FRAMES" --mask "close_$idx.png" --cy "$CAM_CLOSE" --cz "$CAM_CLOSE_Z" "${common[@]}" > /dev/null 2>&1
  fi
  if [ ! -f "$FRAMES/wide_$idx.png" ]; then
    xvfb-run -a "$BHTOOL" render --single "$f" --out "$FRAMES" --mask "wide_$idx.png" --cy "$CAM_WIDE" --cz "$CAM_WIDE_Z" "${common[@]}" > /dev/null 2>&1
  fi
  [ -f "$FRAMES/close_$idx.png" ] && [ -f "$FRAMES/wide_$idx.png" ]
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
    echo "== sim finished"; echo done > chunk_status.txt; break
  fi
  if [ $(( ($(date +%s) - START) / 60 )) -ge "$BUDGET_MIN" ]; then
    echo "== budget reached, stopping sim"; echo continue > chunk_status.txt; kill $SIMPID; sleep 5; break
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
elif [ -n "$RESUME" ]; then
  mkdir -p resume && cp "$RESUME" resume/   # no new state this chunk; carry the old one forward
fi
tail -3 sim.log
echo "== frames: $(ls $FRAMES/close_*.png 2>/dev/null | wc -l) close, $(ls $FRAMES/wide_*.png 2>/dev/null | wc -l) wide"
