#!/usr/bin/env bash
# ============================================================================
# gpu_health_check.sh — проверка "живости" Tesla P40 (24GB) / V100 (32GB)
#  + авто-сравнение двух карт в общем отчёте
#
# Запуск:
#   ./gpu_health_check.sh                  # все этапы (dcgmi diag -r 2)
#   ./gpu_health_check.sh quick            # быстро: info+ecc+bw+burn 60с
#   ./gpu_health_check.sh full             # полный: dcgmi diag -r 3 (~30 мин)
#   ./gpu_health_check.sh info|ecc|diag|bw|burn
#   ./gpu_health_check.sh report [fileA fileB]
#
# Переменные окружения:
#   GPU_IDX=0 / BURN_SECONDS=120 / DCGM_LEVEL=2 / RES_DIR=./gpu_results
#   COMPARE_FATBIN=/usr/local/share/gpu-burn/compare.fatbin
#
# Сравнение:
#   - каждый прогон пишет метрики в $RES_DIR/result_<P40|V100>_<ts>.jsonl
#   - если результат второй карты уже есть, автоматически создаётся
#     $RES_DIR/gpu_compare_report.md
# ============================================================================
set -u

MODE="${1:-all}"
GPU_IDX="${GPU_IDX:-0}"
BURN_SECONDS="${BURN_SECONDS:-120}"
DCGM_LEVEL="${DCGM_LEVEL:-2}"
RES_DIR="${RES_DIR:-./gpu_results}"
COMPARE_FATBIN="${COMPARE_FATBIN:-/usr/local/share/gpu-burn/compare.fatbin}"
mkdir -p "$RES_DIR"

# ---------- утилиты результатов ----------
latest_of() { ls -1t "$RES_DIR"/result_$1_*.jsonl 2>/dev/null | head -1; }

jval() { # jval <file> <key>
  grep "\"key\":\"$2\"" "$1" 2>/dev/null | tail -1 | sed -E 's/^.*"value":"(.*)".*$/\1/'
}
cell() { # ячейка таблицы: значение или "—"
  local v; v=$(jval "$1" "$2"); [ -n "$v" ] && echo "$v" || echo "—"
}
ratio() { # ratio <a> <b>  ->  b/a
  awk -v x="$1" -v y="$2" 'BEGIN{
    if (x ~ /^[0-9.]+$/ && y ~ /^[0-9.]+$/ && x+0 > 0) printf "%.2f", y/x;
    else print "—"}'
}

generate_report() {
  local fA="$1" fB="$2" a b ra rb REPORT
  a=$(sed -n '1p' "$fA" | sed -E 's/^.*"gpu":"(.*)".*$/\1/')
  b=$(sed -n '1p' "$fB" | sed -E 's/^.*"gpu":"(.*)".*$/\1/')
  ra=$(sed -n '1p' "$fA" | sed -E 's/^.*"run":"(.*)".*$/\1/')
  rb=$(sed -n '1p' "$fB" | sed -E 's/^.*"run":"(.*)".*$/\1/')
  if echo "$a" | grep -q V100; then   # P40 всегда в левом столбце
    local t; t="$fA"; fA="$fB"; fB="$t"; t="$a"; a="$b"; b="$t"; t="$ra"; ra="$rb"; rb="$t"
  fi
  REPORT="$RES_DIR/gpu_compare_report.md"
  {
    echo "# GPU health check — сравнительный отчёт"
    echo
    echo "Сгенерирован: $(date '+%Y-%m-%d %H:%M:%S')"
    echo
    echo "| Метрика | ${a} | ${b} |"
    echo "|---|---|---|"
    echo "| Прогон (run id) | ${ra} | ${rb} |"
    echo "| Память, MB | $(cell "$fA" mem_total_mb) | $(cell "$fB" mem_total_mb) |"
    echo "| PCIe линк | $(cell "$fA" pcie_link) | $(cell "$fB" pcie_link) |"
    echo "| ECC uncorrected | $(cell "$fA" ecc_uncorr) | $(cell "$fB" ecc_uncorr) |"
    echo "| DCGM diag | $(cell "$fA" dcgm) | $(cell "$fB" dcgm) |"
    echo "| D2D bandwidth, GB/s | $(cell "$fA" d2d_bw) | $(cell "$fB" d2d_bw) |"
    echo "| gpu-burn, TFLOPS | $(cell "$fA" tflops) | $(cell "$fB" tflops) |"
    echo "| Макс. температура, °C | $(cell "$fA" max_temp) | $(cell "$fB" max_temp) |"
    echo "| SM clock, MHz | $(cell "$fA" max_clock) | $(cell "$fB" max_clock) |"
    echo "| Итог | $(cell "$fA" status) | $(cell "$fB" status) |"
    echo
    echo "### Соотношения (правый столбец / левый)"
    echo
    echo "- D2D bandwidth: $(ratio "$(jval "$fA" d2d_bw)" "$(jval "$fB" d2d_bw)")  (ожидаемо ~2.3 — HBM2 vs GDDR5)"
    echo "- TFLOPS: $(ratio "$(jval "$fA" tflops)" "$(jval "$fB" tflops)")  (ожидаемо ~1.8–2.2)"
    echo
    echo "> Значительно более низкое соотношение — проверь карту в правом столбце"
    echo "> (троттлинг, PCIe линк, слот/riser)."
  } | tee "$REPORT"
  echo
  echo ">>> Файл отчёта: $REPORT"
}

