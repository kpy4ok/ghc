#!/usr/bin/env bash
# install_deps.sh — зависимости для gpu_health_check.sh
# Запуск: sudo ./install_deps.sh
#
# Требование: nvcc из CUDA **12.x** (в 13.x sm_61/sm_70 deprecated — сборка упадёт).
set -e

NVCC="nvcc"

# ---------- выбор nvcc: только 12.x ----------
major_of() { # major_of <nvcc-pуть>
  "$1" --version 2>/dev/null | grep -oE 'release [0-9]+' | awk '{print $2}'
}

if ! command -v nvcc >/dev/null 2>&1; then
  echo "  ERROR: nvcc не найден — установи CUDA toolkit 12.x (например: sudo apt install -y cuda-toolkit-12-6) и повтори"
  exit 1
fi
NVM=$(major_of "$(command -v nvcc)")
if [ "$NVM" = "12" ] || [ "$NVM" = "" ]; then
  : # 12.x — ок; пустое значение разберём ниже по факту проверки
elif [ "$NVM" != "" ] && [ "$NVM" != "12" ]; then
  # в PATH висит nvcc 13.x — ищем 12.x в стандартных местах
  ALT=""
  for d in /usr/local/cuda-12*/bin; do
    [ -x "$d/nvcc" ] && ALT="$d/nvcc" && break
  done
  if [ -n "$ALT" ]; then
    NVCC="$ALT"
    echo "  nvcc из PATH: $(command -v nvcc) (CUDA $NVM) — подмена на $NVCC"
  else
    echo "  ERROR: nvcc в PATH — CUDA $NVM, а нужен 12.x (sm_61/sm_70). Поставь cuda-toolkit-12-6 и повтори."
    exit 1
  fi
fi
NVCC_VER=$("$NVCC" --version 2>/dev/null | grep -oE 'release [0-9]+\.[0-9]+' | head -1)
echo "  nvcc: $NVCC ($NVCC_VER)"

echo "== 1/3 DCGM (аппаратная диагностика) =="
if command -v dcgmi >/dev/null 2>&1; then
  echo "  dcgmi уже есть: $(command -v dcgmi)"
else
  apt-get update
  apt-get install -y datacenter-gpu-manager
fi

echo "== 2/3 CUDA samples: deviceQuery + bandwidthTest =="
apt-get install -y git make g++
rm -rf /tmp/cuda-samples
# v12.6.0 — последняя ветка с полной поддержкой sm_61/sm_70
git clone --depth 1 --branch v12.6.0 https://github.com/NVIDIA/cuda-samples /tmp/cuda-samples
(cd /tmp/cuda-samples/Samples/deviceQuery   && make -j)
(cd /tmp/cuda-samples/Samples/bandwidthTest && make -j)
install -m755 /tmp/cuda-samples/Samples/deviceQuery/deviceQuery   /usr/local/bin/
install -m755 /tmp/cuda-samples/Samples/bandwidthTest/bandwidthTest /usr/local/bin/

echo "== 3/3 gpu-burn  Stress test=="
rm -rf /tmp/gpu-burn
git clone --depth 1 https://github.com/wilicc/gpu-burn /tmp/gpu-burn
(cd /tmp/gpu-burn && make)
# Makefile по умолчанию шьёт fatbin под compute_75 — перешить под Pascal+Volta:
(cd /tmp/gpu-burn && "$NVCC" -O3 -fatbin compare.cu -o compare.fatbin \
   -gencode arch=compute_61,code=sm_61 -gencode arch=compute_70,code=sm_70)
install -m755 /tmp/gpu-burn/gpu_burn /usr/local/bin/gpu-burn
# gpu-burn грузит ядро пути, заданного -c (по умолчанию относительный compare.fatbin),
# поэтому fatbin ставим в отдельное место, а не рядом с бинарником:
mkdir -p /usr/local/share/gpu-burn
install -m644 /tmp/gpu-burn/compare.fatbin /usr/local/share/gpu-burn/

echo "== 4/4 Самопроверка =="
echo "  deviceQuery:"
deviceQuery -c 0 || echo "  WARNING: deviceQuery не прошёл — проверь CUDA/драйвер"
echo "  bandwidthTest (D2D строка):"
bandwidthTest 2>/dev/null | grep 'D2D Bandwidth' || echo "  WARNING: bandwidthTest не отдал D2D"
echo "  dcgmi discovery:"
dcgmi discovery -d -l 2>&1 | head -20 || echo "  WARNING: dcgmi не работает"

echo; echo "Готово. Далее: ./gpu_health_check.sh"
