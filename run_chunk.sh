#!/usr/bin/env bash
# One chunk: run the SPH flyby for up to BUDGET_MIN minutes while rendering every finished state (two cameras,
# transparent PNG), then keep rendering the backlog until TOTAL_MIN. States still unrendered at TOTAL_MIN are
# carried to the next chunk in resume/ together with the newest state (the resume point) - nothing is lost and
# the job can never hit the runner's 6 h limit.
# Env: MASS N BY VINF END DT MAXDT BUDGET_MIN TOTAL_MIN W H ITERS CAM_CLOSE CAM_WIDE BH_R ABSORB_R TEXTURE RESUME_DIR
set -u
BHTOOL=${BHTOOL:-./bhtool}
SIM=sim; FRAMES=frames; mkdir -p $SIM $FRAMES resume
MASS=${MASS:-1}; N=${N:-500000}; BY=${BY:-14000}; VINF=${VINF:-8}
END=${END:-40000}; DT=${DT:-40}; MAXDT=${MAXDT:-10}
BUDGET_MIN=${BUDGET_MIN:-270}; TOTAL_MIN=${TOTAL_MIN:-318}
W=${W:-1920}; H=${H:-1080}; ITERS=${ITERS:-6}
CAM_CLOSE=${CAM_CLOSE:--34000}; CAM_CLOSE_Z=${CAM_CLOSE_Z:-8000}
CAM_WIDE=${CAM_WIDE:--90000}; CAM_WIDE_Z=${CAM_WIDE_Z:-24000}; TEXTURE=${TEXTURE:-}
# near-frontal light (reference film: whole disc lit, specular at centre; limb profile is matched in post)
SUN=${SUN:-0.1 1 -0.15}; SUN_I=${SUN_I:-1.1}; AMBIENT=${AMBIENT:-0.12}; EMISSION=${EMISSION:-0.8}
read -r SX SY SZ <<< "$SUN"
BH_R=${BH_R:-1913}        # visual black-hole radius [km] = 0.3 Earth radii (rendered as a black disc)
ABSORB_R=${ABSORB_R:-1913} # physical absorb radius [km]: anything inside the black disc is invisible anyway,
                           # and eating it keeps the Courant time step from collapsing after the encounter
RESUME_DIR=${RESUME_DIR:-}

# Pending states from the previous chunk: newest = resume point, all of them still need rendering.
RESUME=""
if [ -n "$RESUME_DIR" ] && ls "$RESUME_DIR"/bh_*.ssf >/dev/null 2>&1; then
  cp "$RESUME_DIR"/bh_*.ssf $SIM/
  RESUME=$(ls -1 $SIM/bh_*.ssf | sort | tail -1)
  echo "== carried over $(ls $SIM/bh_*.ssf | wc -l) state(s); resume point $RESUME"
fi
SKIP=" $(cd "${RESUME_DIR:-/nonexistent}" 2>/dev/null && ls rendered_* 2>/dev/null | sed 's/rendered_//' | tr '\n' ' ') "  # already rendered last chunk