run_report() {
  local fA="${1:-}" fB="${2:-}"
  [ -n "$fA" ] || fA=$(latest_of P40)
  [ -n "$fB" ] || fB=$(latest_of V100)
  if [ -z "$fA" ] || [ -z "$fB" ]; then
    echo "Недостаточно файлов результатов:"
    echo "  P40:  ${fA:-—}"
    echo "  V100: ${fB:-—}"
    echo "Сначала прогони проверку на обеих картах: GPU_IDX=N ./gpu_health_check.sh quick"
    exit 1
  fi
  generate_report "$fA" "$fB"
}

# report не требует GPU — обрабатываем до проверки карты
if [ "$MODE" = "report" ]; then
  shift
  run_report "$@"
  exit 0
fi

# ---------- основной прогон ----------
export CUDA_VISIBLE_DEVICES="$GPU_IDX"
NSMI() { nvidia-smi -i "$GPU_IDX" "$@"; }

GPU_NAME="$(NSMI --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)"
[ -n "$GPU_NAME" ] || { echo "nvidia-smi не видит карту GPU_IDX=$GPU_IDX"; exit 2; }
case "$GPU_NAME" in
  *P40*) GPU_SHORT="P40" ;;
  *V100*) GPU_SHORT="V100" ;;
  *)     GPU_SHORT=$(echo "$GPU_NAME" | awk '{print $NF}') ;;
esac
RUN_ID="$(date +%Y%m%d_%H%M%S)"
LOG_DIR="$RES_DIR/logs_${GPU_SHORT}_${RUN_ID}"
RESULT_FILE="$RES_DIR/result_${GPU_SHORT}_${RUN_ID}.jsonl"
mkdir -p "$LOG_DIR"

rec() { printf '{"gpu":"%s","run":"%s","key":"%s","value":"%s"}\n' \
  "$GPU_NAME" "$RUN_ID" "$1" "${2//\"/\\\"}" >> "$RESULT_FILE"; }

MEMEXP=380
case "$GPU_SHORT" in
  P40)  EXPECT_MB=23040; MIN_BW=300; BOOST=1720; MEMEXP=380 ;;
  V100) EXPECT_MB=32768; MIN_BW=700; BOOST=1530; MEMEXP=900 ;;
  *)    EXPECT_MB=0;     MIN_BW=100; BOOST=0;    MEMEXP=0   ;;
esac

PASS=0; FAIL=0; WARN=0
ok()   { echo "  [OK]   $1"; PASS=$((PASS+1)); }
bad()  { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }
warn() { echo "  [WARN] $1"; WARN=$((WARN+1)); }

stage_info() {
  echo; echo "== [1/5] Базовые параметры: $GPU_NAME =="
  NSMI --query-gpu=name,driver_version,memory.total,temperature.gpu,power.draw,power.limit \
       --format=csv | tee "$LOG_DIR/brief.txt"
  NSMI --query-gpu=pcie.link.gen.current,pcie.link.width.current \
       --format=csv,noheader | tee -a "$LOG_DIR/brief.txt"

  local mem
  mem=$(NSMI --query-gpu=memory.total --format=csv,noheader,nounits | head -1 | tr -d ' ')
  rec mem_total_mb "$mem"
  if [ "$EXPECT_MB" != "0" ] && [ "$mem" -lt "$EXPECT_MB" ]; then
    bad "Память: $mem MB < минимума $EXPECT_MB"
  else
    ok "Память: $mem MB"
  fi

  local gen width
  IFS=',' read -r gen width <<< "$(NSMI --query-gpu=pcie.link.gen.current,pcie.link.width.current --format=csv,noheader | head -1)"
  gen=$(echo "${gen:-?}" | tr -d ' '); width=$(echo "${width:-?}" | tr -d ' ')
  rec pcie_link "Gen${gen} x${width}"
  if [ "$width" = "16" ]; then
    ok "PCIe: Gen${gen} x16"
  else
    warn "PCIe: Gen${gen} x${width} — ожидался x16, проверить слот/riser"
  fi

  local dq="not installed"
  if command -v deviceQuery >/dev/null 2>&1; then
    if deviceQuery > "$LOG_DIR/devicequery.txt" 2>&1; then
      dq="OK"; ok "deviceQuery: OK"
    else
      dq="FAIL"; bad "deviceQuery упал — CUDA не видит карту"
    fi
  fi
  rec devicequery "$dq"
}

