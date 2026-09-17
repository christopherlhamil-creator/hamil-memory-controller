# 4. Tripartite Heterogeneous Architecture

**Lead inventor**: Christopher Hamil  
**This section**: Council Seat 1 (`council-grok`)  
**Grounding (disk-first)**: `src/ebm_governor.zig`, `inventory/EVAL-BRANDYS-XDNA-NPU-STREAM-20260908.md`, `inventory/EVAL-GRAND-FUSION-BENCH-20260908.md`, `inventory/EVAL-BRANDYS-ZEN4-MULTIPROCESS-1M-BENCH-20260908.md`, `inventory/EVAL-EBM-GOVERNOR-POEPATH-20260908.md`

Christopher Hamil’s controller is not a GPU-first inference stack and not a three-silicon “always-on” cluster. It is a **tripartite energy assignment** over one 17,408-byte cell (Invariant A-1) and one 64-byte `=Q16s16s16sII` header (Invariant A-2):

\[
E_{\mathrm{joint}} = E_{\mathrm{NPU}} + E_{\mathrm{CPU}} + E_{\mathrm{GPU}},
\qquad
E_{\mathrm{GPU}} = \varnothing \text{ when } G < 0.0100
\]

as implemented in `src/ebm_governor.zig` (`compose`, `jointEnergy`, `evaluate`). \(E_{\mathrm{GPU}} = 0\) is forbidden on the happy path: zero would mean “the GPU expert agrees,” which corrupts the log-space Product-of-Experts. Skip (\(\varnothing\)) means the GPU expert is **not in the product**.

---

## 4.1 Three silicons, three jobs

| Silicon | Host | Job | What it is *not* |
| :--- | :--- | :--- | :--- |
| **CPU (Zen 4 AVX-512)** | Brandys, Ryzen 7 8700F | In-register A-2 predicates, seqlock ring, spoke scan inside 1 MiB private L2 | A SQL VM; a CUDA runtime |
| **NPU (XDNA 1)** | Brandys `/dev/accel/accel0` | Streaming 17,408 B cells over XRT `xrt::bo` DMA | A 4096-d float EBM bank; a VLM |
| **GPU (Radeon RX 7700 XT, 12 GiB)** | Brandys | **Selective wake** when `b2b` gap \(G \ge 0.0100\) | Default decode path; a place to park KV cache |

Pop-os (Coffee Lake AVX2) remains the **agent loop** host. Brandys is **compute muscle** only: native binaries, XRT, AVX-512. Quiet Hours: occupancy is Linux OpenSSH; port 3389 RDP refused (`inventory/EVAL-BRANDYS-XDNA-NPU-STREAM-20260908.md` §2). Sequential 12 GiB VRAM law: never two large models in that GPU at once.

The NPU topological vector is **4096-bit = 512 B** (`src/b2b_pack.zig` light-packet cap). The fingerprint bank is **4096 × f32 = 16,384 B** (`geometry.EBM_F32_DIM`). Those two “4096”s must not be coerced.

---

## 4.2 CPU AVX-512 — operational hot tier

On Brandys native `znver4` (`inventory/EVAL-BRANDYS-ZEN4-MULTIPROCESS-1M-BENCH-20260908.md`):

- Four OS child processes, `/dev/shm` `SharedCellRing`: **11,459 ops/s** at **7.02 µs** vs SQLite **144 ops/s** at **15,343.8 µs** (**79.7×**).
- 1M-record warm domain spoke: **381,119.3 QPS**, p50 **2,290 ns**, **IPC 2.90**, **LLC misses = 0** over 5,000 queries. The 640 KB spoke fits Zen 4’s 1 MiB private L2.

Coffee Lake remains the worst-case CPU (`inventory/EVAL-1M-QUERY-BENCH-20260908.md`): same geometry, shared 256 KiB L2, 46,396 LLC misses on the warm point arm. The architecture is the cell, not the SKU.

---

## 4.3 NPU 118 GiB/s — cell DMA, not tensor FLOPs

`inventory/EVAL-BRANDYS-XDNA-NPU-STREAM-20260908.md` (100,000 cells, bidirectional host↔device, XRT `libxrt_coreutil.so` + `libxrt_driver_xdna.so.2`, FW 1.5.5.391):

| Metric | Measured |
| :--- | ---: |
| Throughput | **3,644,530 cells/s** |
| Bidirectional bandwidth | **118.174 GiB/s** |
| Mean DMA latency | **252.686 ns** (p50 250 ns, p99 320 ns) |
| Bytes moved | \(100{,}000 \times 17{,}408 \times 2 = 3.48\,\mathrm{GB}\) |
| GPU wakes | **0** (\(E_{\mathrm{GPU}}=\varnothing\)) |
| Thermal \(\Delta\) | CPU 37.0→37.0 °C, GPU edge 34.0→34.0 °C |

This is **cell streaming**, not matrix multiply. Opcode 1001 (`assert_relation`) rides in the 64 B header inside each 17,408 B `xrt::bo`. The GPU fan stays at the locked 2,700 RPM idle curve because the PoE governor never woke it.

---

## 4.4 Selective GPU wake — PoE, not `-ngl`

Hybrid llama.cpp offload (`-ngl`) streams KV tensors across PCIe whenever a layer misses SRAM. Hamil’s governor does the opposite (`src/ebm_governor.zig`):

- `GPU_WAKE_GAP = 0.0100` (identical pin to `b2b_pack.VectorGapPacket.GAP_SILENCE_THRESHOLD`).
- `compose(npu, cpu, gap, gpu_energy)` returns `gpu = null` when `gap < 0.0100`.
- Hard veto **before** `writePositionalAll`: \(E_{\mathrm{joint}} \ge 500\) or hop \(> 4\).

`inventory/EVAL-EBM-GOVERNOR-POEPATH-20260908.md` (Host A, ReleaseFast, 1e6 iters): happy-path evaluate **1.854 ns**; hard veto **0.444 ns**; hop-5 kill **0.360 ns**; a veto leaves the cell file at 17,408 B (zero extra bytes).

`inventory/EVAL-GRAND-FUSION-BENCH-20260908.md` composes intake → boot pack → governor → dual-head swap → IPC ring:

- **1,118,133** intent cycles/s, **894.35 ns/cycle**
- **100,000 / 100,000 GPU happy-path skips (100.00%)**
- **0** dynamic heap bytes
- Hop 5 refused (Invariant A-11)

The 12 GiB Radeon is a **disagreement accelerator**, not a default resident.

---

## 4.5 What this is not

It is not CUDA Unified Memory, not ROCm always-resident weights, not “put the whole agent on the NPU,” and not a rewrite of SQLite onto XDNA. The Semantic Sidecar still drains to ordinary SQLite on the cold path (`src/sqlite_sidecar.zig`). The three silicons share **one cell geometry** and **one energy governor**. That pairing is Christopher Hamil’s.

Cite: [hamil2026cellular], [hamil2026npu], [hamil2026fusion], [hamil2026governor], [hamil2026brandyszen4].