# When resuming, OpenSPH restarts the clock at 0, so --end acts as *extra* duration.
RUN_END=$END; SIMPID=""
if [ -n "$RESUME" ]; then
  idx=$(basename "$RESUME" .ssf); idx=${idx#bh_}; idx=$((10#$idx))
  RUN_END=$(( END - idx * DT ))
  echo "== resume from frame $idx, remaining ${RUN_END}s of sim time"
fi
if [ "$RUN_END" -gt "$DT" ]; then
  args=(sim --n "$N" --mass "$MASS" --r "$ABSORB_R" --by "$BY" --vinf "$VINF" --end "$RUN_END" --dt "$DT" --maxdt "$MAXDT" --out "$SIM")
  [ -n "$TEXTURE" ] && args+=(--texture "$TEXTURE")
  [ -n "$RESUME" ] && args+=(--resume "$RESUME")
  echo "== chunk: ${args[*]}  budget=${BUDGET_MIN}min total=${TOTAL_MIN}min"
  xvfb-run -a "$BHTOOL" "${args[@]}" > sim.log 2>&1 &
  SIMPID=$!
else
  echo "== nothing left to simulate, rendering the backlog only"
fi
START=$(date +%s)
[ -n "$SIMPID" ] && sleep 45   # let the sim (re)write its first state before the render loop looks at the files
elapsed_min() { echo $(( ($(date +%s) - START) / 60 )); }
sim_alive() { [ -n "$SIMPID" ] && kill -0 "$SIMPID" 2>/dev/null; }

render_one() {  # $1 = path to ssf -> close_NNNN.png and wide_NNNN.png (transparent background)
  local f=$1 idx; idx=$(basename "$f" .ssf); idx=${idx#bh_}
  case "$SKIP" in *" $idx "*) return 0;; esac
  local common=(--w "$W" --h "$H" --iters "$ITERS" --transparent 1 \
      --sx "$SX" --sy "$SY" --sz "$SZ" --sun "$SUN_I" --ambient "$AMBIENT" --emission "$EMISSION" --bh_r "$BH_R")
  if [ ! -f "$FRAMES/close_$idx.png" ]; then
    xvfb-run -a "$BHTOOL" render --single "$f" --out "$FRAMES" --mask "close_$idx.png" --cy "$CAM_CLOSE" --cz "$CAM_CLOSE_Z" "${common[@]}" > /dev/null 2>&1
  fi
  if [ ! -f "$FRAMES/wide_$idx.png" ]; then
    xvfb-run -a "$BHTOOL" render --single "$f" --out "$FRAMES" --mask "wide_$idx.png" --cy "$CAM_WIDE" --cz "$CAM_WIDE_Z" "${common[@]}" > /dev/null 2>&1
  fi
  [ -f "$FRAMES/close_$idx.png" ] && [ -f "$FRAMES/wide_$idx.png" ]
}

# main loop: render oldest complete states first; the newest file may still be being written while the sim runs
STATUS=continue
while true; do
  mapfile -t files < <(ls -1 $SIM/bh_*.ssf 2>/dev/null | sort)
  cnt=${#files[@]}
  if sim_alive; then n_ok=$((cnt - 1)); else n_ok=$cnt; fi
  rendered_now=0
  for ((k = 0; k < n_ok; k++)); do
    if [ "$(elapsed_min)" -ge "$TOTAL_MIN" ]; then break; fi
    if render_one "${files[$k]}"; then
      # keep the newest state as the resume point even after rendering it
      if [ "$k" -lt $((cnt - 1)) ]; then rm -f "${files[$k]}"; fi
      rendered_now=1
    fi
    if sim_alive && [ "$(elapsed_min)" -ge "$BUDGET_MIN" ]; then
      echo "== sim budget reached at frame $(ls $SIM/bh_*.ssf | wc -l) states pending, stopping sim"; kill "$SIMPID"; sleep 5; SIMPID=""
    fi
  done
  if [ "$(elapsed_min)" -ge "$TOTAL_MIN" ]; then echo "== total budget reached"; break; fi
  if sim_alive; then
    if [ "$(elapsed_min)" -ge "$BUDGET_MIN" ]; then
      echo "== sim budget reached, stopping sim"; kill "$SIMPID"; sleep 5; SIMPID=""
    elif [ "$rendered_now" = 0 ]; then sleep 20; fi
  else
    # sim finished (or was stopped): loop once more to render what remains, then leave
    mapfile -t files < <(ls -1 $SIM/bh_*.ssf 2>/dev/null | sort)
    all_done=1
    for f in "${files[@]}"; do i=$(basename "$f" .ssf); i=${i#bh_}; case "$SKIP" in *" $i "*) continue;; esac; [ -f "$FRAMES/close_$i.png" ] && [ -f "$FRAMES/wide_$i.png" ] || all_done=0; done
    [ "$all_done" = 1 ] && break
  fi
done
if sim_alive; then kill "$SIMPID"; sleep 5; fi
# a state that was being written when the sim was killed is unusable: drop it if it is clearly smaller
mapfile -t files < <(ls -1 $SIM/bh_*.ssf 2>/dev/null | sort)
if [ ${#files[@]} -ge 2 ]; then
  s_last=$(stat -c %s "${files[-1]}"); s_prev=$(stat -c %s "${files[-2]}")
  if [ "$s_last" -lt $(( s_prev * 9 / 10 )) ]; then echo "== dropping partial state ${files[-1]} ($s_last < $s_prev bytes)"; rm -f "${files[-1]}"; fi
fi

# carry forward: every state whose frames are missing + the newest state (resume point)
mapfile -t files < <(ls -1 $SIM/bh_*.ssf 2>/dev/null | sort)
cnt=${#files[@]}
for ((k = 0; k < cnt; k++)); do
  f=${files[$k]}; i=$(basename "$f" .ssf); i=${i#bh_}
  done_i=0; case "$SKIP" in *" $i "*) done_i=1;; esac
  [ -f "$FRAMES/close_$i.png" ] && [ -f "$FRAMES/wide_$i.png" ] && done_i=1
  if [ "$k" -eq $((cnt - 1)) ] || [ "$done_i" = 0 ]; then cp "$f" resume/; fi
  # a carried state whose frames already exist must not be rendered again next chunk: mark it
  if [ "$k" -eq $((cnt - 1)) ] && [ "$done_i" = 1 ]; then touch "resume/rendered_$i"; fi
done
last=${files[$((cnt - 1))]:-}
final_idx=$(basename "${last:-bh_0000.ssf}" .ssf); final_idx=${final_idx#bh_}; final_idx=$((10#$final_idx))
if [ $(( END - final_idx * DT )) -le "$DT" ]; then STATUS=done; fi
echo $STATUS > chunk_status.txt
tail -3 sim.log 2>/dev/null
echo "== frames: $(ls $FRAMES/close_*.png 2>/dev/null | wc -l) close, $(ls $FRAMES/wide_*.png 2>/dev/null | wc -l) wide; carried: $(ls resume/*.ssf 2>/dev/null | wc -l) state(s); status=$STATUS; elapsed $(elapsed_min) min"