stage_ecc() {
  echo; echo "== [2/5] ECC-память =="
  NSMI -q -d ECC > "$LOG_DIR/ecc.txt" 2>&1
  local mode uncorr
  mode=$(grep -Ei 'ECC Status' "$LOG_DIR/ecc.txt" | head -1 | awk -F: '{gsub(/ /,""); print $2}')
  uncorr=$(grep -Ei 'Uncorrectable' "$LOG_DIR/ecc.txt" | grep -oE '[0-9]+' | awk '{s+=$1} END{print s+0}')
  echo "  ECC mode: ${mode:-?} | uncorrectable (всего): $uncorr"
  rec ecc_mode "${mode:-?}"; rec ecc_uncorr "$uncorr"
  case "$mode" in
    Enabled)  ok "ECC включён" ;;
    Disabled) warn "ECC отключён (на Tesla должен быть Enabled)" ;;
    *)        warn "Не распознано ECC — см. $LOG_DIR/ecc.txt" ;;
  esac
  if [ "$uncorr" -gt 0 ]; then
    bad "Есть uncorrectable ECC-ошибки — деградация памяти, RMA"
  else
    ok "Без uncorrectable ECC-ошибок"
  fi
}

stage_diag() {
  echo; echo "== [3/5] dcgmi diag (уровень $DCGM_LEVEL) =="
  if ! command -v dcgmi >/dev/null 2>&1; then
    warn "dcgmi не установлен — пропуск"; rec dcgm "skipped"; return
  fi
  local bus did res
  bus=$(NSMI --query-gpu=pci.bus_id --format=csv,noheader | head -1 | tr -d ' ')
  dcgmi discovery -l > /dev/null 2>&1
  did=$(dcgmi discovery -l 2>/dev/null | awk -v b="$bus" 'index($0,b) && $1 ~ /^[0-9]+\.$/{print $1; exit}')
  [ -n "$did" ] || { bad "dcgmi не видит карту (bus $bus)"; rec dcgm "FAIL"; return; }
  echo "  dcgmi device id: $did"
  dcgmi diag -i "$did" -r "$DCGM_LEVEL" -v 2>&1 | tee "$LOG_DIR/dcgmi_diag.txt"
  if   grep -q '\[FAIL\]' "$LOG_DIR/dcgmi_diag.txt"; then res="FAIL"
  elif grep -q '\[PASS\]' "$LOG_DIR/dcgmi_diag.txt"; then res="PASS"
  else res="UNCLEAR"
  fi
  rec dcgm "$res"
  case "$res" in
    FAIL) bad "DCGM: FAIL — подробности в dcgmi_diag.txt" ;;
    PASS) ok "DCGM: PASS" ;;
    *)    warn "DCGM: результат не распознан — см. dcgmi_diag.txt" ;;
  esac
}

stage_bw() {
  echo; echo "== [4/5] Bandwidth =="
  if ! command -v bandwidthTest >/dev/null 2>&1; then
    warn "bandwidthTest не установлен — пропуск"; rec d2d_bw "skipped"; return
  fi
  bandwidthTest 2>&1 | tee "$LOG_DIR/bandwidth.txt"
  local bw
  bw=$(sed -n 's/.*D2D Bandwidth \([0-9.]*\) GB\/s.*/\1/p' "$LOG_DIR/bandwidth.txt" | head -1)
  if [ -n "${bw:-}" ]; then
    local bi=${bw%.*}
    echo "  D2D: ${bw} GB/s (порог ≥ ${MIN_BW}, номинал ~${MEMEXP})"
    rec d2d_bw "$bw"
    [ "$bi" -ge "$MIN_BW" ] && ok "Пропускная способность в норме" || bad "D2D слишком низкий — проверить слот/riser/коннектор"
  else
    warn "Не удалось распознать D2D в bandwidth.txt"; rec d2d_bw "unparsed"
  fi
}

