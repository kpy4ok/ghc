# GPU Health Check — Tesla P40 / V100

Проверка «живости» серверных карт NVIDIA **Tesla P40 (24 GB)** и **Tesla V100 (32 GB)**
в связке «карта + слот + riser + охлаждение» и автоматическое сравнение двух карт
в одном отчёте.

Подходит для:
- приёмки б/у Tesla-карт (до покупки — на месте, после — в сервере);
- периодического контроля ферма/рабочей станции (ECC, XID, троттлинг);
- диагностики: «карта вставляется, но вылетает / тормозит / греется».

Проверяются **только** параметры карты и её подключения — никаких игровых/3D-тестов:
обе карты без видеовыхода, с пассивным охлаждением.

---

## Содержание

1. [Сравнение карт (что ожидать)](#1-сравнение-карт-что-ожидать)
2. [Что проверяет скрипт](#2-что-проверяет-скрипт)
3. [Требования](#3-требования)
4. [Установка](#4-установка)
5. [Использование](#5-использование)
6. [Результаты и файлы](#6-результаты-и-файлы)
7. [Ожидаемые значения и пороги](#7-ожидаемые-значения-и-пороги)
8. [Диагностика ошибок](#8-диагностика-ошибок)
9. [Структура репозитория](#9-структура-репозитория)

---

## 1. Сравнение карт (что ожидать)

| Параметр | Tesla P40 | Tesla V100 32GB |
|---|---|---|
| Архитектура | Pascal (sm_61, CC 6.1) | Volta (sm_70, CC 7.0) |
| Память | 24 GB GDDR5 | 32 GB HBM2 |
| Видна nvidia-smi как | **23040 MiB** (1536 MiB — под ECC/драйвер) | **32768 MiB** |
| Пропускная способность памяти | ~384 GB/s | ~900 GB/s |
| D2D bandwidth (test) | 340–380 GB/s | 830–900 GB/s |
| FP32 (пик) | ~6.8 TFLOPS | ~15.7 TFLOPS |
| SM boost clock | 1720 MHz | 1530 MHz |
| GPU-burn | ~8000–9000* | ~9500–11000* |
| Потребление (номинал) | 250 W | 250–300 W |
| PCIe | Gen3 x16 | Gen3 x16 |
| Tensor-ядра | нет | есть |

\* gpu-burn считает операции с «экстраполированным» счётчиком для матрицы 8192×8192,
поэтому значения могут быть выше пиковых TFLOPS карты — это особенность метрики,
важно сравнивать **карту с собой во времени** и **карту с картой**, а не с даташитом.

> **Ожидаемые соотношения (V100 / P40)**: D2D bandwidth ≈ 2.3, gpu-burn ≈ 1.1–1.3.
> Значительно меньший разрыв — повод проверить карту в правом столбце отчёта.

---

## 2. Что проверяет скрипт

Каждый этап помечается `[OK]` / `[WARN]` / `[FAIL]`; итог — число FAIL (exit code).

| # | Этап | Что делает | OK | FAIL / WARN |
|---|---|---|---|---|
| 1 | **Базовые параметры** | nvidia-smi: имя, память, PCIe-линк; `deviceQuery` | память ≥ номинала; PCIe x16 (Gen ≥ 2) | меньше памяти → FAIL; PCIe Gen1 или < x16 → WARN (слот/riser) |
| 2 | **ECC** | `nvidia-smi -q -d ECC`: режим, uncorrectable (volatile+aggregate) | Enabled, 0 uncorrectable | uncorrectable > 0 → **RMA**; ECC Disabled → WARN; N/A (580.x, Pascal) → WARN |
| 3 | **DCGM-диагностика** | `dcgmi diag -r 2/3` — аппаратная диагностика NVIDIA (память, SM, PCIe, питание) | `[PASS]` | `[FAIL]` → подробности в `dcgmi_diag.txt` |
| 4 | **Bandwidth** | CUDA sample `bandwidthTest`, D2D-копирование | ≥ порога (P40: 300, V100: 700 GB/s) | ниже порога → **проблемы со слотом/riser/коннектором** |
| 5 | **gpu-burn** | GEMM-нагрузка + параллельный мониторинг temp/SM-частоты/power каждые 2 с | temp < 80°C; SM clock ≥ 60% номинала; exit 0 и без «FAILED» | ≥ 90°C → FAIL; частота << номинала → троттлинг (тепло/питание); частота не читается (N/A) → WARN |
| — | **XID** | поиск `Xid` в `dmesg` | нет записей | Xid 48/63/64 → деградация памяти (RMA), 79 → fallback-ошибки |

Пороги «слабой» проверки: `BURN_SECONDS` (длительность нагрузки), `DCGM_LEVEL`
(2 = быстрый прогон, 3 = полный, ~30 мин) — см. §5.

---

## 3. Требования

| Компонент | Требование | Примечание |
|---|---|---|
| ОС | Linux (Ubuntu/Debian) | под другие distro установка повторяется руками |
| Драйвер | **ветка 580.x — последняя с поддержкой Pascal/Volta** | в 580.x `nvidia-smi` для P40 вырезал часть ECC-полей — парсится текстовый `-q -d ECC`, это учтено. Не обновляйтесь на следующий мажор без проверки. |
| CUDA toolkit | **12.x** (рекомендуется 12.6) | нужен только для **сборки** `deviceQuery`/`bandwidthTest`/fatbin. В CUDA 13 sm_61/sm_70 deprecated — сборка упадёт с `unsupported gpu architecture`. |
| Права | `sudo` — только для `install_deps.sh` | сам `gpu_health_check.sh` работает без root (кроме dmesg — будет WARN при отсутствии доступа) |
| Охлаждение | **внешний обдув обязателен** | обе карты пассивные; без обдува троттлинг/сброс частот |
| Питание | 250–300 Вт по rail | проверить `power.limit` в выводе [1/5] |
| Карта | одна или несколько | при нескольких — `GPU_IDX` (§5) |

Проверка текущей версии:

```bash
nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv
nvcc --version | tail -2
```

---

## 4. Установка

```bash
git clone https://github.com/kpy4ok/ghc
cd ghc
sudo ./install_deps.sh
```

Что ставится и куда:

| Шаг | Инструмент | Куда | Зачем |
|---|---|---|---|
| 1 | `datacenter-gpu-manager` (dcgmi) | apt | аппаратная диагностика (этап 3) |
| 2 | `deviceQuery`, `bandwidthTest` (CUDA samples v12.6.0) | `/usr/local/bin/` | этап 1 (deviceQuery) и 4 (bandwidth) |
| 3 | `gpu-burn` (wilicc) | бинарник → `/usr/local/bin/gpu-burn`, **`compare.fatbin` → `/usr/local/share/gpu-burn/`** | этап 5 |

> **Важно про gpu-burn**: программа грузит CUDA-ядро из файла, имя которого задано
> флагом `-c` (по умолчанию относительный путь `compare.fatbin` в cwd). Поэтому:
> - `compare.fatbin` **не ставится** рядом с бинарником, а в отдельную директорию;
> - `install_deps.sh` пересобирает fatbin под `sm_61 + sm_70` (стандартный Makefile
>   шьёт его под `compute_75` — на Pascal/Volta gpu-burn упадёт с
>   `couldn't find compare kernel … named symbol not found` / `DIED`);
> - `gpu_health_check.sh` запускает gpu-burn с `-c /usr/local/share/gpu-burn/compare.fatbin`,
>   поэтому работает из любой директории.

Перезапускать `install_deps.sh` безопасно (idempotent). Проверить установку:

```bash
deviceQuery -c 0        # видит карту
bandwidthTest           # печатает таблицу с D2D Bandwidth
gpu-burn -c /usr/local/share/gpu-burn/compare.fatbin 10   # таблица (Gflop/s) + "GPU 0: OK"
```

---

## 5. Использование

```bash
./gpu_health_check.sh [режим]
```

### Режимы

| Режим | Суть | Время |
|---|---|---|
| `quick` | info + ECC + bandwidth + gpu-burn 60 с | ~3–5 мин |
| `all` (по умолчанию) | то же + `dcgmi diag -r 2` | + ~5–10 мин |
| `full` | то же + `dcgmi diag -r 3` (полная диагностика) | + ~30 мин |
| `info` / `ecc` / `diag` / `bw` / `burn` | отдельный этап | — |
| `report [fileA fileB]` | пересобрать отчёт-сравнение (GPU не требуется) | мгновенно |

### Переменные окружения

| Переменная | По умолчанию | Назначение |
|---|---|---|
| `GPU_IDX` | `0` | индекс карты (при нескольких: `GPU_IDX=0`, `GPU_IDX=1`, …) |
| `BURN_SECONDS` | `120` | длительность gpu-burn (в `quick` принудительно 60) |
| `DCGM_LEVEL` | `2` | уровень `dcgmi diag` (2 — быстрый, 3 — полный) |
| `RES_DIR` | `./gpu_results` | каталог результатов/логов |
| `COMPARE_FATBIN` | `/usr/local/share/gpu-burn/compare.fatbin` | путь к fatbin для gpu-burn |

### Типичный сценарий: сравнение двух карт

```bash
# P40 — карта 0, V100 — карта 1 (проверить индексы: nvidia-smi -L)
GPU_IDX=0 ./gpu_health_check.sh quick     # пишет result_P40_<ts>.jsonl
GPU_IDX=1 ./gpu_health_check.sh quick     # пишет result_V100_<ts>.jsonl
                                         # → автоматически генерирует gpu_compare_report.md

# при необходимости — полный прогон:
GPU_IDX=0 ./gpu_health_check.sh full
GPU_IDX=1 ./gpu_health_check.sh full

# пересобрать отчёт из конкретных прогонов (без повторных тестов):
./gpu_health_check.sh report gpu_results/result_P40_20261006_081400.jsonl \
                              gpu_results/result_V100_20261006_083000.jsonl
```

**Подготовка перед прогоном** (скрипт предупреждает, но не останавливает чужие процессы):

```bash
nvidia-smi --query-compute-apps=pid,process_name --format=csv   # кто сидит на карте
# остановить лишнее; при возможности: nvidia-smi --gpu-reset -i 0
```

---

## 6. Результаты и файлы

После каждого прогона в `$RES_DIR`:

```
gpu_results/
├── result_P40_20261006_081400.jsonl     # метрики прогона (JSON lines)
├── result_V100_20261006_083000.jsonl
├── logs_P40_20261006_081400/            # сырые логи
│   ├── brief.txt                        #   nvidia-smi (имя/память/PCIe)
│   ├── devicequery.txt                  #   deviceQuery
│   ├── ecc.txt                          #   nvidia-smi -q -d ECC
│   ├── dcgmi_diag.txt                   #   вывод dcgmi diag
│   ├── bandwidth.txt                    #   bandwidthTest
│   ├── gpu_burn.txt                     #   gpu-burn
│   └── monitor.csv                      #   temp,clock,power каждые 2 с
└── gpu_compare_report.md                # авто-сборка после 2-го прогона
```

`result_*.jsonl` — по строке на метрику: `{"gpu":"Tesla P40","run":"…","key":"d2d_bw","value":"371.2"}`.

### Пример `gpu_compare_report.md`

| Метрика | Tesla P40 | Tesla V100-SXM2-32GB |
|---|---|---|
| Прогон (run id) | 20261006_081400 | 20261006_083000 |
| Память, MB | 23040 | 32768 |
| PCIe линк | Gen3 x16 | Gen3 x16 |
| ECC uncorrected | 0 | 0 |
| DCGM diag | PASS | PASS |
| D2D bandwidth, GB/s | 371.2 | 864.5 |
| gpu-burn, TFLOPS | 5.12 | 10.8 |
| Макс. температура, °C | 74 | 78 |
| SM clock, MHz | 1705 | 1518 |
| Итог | OK:9 WARN:0 FAIL:0 | OK:9 WARN:0 FAIL:0 |

В P40 всегда в левом столбце; ниже — столбец соотношений (правый/левый).

---

## 7. Ожидаемые значения и пороги

| Метрика | P40: OK | V100: OK | Что значит отклонение |
|---|---|---|---|
| Память | ≥ 23040 MB | ≥ 32768 MB | меньше — карта «урезана»/подмена |
| PCIe | Gen3 x16 | Gen3 x16 | < x16 → riser/слот/коннектор |
| ECC uncorrectable | 0 | 0 | > 0 → **RMA** |
| D2D bandwidth | 340–380 GB/s | 830–900 GB/s | << порог (300/700) → PCIe/слот. На **Gen1** P40 будет ~200–250 → FAIL — это деградация линка, а не карты |
| gpu-burn | ~8000–9000 | ~9500–11000 | ниже на 20%+ → троттлинг/б/у деградация |
| Температура (обдув) | < 80°C | < 80°C | ≥ 90°C → обдув/термоинтерфейс |
| SM clock под нагрузкой | ~1720 MHz (мин. 60% = 1030) | ~1530 MHz (мин. 60% = 920) | << номинал → тепло/питание |
| Драйвер | 580.x | 580.x | см. §3 |

Если на повторном прогоне **одна и та же карта** просела по bandwidth/TFLOPS/температуре
относительно первого прогона — это маркер деградации (термоинтерфейс, riser, память).

---

## 8. Диагностика ошибок

| Симптом | Причина | Решение |
|---|---|---|
| gpu-burn: `couldn't find compare kernel: compare.fatbin … named symbol not found` → `DIED` | gpu-burn ищет fatbin **в cwd**, а его там нет; **или** fatbin собран под чужую архитектуру (Makefile по умолчанию — compute_75) | запускать через скрипт (ставит `-c /usr/local/share/gpu-burn/compare.fatbin`) или вручную: `gpu-burn -c /usr/local/share/gpu-burn/compare.fatbin 10`. Если из исходной директории `/tmp/gpu-burn` работает, а отсюда нет — точно путь к fatbin |
| `unsupported gpu architecture 'compute_61'/'compute_70'` при сборке | CUDA 13.x toolkit — sm_61/sm_70 deprecated | поставить `cuda-toolkit-12-6` и собирать его `nvcc` |
| `named symbol not found` при сборке fatbin, `nvcc` из CUDA 12 | источник собран/пересобран с ошибкой | убедиться, что использован именно `nvcc` из 12.x: `/usr/local/cuda-12.6/bin/nvcc -O3 -fatbin compare.cu -o compare.fatbin -gencode arch=compute_61,code=sm_61 -gencode arch=compute_70,code=sm_70` |
| nvidia-smi: `Field "ecc.errors.corrected.volatile" is not a valid field to query` | драйвер 580.x вырезал query-поля ECC для Pascal/Volta | не баг: скрипт парсит текстовый `nvidia-smi -q -d ECC` |
| Память 23040, а «должно 24576» | 1536 MiB заняты ECC/драйвером — **норма для P40** | порог в скрипте: `EXPECT_MB=23040` |
| D2D bandwidth низкий, всё остальное в норме | PCIe-линк не x16 (x1/x4), плохой riser/коннектор | `nvidia-smi -q -d PCIe`, переставить в другой слот, другой riser |
| SM clock << номинал, температура высокая | троттлинг: нет обдува / плохой термоинтерфейс / лимит питания | обдув; `nvidia-smi -q -d POWER` (Power Limit), `clocks_event_reasons.active` |
| Xid 48 / 63 / 64 в dmesg | ошибки памяти (двойной ECC / bad page, на V100 — HBM) | RMA |
| Xid 79 | GPU fell back to slower mode (частичная смерть памяти/ядер) | RMA / замена |
| `No clients are alive! Aborting` без других ошибок | gpu-burn упал на init — см. `named symbol not found` выше | — |
| `Initialized device 0 … (1147 MB available)` — свободной памяти мало | на карте сидит другой процесс | `nvidia-smi --query-compute-apps=...`, остановить; тесты искажаются |
| `dcgmi` не видит карту («dcgmi не видит карту (bus …)») | (а) DCGM несовместим с версией драйвера/не перезапущен; (б) bus-id карты не отображается в discovery | руками: `sudo dcgmi discovery -d -l` — карта в списке с `Id:`? Если нет: `sudo apt-get install --reinstall datacenter-gpu-manager`, при необходимости выбрать ветку DCGM под драйвер. Если да — id выводится скриптом по строке GPU |
| `dcgmi diag` стартует, но сразу падает/не видит GPU (apt-DCGM + новый драйвер) | ветка DCGM из apt не покрывает мажор драйвера (у вас: 580.x) | посмотреть `dcgmi --version` и версию DCGM в репозитории; если несовместимо — собрать DCGM под ветку драйвера или отложить этап diag (остальные этапы не зависят от него) |
| D2D bandwidth ~200–250 GB/s на P40, всё остальное в норме | PCIe-линк деградировал до Gen1 (номинал Gen3 x16 даёт 340–380) | `nvidia-smi -q -d PCIe` (Max Link Width), переставить в другой слот/riser, проверить коннектор — карта не виновата |
| Скрипт пишет «На карте уже есть процессы: pid,process_name», хотя nvidia-smi пуст | ложный триггер на заголовок CSV (исправлено в fix/stages-parsing) | запрос `--query-compute-apps` теперь с `--format=csv,noheader`; при новом коде предупреждение появляется только при реальных процессах |
| `SM clock 0 MHz` в отчёте burn | поле `clocks.sm` отдаёт `N/A` (частично вырезано в 580.x на Pascal) | не троттлинг: скрипт берёт fallback `clocks.gr`, а при нуле — WARN «частота не измерена», не FAIL |
| ECC: режим `?`, `uncorrectable: N/A` | форма вывода `-q -d ECC` отличается от обеих известных (parser понимает 580.x: `Current` + `Single Bit`/`Double Bit`, и классическую) | посмотреть `logs_*/ecc.txt` руками; секции есть — расширить `sum_uncorr` под новую форму |
| `nvidia-smi не видит карту` | карта не инициализирована (после reset/BIOS) | перезагрузка, перестановка, `dmesg | grep -i nvidia` |
| `bandwidthTest`/`deviceQuery` не нашлись | шаг 2 install_deps пропущен (нет nvcc) | установить CUDA 12.x toolkit, повторить `install_deps.sh` |

**Эталонные коды XID** (частые): 48 — double-bit ECC; 63 — row remapping; 64 — row
remapping failed; 79 — fallback; 119/120 — GSP/ECC-апплеты (на Volta).

---

## 9. Структура репозитория

```
ghc/
├── README.md               # этот файл
├── install_deps.sh         # установка зависимостей (sudo): dcgmi, CUDA samples, gpu-burn + fatbin
├── gpu_health_check.sh     # основной скрипт: 5 этапов + XID + авто-отчёт
└── gpu_results/            # (после запуска) метрики, логи, gpu_compare_report.md
```

### Ссылки
- [wilicc/gpu-burn](https://github.com/wilicc/gpu-burn) — стресс-тест GEMM
- [NVIDIA/cuda-samples](https://github.com/NVIDIA/cuda-samples) — `deviceQuery`, `bandwidthTest`
- [NVIDIA DCGM](https://docs.nvidia.com/datacenter/dcgm/latest/user-guide/index.html) — `dcgmi diag`
