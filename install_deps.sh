#!/usr/bin/env bash
# install_deps.sh — зависимости для gpu_health_check.sh
# Запуск: sudo ./install_deps.sh
set -e

echo "== 1/3 DCGM (аппаратная диагностика) =="
if command -v dcgmi >/dev/null 2>&1; then
  echo "  dcgmi уже есть"
else
  apt-get update
  apt-get install -y datacenter-gpu-manager
fi

echo "== 2/3 CUDA samples: deviceQuery + bandwidthTest =="
if ! command -v nvcc >/dev/null 2>&1; then
  echo "  WARNING: nvcc не найден — пропуск (нужен CUDA toolkit 12.x)"
else
  apt-get install -y git make g++
  rm -rf /tmp/cuda-samples
  # v12.6.0 — последняя ветка с полной поддержкой sm_61/sm_70
  git clone --depth 1 --branch v12.6.0 https://github.com/NVIDIA/cuda-samples /tmp/cuda-samples
  (cd /tmp/cuda-samples/Samples/deviceQuery   && make -j)
  (cd /tmp/cuda-samples/Samples/bandwidthTest && make -j)
  install -m755 /tmp/cuda-samples/Samples/deviceQuery/deviceQuery   /usr/local/bin/
  install -m755 /tmp/cuda-samples/Samples/bandwidthTest/bandwidthTest /usr/local/bin/
fi

echo "== 3/3 gpu-burn  Stress test=="
rm -rf /tmp/gpu-burn
git clone --depth 1 https://github.com/wilicc/gpu-burn /tmp/gpu-burn
(cd /tmp/gpu-burn && make)
(cd /tmp/gpu-burn && nvcc -O3 -fatbin compare.cu -o compare.fatbin \
   -gencode arch=compute_61,code=sm_61 -gencode arch=compute_70,code=sm_70)
install -m755 /tmp/gpu-burn/gpu_burn /usr/local/bin/gpu-burn
mkdir -p /usr/local/share/gpu-burn
install -m644 /tmp/gpu-burn/compare.fatbin /usr/local/share/gpu-burn/

echo; echo "Готово. Далее: ./gpu_health_check.sh"