stage_burn() {
  echo; echo "== [5/5] gpu-burn, ${BURN_SECONDS}с =="
  if ! command -v gpu-burn >/dev/null 2>&1; then
    warn "gpu-burn не установлен — пропуск"
    rec tflops "skipped"; rec max_temp "skipped"; rec max_clock "skipped"
    return
  fi
  [ -f "$COMPARE_FATBIN" ] || warn "compare.fatbin не найден: $COMPARE_FATBIN (gpu-burn упадёт — см. README, Установка)"

  local procs
  procs=$(NSMI --query-compute-apps=pid,process_name --format=csv 2>/dev/null | tail -1 | tr -d ' ')
  [ -n "${procs:-}" ] && warn "На карте уже есть процессы: $procs — тест будет искажён, лучше остановить"

  : > "$LOG_DIR/monitor.csv"
  ( while :; do
      NSMI --query-gpu=temperature.gpu,clocks.sm,power.draw --format=csv,noheader,nounits 2>/dev/null | tr '\n' ',' >> "$LOG_DIR/monitor.csv"
      echo >> "$LOG_DIR/monitor.csv"
      sleep 2
    done ) &
  local mon=$!

  gpu-burn -c "$COMPARE_FATBIN" "$BURN_SECONDS" 2>&1 | tee "$LOG_DIR/gpu_burn.txt"
  kill "$mon" 2>/dev/null; wait "$mon" 2>/dev/null

  local maxt maxc
  maxt=$(awk -F',' '$1 ~ /^[0-9]+$/ {print $1}' "$LOG_DIR/monitor.csv" | sort -n | tail -1)
  maxc=$(awk -F',' '$2 ~ /^[0-9]+$/ {print $2}' "$LOG_DIR/monitor.csv" | sort -n | tail -1)
  maxt=${maxt:-0}; maxc=${maxc:-0}
  echo "  Макс. под нагрузкой: ${maxt}°C, SM ${maxc} MHz"
  rec max_temp "$maxt"; rec max_clock "$maxc"

  if [ "$maxt" -ge 90 ]; then bad "Температура ${maxt}°C — критично (карты пассивные — нужен обдув!)"
  elif [ "$maxt" -ge 80 ]; then warn "Температура ${maxt}°C — повышена"
  else ok "Температура под нагрузкой: ${maxt}°C"
  fi
  if [ "$BOOST" != "0" ] && [ "$maxc" -lt $((BOOST*60/100)) ]; then
    bad "SM clock ${maxc} MHz << номинал ~${BOOST} — троттлинг (питание/тепло)"
  else
    ok "SM clock под нагрузкой: ${maxc} MHz (номинал ~${BOOST})"
  fi
  local tf
  tf=$(grep -oE '[0-9]+\.[0-9]+[[:space:]]*TFLOPS' "$LOG_DIR/gpu_burn.txt" | tail -1 | grep -oE '[0-9]+\.[0-9]+' | head -1)
  if [ -n "${tf:-}" ]; then echo "  gpu-burn: ${tf} TFLOPS"; rec tflops "$tf"; else rec tflops "unparsed"; fi
  grep -q "All tests completed" "$LOG_DIR/gpu_burn.txt" \
    && ok "gpu-burn завершился штатно" || bad "gpu-burn не завершился штатно"
}

stage_xid() {
  echo; echo "== XID-ошибки (kernel log) =="
  local x
  x=$(dmesg 2>/dev/null | grep -i 'xid' | tail -5)
  if [ -n "$x" ]; then
    warn "Найдены XID в dmesg (48=двойной ECC, 63/64=rows HBM, 79=fallback):"
    echo "$x" | sed 's/^/    /'
    rec xid "found"
  else
    ok "XID не найдены (или нет доступа к dmesg)"
    rec xid "none"
  fi
}

run() {
  case "$1" in
    info) stage_info ;; ecc) stage_ecc ;; diag) stage_diag ;;
    bw)   stage_bw   ;; burn) stage_burn ;;
  esac
}

maybe_report() {
  local other other_file
  [ "$GPU_SHORT" = "P40" ] && other=V100 || other=P40
  other_file=$(latest_of "$other")
  if [ -n "$other_file" ]; then
    echo
    echo "== СРАВНЕНИЕ: результат ${other} найден ($other_file) =="
    generate_report "$RESULT_FILE" "$other_file"
  else
    echo
    echo "  (Результат ${other} ещё нет — отчёт сравнения будет сгенерирован"
    echo "   автоматически после второго прогона на второй карте.)"
  fi
}

case "$MODE" in
  quick) BURN_SECONDS=60; run info; run ecc; run bw; run burn ;;
  all)   run info; run ecc; run diag; run bw; run burn ;;
  full)  DCGM_LEVEL=3;    run info; run ecc; run diag; run bw; run burn ;;
  info|ecc|diag|bw|burn)  run "$MODE" ;;
  *)     echo "Использование: $0 {all|quick|full|info|ecc|diag|bw|burn|report}"; exit 2 ;;
esac

stage_xid
rec status "OK:${PASS} WARN:${WARN} FAIL:${FAIL}"

echo
echo "================ ИТОГО: $GPU_NAME ================"
echo "  OK: $PASS   WARN: $WARN   FAIL: $FAIL"
echo "  Метрики: $RESULT_FILE"
echo "  Логи:    $LOG_DIR/"
[ "$FAIL" -gt 0 ] && echo "  >>> НАЙДЕНЫ СБОИ — см. этапы выше <<<"

maybe_report
exit "$FAIL"
