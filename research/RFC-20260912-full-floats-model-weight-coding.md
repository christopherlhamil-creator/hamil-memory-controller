# Full Floats Are the Model: Compiling Weight Coding onto a 17,408-Byte Cell

**Lead Author:** Christopher Hamil  
**Affiliation:** Tree of Thoughts Hybrid Systems Laboratory  
**Date:** September 2026  
**Status:** DRAFT — measurements NEEDS WORK; agents do not decide done  
**Companion to:** The Hamil Memory Controller (memory plane). This manuscript is the engine-plane weight cut.

## Abstract

A weight-container path was measured for Qwen2.5-Coder-7B-Instruct on one host. The design retains the 20,480 B Record and 17,408 B cell geometry while the owned file identity is `.chpe` (`CHPE`, `0x45504843`); ISO WARC/1.0 is a historical binary-record label, not the owned type. W2 stores two four-bit values per byte and reconstructs floating-point weights at GEMV time. On the current native `.chpe` flag-128 tail, token 0 returns argmax **75311**, RMS **0.000014**, and retains the BF16 oracle result. The earlier group-N WARC figures, including 0.209801, remain measured mill history rather than the live reader. The current cut also measures tokenizer identity and overflow refusal, KV as four 17,408 B Records per token, GQA attention, RoPE, and an L0 `o_proj` parity path. The residual mill is written but not EVALed; RMSNorm, MLP, the 28-layer loop, and sampler are not claimed landed. llama.cpp Q6_K RMS 0.103875 remains their residual, not a target. This is a measured direction, not production readiness or a finished engine.

## 1. Introduction

The motivating observation is simple: models need their floating-point work. Christopher Hamil states it directly:

> “yes the reason i asked what weights are coded in is the same reason i asked how models work. models need the full floating points”

The observation changes the question asked of quantization. A file format is not the model. A codebook, nibble stream, block scale, or packed tensor is a container at the door of the computation. The computation still consumes reconstructed values in float arithmetic. This paper studies the boundary where that container becomes an owned runtime representation: a weight record whose geometry is chosen together with the machine geometry in which it is read.

The second design premise is ownership rather than mere compatibility:

> “no it my request to build a custom everything, I'm using cactus as my steping ground into making my own custom system from the ground up so no one owns even the engine”

Cactus is consequently treated here as a stepping ground and a source of implementation lessons, not as the owned engine. The historical experiment used a Python packer outside `src/`, a memory-mapped WARC, and a Zig runtime with a W2 GEMV path. The current cut adds measured `.chpe` tokenizer, KV, attention, RoPE, and weight-tail seams, but does not claim that the complete end-to-end engine is landed. The residual, RMSNorm, MLP, 28-layer loop, and sampler remain outside the measured claims.

The geometry is deliberate:

> “If everything is done to the same geometry from the initial compiling you are not glue pieces togethere you are optimizing the paths, the compatability is that i use ISA.”

The memory plane uses 17,408 B cells, equal to 272 cache lines of 64 B. The engine plane tested here uses a 20,480 B record, five 4,096 B pages, containing a 3,072 B prefetch region and a 17,408 B cell. Its coded tile is 16,384 B, leaving a 960 B semantic payload. This arrangement does not make the planes identical; it gives them a shared physical unit around which I/O, mapping, and dispatch can be organized.

Finally:

> “if we control every piece then we can actually optimize it”

The paper therefore reports the pieces separately. It distinguishes BF16 warehouse values, WARC/W2 coding, and llama.cpp Q6_K decoding. It records the host and device for every timing. It does not collapse different devices into a speed claim, and it does not turn an argmax match into a claim of numerical parity.

The central question is narrow: can coding fit the chosen geometry while preserving useful model behavior on a measured token? The answer is now split between historical WARC mills and the live `.chpe` identity. Scalar and group-N coding experiments remain valuable scars: they show that byte fit and argmax preservation are not enough. The current BF16-tail retarget instead measures 75311 / 0.000014, while the tokenizer, KV, attention, RoPE, and L0 `o_proj` seams have named proofs. More coding is not automatically tighter, and the remaining un-EVALed forward stages stay UNKNOWN.

## 2. Containers are not models

GGUF, safetensors, and codebook formats address different parts of the boundary. GGUF is a model distribution and metadata container commonly associated with GGML/llama.cpp block quantization. The relevant Q6_K path uses super-block structures and stores quantized values with scales and auxiliary parameters. Those blocks are useful engineering units, but their existence does not establish the geometry of an owned engine. The file becomes a kernel ABI only when the runtime promises to consume its layout directly. That distinction is the boundary under test here. The GGML/GGUF documentation and implementation are related work, not evidence that WARC is equivalent to GGUF [UNSOURCED].

Safetensors is an unquantized, sharded warehouse for tensor data and metadata. The Qwen BF16 source used in this work occupied four shards totaling 15,231,271,864 B. Safetensors preserves the source representation needed by an oracle and by a packer, but it is not the runtime representation tested here. There is no safetensors parser in the WARC engine. The packer reads BF16 outside the runtime and emits records with the WARC layout. Thus “BF16 oracle” means the comparison path, not a claim that the production WARC reader carries BF16 shards.

GPTQ and AWQ are related post-training quantization approaches for compressing a warehouse into lower-precision weights. They demonstrate that coding can be made sensitive to model behavior, calibration, and tensor structure. They do not answer the local layout question: how should a coded weight tile fit a 16,384 B fingerprint region beside a 17,408 B memory cell, and how should a C ABI expose that tile to a Zig orchestrator? Those methods are cited as quantization context, not as measurements of this engine [UNSOURCED].

Cactus-compute CQ is another adjacent coding system. Its CQ4 path uses a different coding, including Walsh–Hadamard and codebook operations. The repository retains a Cactus HIP symbol named `cactus_hip_cq4_gemv` for CQ4 tiles. That symbol is not launched on WARC/W2 bytes. Running CQ4 on W2 would conflate two representations and would turn a coding distinction into an ABI bug. Cactus is the stepping ground in this work: a useful experimental environment from which an owned engine can be built, not the name of the owned container.

The memory-plane companion describes the 17,408 B cell, 64 B header, and relational sidecar once. This paper uses that geometry as an input constraint and then leaves the database result behind. The engine question is weights, coding, mapping, and model-output fidelity. A cell is not a tensor tile, and a WARC record is not a database row.

## 3. WARC record geometry

The historical WARC record is 20,480 B, or five 4,096 B pages. Its first 3,072 B are a prefetch region. The remaining 17,408 B align with the cell geometry: 272 × 64 B. Within that record, the coded tile occupies 16,384 B. The remaining semantic payload is 960 B. These are exact byte budgets, not rounded capacities. The owned extension identity in the current cut is `.chpe`, ASCII `CHPE`, little-endian magic `0x45504843`; ISO WARC/1.0 text remains a record/container history label and is not the owned file type.

The four-bit W2 law is:

```text
q0 = b & 0x0F
q1 = b >> 4
f  = (q - 8) * scale + bias
```

One 16,384 B tile has 32,768 four-bit values, hence capacity for 32,768 floats after reconstruction. The packer refuses a tile for which `rows * cols > 32768`. Overflow splits; it is never silently truncated. This is important for the model because matrix shapes do not share one safe tile class. A layout that fits one projection can fail for another.

Group-32 W2 stores a scale and bias for every group of 32 values. For `down_proj` with shape 1 × 18,944, the measured budget is 9,472 nibble bytes plus 592 pairs of scale and bias, totaling 14,208 B, which fits within 16,384 B. At width 3,584, the group-32 budget is `R * 2688` bytes. The inequality `R * 2688 ≤ 16384` permits `R ≤ 6`. Since `3584%6=2`, 3,584-wide tensors use `R=4`, not `R=6`; `18944%4=0`. The 152064-row `lm_head` uses `R=6` because `152064%6=0`. A 9 × 3,584 tile requires 16,128 nibble bytes plus 8,064 scale bytes, totaling 24,192 B. It does not fit. The correct operation is retile or split, not a prose exception and not truncation.

Group-16 is a distinct measured layout. At four rows of width 3,584 it uses 7,168 nibble B + 896×8 scale/bias B = 14,336 B, which fits within 16,384 B. Group-8 at four rows does not fit: its measured budget is 21,504 B. Group-8 at three rows fits at 16,128 B and is legal for `lm_head` because `152064%3=0`; group-8 at two rows fits at 10,752 B and is legal for L26 `gate` because `18944%2=0`. Group-4 fits at one row, as used by embed, and group-2 fits at one row, as used by the later `lm_head` tail. The coding flags are bits 0–4: group-32=`1`, group-16=`2`, group-8=`4`, group-4=`8`, group-2=`16`. `@popCount(flags & 31) > 1` refuses mixed bits.

This geometry also defines the language boundary. The runtime is Zig; the low-level coding and GEMV entry points cross a C ABI. The packer is currently Python and is outside `src/`. That is an explicit transitional boundary. It is not evidence that Python, the Cactus CQ4 ABI, and WARC are one engine. The objective is to compile the incoming representation into a stable owned layout, then measure the runtime path against an oracle.

## 4. Methods

### Model and inputs

The model was `Qwen2.5-Coder-7B-Instruct`. Its BF16 safetensors source comprised four shards totaling 15,231,271,864 B. The model has hidden size 3584, 28 layers, GQA 28/4, vocabulary size 152,064, `tie_word_embeddings=false`, `rms_norm_eps=1e-6`, `rope_theta=1e6`, `add_bos=false`, and `bos_token_id=151643`. The historical WARC mill archive at the GATE-L26-G8 stage was 23,329,611,776 B with 1,139,141 records. The later BF16 split/retarget mill ledger is 64368254976 B with 3142981 records; the live tail and unread history are described in the dated cut below. Record 0 remained unchanged: `368ea8f6c75a0ecd665cc15a14fe1991644e3ac8ac7222a788d0736ddf1757ee`.

The archive was extended in measured stages rather than collapsed to a single final size. After in-place group-32 `down_proj`, it was 5,687,320,576 B / 277,701 records. Adding group-32 `lm_head` produced 5,860,335,616 B / 286,149 records. Adding group-32 `v_proj` and `o_proj` produced 6,447,538,176 B / 314,821 records. The group-32 gate tail produced 9,163,350,016 B / 447,429 records. The group-16 L26 gate tail produced 9,260,343,296 B / 452,165 records. The group-32 `up_proj` tail produced the final 11,976,155,136 B / 584,773 records. Overflow is therefore visible in record accounting; old records remain unreferenced when a tail is split.

The final native stack at that historical stage was: group-4 embed at records 825541..977604 with flags 8; group-2 `lm_head` at 977605..1129668 with flags 16; group-32 gate at L0–L25 and L27; group-8 gate at L26 in records 1129669..1139140 with flags 4; group-32 `up` at 452165..584772; and group-32 `down_proj`, `v_proj`, and `o_proj`, including g32 `o` L0 at 286149..287044. The prior group-16 L26 tail 447429..452164 and unused g32 L26 records 437957..442692 remained unreferenced. `q_proj` and `k_proj` remained scalar-scale. REST-CLASS-4 did not recode any tile; group-16 `o_proj` native RMS was UNKNOWN.

The comparison file was the Q6_K GGUF, 6,254,198,752 B. All reported model-output measurements used `token_id = 0`, position 0, with no extra BOS. This is a seq_len=1, position-zero test, not a broad language benchmark.

Archive growth was measured at each tail:

| after | bytes | records |
| :--- | ---: | ---: |
| g32 `down_proj` in-place | 5,687,320,576 | 277,701 |
| + g32 `lm_head` | 5,860,335,616 | 286,149 |
| + g32 `v`+`o` | 6,447,538,176 | 314,821 |
| + g32 `gate` tail | 9,163,350,016 | 447,429 |
| + g16 L26 `gate` tail | 9,260,343,296 | 452,165 |
| + g32 `up` tail | 11,976,155,136 | 584,773 |
| + g16 `lm_head` | 12,754,722,816 | 622,789 |
| + g8 `lm_head` | 13,792,813,056 | 673,477 |
| + g4 `lm_head` | 16,907,083,776 | 825,541 |
| + g4 embed | 20,021,354,496 | 977,605 |
| + g2 `lm_head` | 23,135,625,216 | 1,129,669 |
| + g8 L26 `gate` | **23,329,611,776** | **1,139,141** |

Rec 0 sha256 is unchanged: `368ea8f6c75a0ecd665cc15a14fe1991644e3ac8ac7222a788d0736ddf1757ee`.

### Paths and hardware

The BF16 oracle used the same Zig graph and the source tensors. The WARC path used memory mapping and W2 GEMV on `pop`, an Intel Coffee Lake system running Pop!_OS with AVX2. The Q6_K path used libllama with `ngl 99` and a GTX 1060. The GTX 1060 was used only for the llama.cpp Q6_K decode row. No HIP compiler was used for this comparison. `Brandys` is an AMD Zen 4 host with a Radeon RX 7700 XT (`gfx1101`); owned HIP W2 GEMV rows are UNKNOWN in this corpus.

No `llama-server` was used. No daemon or paid cloud service was part of the measurement. The WARC CPU timings and the Q6_K CUDA timing are retained as observations of their respective paths, but the devices differ and the values are not used as a speed comparison.

### Error measures and hybrids

For a logit vector `x` and BF16 oracle `y`, `max_abs = max_i |x_i - y_i|` and `rms = sqrt((1/n) * sum_i (x_i - y_i)^2)`. The hybrid runs replaced selected WARC tensors with BF16 tensors while holding the rest of the forward path fixed. This identifies sensitivity by tensor class; it does not prove that a hybrid is a deployable representation.

## 5. Results

### Table 1 — Three-way logits, token 0 (EVAL-20260912-AGY-WARC-VS-LLAMACPP-LOGITS)

| path | argmax id | argmax value | max_abs vs BF16 | rms vs BF16 | wall ns |
| :--- | ---: | ---: | ---: | ---: | ---: |
| WARC seq1 (scalar-scale 4-bit) | 1040 | 10.451319 | 5.458222 | 1.169499 | 11,595,573,867 |
| BF16 oracle (Zig graph, safetensors) | 75311 | 10.646298 | 0 | 0 | n/a |
| llama.cpp Q6_K (libllama, ngl 99, GTX 1060) | 75311 | 11.329941 | 0.683642 | 0.103875 | 85,903,265 |

The Zig BF16 argmax matches llama.cpp at 75311. Scalar-scale WARC does not: its argmax is 1040. The 11,595,573,867 ns WARC CPU observation and the 85,903,265 ns llama.cpp GTX 1060 observation are on different devices and are not an engine comparison.

### Table 2 — First-break hybrids, token 0 (EVAL-20260912-AGY-WARC-FIRST-BREAK)

| path | argmax id | match 75311 |
| :--- | ---: | :--- |
| all WARC scalar-scale | 1040 | false |
| WARC + BF16 `down_proj` (all 28 L) | 75311 | **true** |
| WARC + BF16 MLP (gate+up+down) | 474 | false |
| WARC + BF16 `lm_head` | 48298 | false |
| all BF16 | 75311 | true |

The first stage RMS above 0.103875 was L0 x1 (attn residual), at 0.120153. The first max_abs above 1 was L0 h (`silu(g)*u`), at 5.921440. The table shows why “replace more with BF16” is not automatically a monotonic repair: the complete BF16 MLP hybrid changed the argmax to 474, while the `down_proj`-only hybrid restored 75311.

### Table 3 — Group-32 `down_proj` native (EVAL-20260912-AGY-WARC-DOWN-PROJ-GROUPS)

| path | argmax id | argmax value | max_abs vs BF16 | rms vs BF16 |
| :--- | ---: | ---: | ---: | ---: |
| all WARC scalar-scale | 1040 | 10.451319 | 5.458222 | 1.169499 |
| WARC + BF16 `down_proj` | 75311 | 10.479012 | n/a | n/a |
| WARC + **group-32 `down_proj`** | **75311** | **11.006571** | **6.247759** | **0.972398** |
| llama.cpp Q6_K | 75311 | 11.329941 | 0.683642 | 0.103875 |
| all BF16 | 75311 | 10.646246 | 0 | 0 |

Group-32 `down_proj` restored the argmax without BF16 `down_proj` at runtime. Its logit RMS was 0.972398, not llama.cpp-close. The archive remained 5,687,320,576 B. Record 16897 reconstruction max_abs was 3.377279e-03, previously 4.720055e-03. Native group-32 WARC wall time was 9,829,938,361 ns on the pop CPU.

### Table 4 — Remaining class, g32-down native (EVAL-20260912-AGY-WARC-G32-RMS-CLASS)

| path | argmax | max_abs | rms | L0 x1 rms | L0 h max_abs |
| :--- | ---: | ---: | ---: | ---: | ---: |
| native g32-down | 75311 | 6.247759 | 0.972398 | 0.120153 | 5.921440 |
| + BF16 attn (q,k,v,o) | 75311 | 6.254674 | 0.870220 | **0.100108** | 4.388432 |
| + BF16 `gate_proj` | **474** | 5.038136 | 0.961070 | 0.120153 | 7.478052 |
| + BF16 `up_proj` | 75311 | 6.148354 | 0.954559 | 0.120153 | 5.696454 |
| + BF16 `lm_head` | 75311 | **2.932936** | **0.665527** | 0.120153 | 5.921440 |
| llama.cpp Q6_K | 75311 | 0.683642 | 0.103875 | n/a | n/a |

The lowest RMS among the measured hybrids that retained argmax 75311 was the BF16 `lm_head` hybrid, at 0.665527. Attention was secondary: it cleared the L0 x1 tripwire but did not approach the Q6_K RMS. BF16 `gate_proj` changed the argmax to 474. Group-32 `lm_head` recoding is not in these tables and is not claimed as landed.

Supporting packing and GEMV measurements were also recorded. Packing from BF16 produced 277,701 tiles, with reconstruct sample max_abs 0.3349609. `gemvTile` and dequantize-then-dot had max_abs 0. Full-matrix `q_proj` versus BF16 for `x=ones` measured max_abs 19.511393 and 17.35 ms; `down_proj` measured 289.571080 and 93.93 ms. Layer-0 forward for `x=ones` measured y max_abs 4.676967, RMS 0.561870, attn residual 0.456665, and MLP h 52.980827. These `x=ones` results are not token-0 results and are not substituted for the four tables.

### Table 5 — g32 `lm_head` native (EVAL-20260912-AGY-WARC-LM-HEAD-G32)

| path | argmax id | max_abs vs BF16 | rms vs BF16 |
| :--- | ---: | ---: | ---: |
| g32-down + scalar head (prior) | 75311 | 6.247759 | 0.972398 |
| g32-down + BF16 `lm_head` (hybrid) | 75311 | 2.932936 | 0.665527 |
| **g32-down + g32 `lm_head`** | **75311** | **3.138624** | **0.702873** |
| llama.cpp Q6_K | 75311 | 0.683642 | 0.103875 |
| all BF16 | 75311 | 0 | 0 |

Archive **5,860,335,616 B**, **286,149** records. `R=6` tail. 9×3584 cannot hold g32.

### Table 6 — g32 `v`+`o` native (EVAL-20260912-AGY-WARC-VO-G32)

| path | argmax id | max_abs vs BF16 | rms vs BF16 | L0 x1 rms |
| :--- | ---: | ---: | ---: | ---: |
| g32-down+head, scalar attn | 75311 | 3.138624 | 0.702873 | 0.120153 |
| g32-down + BF16 attn (prior hybrid) | 75311 | 6.254674 | 0.870220 | 0.100108 |
| **g32-down+head + g32 v+o** | **75311** | **2.957127** | **0.530739** | **0.102155** |
| llama.cpp Q6_K | 75311 | 0.683642 | 0.103875 | n/a |
| all BF16 | 75311 | 0 | 0 | 0 |

First RMS break after this stack: **L0 y = 0.177989**. First max_abs>1: **L0 h = 4.627914**. Seq1 `q`/`k` unused.

### Table 7 — L0 y class hybrids, no recode (EVAL-20260912-AGY-WARC-L0Y-CLASS)

| path | argmax id | max_abs vs BF16 | rms vs BF16 | L0 h max_abs | L0 y rms |
| :--- | ---: | ---: | ---: | ---: | ---: |
| native g32-down+head+v+o | 75311 | 2.957127 | 0.530739 | 4.627914 | 0.177989 |
| + BF16 `up_proj` | 75311 | 2.701601 | 0.511859 | 4.410632 | 0.175773 |
| + BF16 `q_proj` | 75311 | 2.957127 | 0.530739 | 4.627914 | 0.177989 |
| + BF16 embed | 75311 | 3.307900 | 0.577105 | 3.448286 | 0.121297 |
| + BF16 `gate_proj` | 75311 | 1.751955 | **0.357160** | 6.249566 | 0.201165 |
| llama.cpp Q6_K | 75311 | 0.683642 | 0.103875 | n/a | n/a |
| all BF16 | 75311 | 0 | 0 | 0 | 0 |

`q` RMS delta vs native = **0** (seq1 dead). Embed BF16 **worsens** logit RMS **on this stack**. Gate BF16 is the RMS lever on **this** stack; the earlier 474 was a different graph.

### Table 8 — native g32 gate all 28 (EVAL-20260912-AGY-WARC-GATE-G32)

| path | argmax id | max_abs vs BF16 | rms vs BF16 | L0 h max_abs | L0 y rms |
| :--- | ---: | ---: | ---: | ---: | ---: |
| native g32-down+head+v+o | 75311 | 2.957127 | 0.530739 | 4.627914 | 0.177989 |
| + BF16 gate (hybrid) | 75311 | 1.751955 | 0.357160 | 6.249566 | 0.201165 |
| **g32 gate all 28** | **474** | **2.340956** | **0.473458** | **6.217336** | **0.200909** |
| llama.cpp Q6_K | 75311 | 0.683642 | 0.103875 | n/a | n/a |

L0 g32 `W_g` GEMV vs BF16: max_abs **0.123071**, RMS **0.015291** (leftover scalar L0: **1.274643 / 0.230835**). Rec 314821 reconstruction max_abs **0.004291**. Packing is not the 474 defect.

### Table 9 — prefix cliff, g32 gate + BF16 rest (EVAL-20260912-AGY-WARC-GATE-474 and GATE-LATE)

| K (g32 on 0..=K, BF16 on K+1..27) | argmax | rms vs BF16 |
| ---: | ---: | ---: |
| 0 | 75311 | 0.356410 |
| 6 | 75311 | 0.356364 |
| 13 | 75311 | 0.354887 |
| 20 | 75311 | 0.356502 |
| 21 | 75311 | 0.356089 |
| 22 | 75311 | 0.355535 |
| 23 | 75311 | 0.355650 |
| 24 | 75311 | 0.356875 |
| 25 | 75311 | 0.357251 |
| **26** | **474** | **0.464082** |
| 27 (all g32) | 474 | 0.473458 |

**`K*=26`**. Layers 0..25 stay in the 0.355–0.357 band. L26 g32 flips 75311→474.

### Table 10 — shippable leftover-scalar rest (EVAL GATE-LATE, GATE-L26)

| path | argmax | max_abs | rms |
| :--- | ---: | ---: | ---: |
| leftover scalar gate all 28 | 75311 | 2.957127 | 0.530739 |
| g32 0..=20, scalar L21–27 | 75311 | 3.204320 | **0.543931** |
| **g32 0..=25, scalar L26–27** | **75311** | **3.003202** | **0.520725** |
| g32 0..=26, scalar L27 | 474 | 3.000930 | 0.584634 |
| g32 all 28 | 474 | 2.340956 | 0.473458 |

**More g32 is not always tighter.** `0..=20` + scalar tail raised RMS above all-scalar. `0..=25` + scalar L26–27 beats all-scalar and is the last 75311-preserving g32 prefix.

### Table 11 — L26 vs L27 split and L27 keeper (EVAL GATE-L27, GATE-L26-HOLE)

g32 L0–L25 fixed.

| L26 | L27 | argmax | max_abs | rms |
| :--- | :--- | ---: | ---: | ---: |
| scalar | scalar | 75311 | 3.003202 | 0.520725 |
| BF16 | scalar | 75311 | 2.174780 | 0.477994 |
| scalar | BF16 | 75311 | 3.337777 | **0.538859** |
| BF16 | BF16 | 75311 | 1.771796 | 0.357251 |
| scalar | g32 | 75311 | 3.317519 | **0.533497** |
| **BF16** | **g32** | **75311** | **1.787870** | **0.361571** |

Isolated L27 BF16 raises RMS. Isolated L26 BF16 is the only single-layer win. Joint BF16 L26+L27 is the 0.357 plateau. **L27 g32 is a keeper once L26 is high-fidelity** (0.361571 is 0.004320 from 0.357251).

### Table 12 — group-16 L26 `gate` native (EVAL-20260912-AGY-WARC-GATE-L26-G16)

| path | L26 | L27 | argmax | max_abs | rms | match 75311 |
| :--- | :--- | :--- | ---: | ---: | ---: | ---: |
| native (scalar L26, g32 L27) | scalar | g32 | 75311 | 3.317519 | 0.533497 | true |
| BF16 L26, g32 L27 (HOLE) | BF16 | g32 | 75311 | 1.787870 | 0.361571 | true |
| **g16 L26, g32 L27 (committed)** | **g16** | **g32** | **75311** | **1.838025** | **0.367929** | **true** |
| g32 L26, scalar L27 (forbidden) | g32 | scalar | 474 | 3.000930 | 0.584634 | false |
| llama.cpp Q6_K | — | — | 75311 | 0.683642 | 0.103875 | true |
| all BF16 | — | — | 75311 | 0 | 0 | true |

Archive **9,260,343,296 B**, **452,165** records. Rec 447429 reconstruct max_abs **4.075529e-03**. `custom_flags=2`. Δ vs scalar-L26 native **−0.165568**. **0.006358** off BF16-L26 ceiling **0.361571**. Group-16 closed the L26 cliff without g32 L26 (474).

### Table 13 — remaining class on g16-L26 stack, no recode (EVAL-20260912-AGY-WARC-UP-CLASS)

| path | argmax | max_abs | rms | L0 h max_abs | L0 y rms |
| :--- | ---: | ---: | ---: | ---: | ---: |
| native g16 L26 + g32 rest | 75311 | 1.838025 | 0.367929 | 6.217336 | 0.200909 |
| + BF16 `up_proj` all 28 | 75311 | 1.713380 | **0.325232** | 6.028565 | 0.198492 |
| + BF16 `q_proj` all 28 | 75311 | 1.838025 | 0.367929 | 6.217336 | 0.200909 |
| + BF16 embed | 75311 | 1.856731 | 0.358781 | 0.300594 | 0.038978 |
| llama.cpp Q6_K | 75311 | 0.683642 | 0.103875 | n/a | n/a |
| all BF16 | 75311 | 0 | 0 | 0 | 0 |

Winner **`up`**. Δ vs native **−0.042697**. `|RMS_q − 0.367929| = 0` (seq1 dead). Embed Δ **−0.009148** with worse max_abs. Zero WARC writes. L0Y `up` Δ **0.018880** was on RMS **0.530739**; do not reuse it as ranking.

### Table 14 — g32 `up_proj` all 28 native (EVAL-20260912-AGY-WARC-UP-G32)

| path | up | argmax | max_abs | rms | match 75311 |
| :--- | :--- | ---: | ---: | ---: | ---: |
| native g16 L26 + scalar `up` | scalar | 75311 | 1.838025 | 0.367929 | true |
| + BF16 `up` all 28 (UP-CLASS) | BF16 | 75311 | 1.713380 | 0.325232 | true |
| **g32 `up` all 28 (committed)** | **g32 0..27** | **75311** | **1.669115** | **0.332708** | **true** |
| llama.cpp Q6_K | — | 75311 | 0.683642 | 0.103875 | true |
| all BF16 | — | 75311 | 0 | 0 | true |

Archive **11,976,155,136 B**, **584,773** records. Rec 452165 reconstruct max_abs **5.403638e-03**. `custom_flags=1`. Δ vs scalar-`up` native **−0.035221**. **0.007476** off BF16-`up` ceiling **0.325232**. All-28 g32 `up` kept 75311, unlike all-28 g32 `gate`. Native committed RMS **0.332708**. g32 `up` max_abs **1.669115** versus BF16-`up` hybrid **1.713380** is measured cancellation on this stack, not a claim that group-32 beats unquantized BF16.

### Table 15 — remaining class on g32-`up` + g16-L26 stack, no recode (EVAL-20260912-AGY-WARC-REST-CLASS)

| path | argmax id | max_abs vs BF16 | rms vs BF16 | L0 h max_abs | L0 y rms | match 75311 |
| :--- | ---: | ---: | ---: | ---: | ---: | :--- |
| native g32 `up` + g16 L26 | 75311 | 1.669115 | 0.332708 | 5.910644 | 0.196872 | true |
| + BF16 `gate_proj` (all 28 L) | 75311 | 1.607660 | 0.325527 | 5.943812 | 0.197146 | true |
| **+ BF16 `lm_head` (WINNER)** | **75311** | **1.180876** | **0.244954** | **5.910644** | **0.196872** | **true** |
| + BF16 `down_proj` (all 28 L) | 1057 | 1.353622 | 0.289821 | 5.910644 | 0.196361 | false |
| + BF16 embed | 75311 | 1.588249 | 0.321514 | 0.208493 | 0.036065 | true |
| llama.cpp Q6_K | 75311 | 0.683642 | 0.103875 | n/a | n/a | true |
| all BF16 | 75311 | 0 | 0 | 0 | 0 | true |

Winner **`lm_head`**. Δ **−0.087754**. `down_proj` BF16 is **1057** — do not recode `down`. Zero WARC writes.

### Table 16 — g16 `lm_head` native (EVAL-20260912-AGY-WARC-LM-HEAD-G16)

| path | `lm_head` | argmax | max_abs | rms | match 75311 |
| :--- | :--- | ---: | ---: | ---: | ---: |
| native g32 head | g32 6×3584 | 75311 | 1.669115 | 0.332708 | true |
| + BF16 `lm_head` (REST-CLASS) | BF16 | 75311 | 1.180876 | 0.244954 | true |
| **g16 `lm_head` (committed)** | **g16 4×3584** | **75311** | **1.603229** | **0.306314** | **true** |
| llama.cpp Q6_K | — | 75311 | 0.683642 | 0.103875 | true |
| all BF16 | — | 75311 | 0 | 0 | true |

Archive **12,754,722,816 B**, **622,789** records.

### Table 17 — g8 `lm_head` native (EVAL-20260912-AGY-WARC-LM-HEAD-G8)

| path | `lm_head` | argmax | max_abs | rms | match 75311 |
| :--- | :--- | ---: | ---: | ---: | :--- |
| native g16 head | g16 4×3584 | 75311 | 1.603229 | 0.306314 | true |
| + BF16 `lm_head` (REST-CLASS) | BF16 | 75311 | 1.180876 | 0.244954 | true |
| **g8 `lm_head` (committed)** | **g8 3×3584** | **75311** | **1.275785** | **0.281791** | **true** |
| llama.cpp Q6_K | — | 75311 | 0.683642 | 0.103875 | true |
| all BF16 | — | 75311 | 0 | 0 | true |

Archive **13,792,813,056 B**, **673,477** records. R=3 is legal here because **`152064%3=0`**. Do not copy R=3 onto `gate` (`18944%3=2`).

### Table 18 — g4 `lm_head` native (EVAL-20260912-AGY-WARC-LM-HEAD-G4)

| path | `lm_head` | argmax | max_abs | rms | match 75311 |
| :--- | :--- | ---: | ---: | ---: | :--- |
| native g8 head | g8 3×3584 | 75311 | 1.275785 | 0.281791 | true |
| + BF16 `lm_head` (REST-CLASS) | BF16 | 75311 | 1.180876 | 0.244954 | true |
| **g4 `lm_head` (committed)** | **g4 1×3584** | **75311** | **1.274693** | **0.259342** | **true** |
| llama.cpp Q6_K | — | 75311 | 0.683642 | 0.103875 | true |
| all BF16 | — | 75311 | 0 | 0 | true |

Archive **16,907,083,776 B**, **825,541** records.

### Table 19 — remaining class on g4-head stack, no recode (EVAL-20260912-AGY-WARC-REST-CLASS-2)

| path | argmax | max_abs | rms | L0 h max_abs | L0 y rms | match 75311 |
| :--- | ---: | ---: | ---: | ---: | ---: | :--- |
| native g4 `lm_head` | 75311 | 1.274693 | 0.259342 | 5.910644 | 0.196872 | true |
| + BF16 `lm_head` | 75311 | 1.180876 | 0.244954 | 5.910644 | 0.196872 | true |
| + BF16 `gate_proj` (all 28 L) | 75311 | 1.221440 | 0.251724 | 5.943812 | 0.197146 | true |
| **+ BF16 embed (WINNER)** | **75311** | **1.267349** | **0.243757** | **0.208493** | **0.036065** | **true** |
| + BF16 `v_proj` (all 28 L) | 75311 | 1.210643 | 0.264390 | 5.903235 | 0.196510 | true |
| llama.cpp Q6_K | 75311 | 0.683642 | 0.103875 | n/a | n/a | true |
| all BF16 | 75311 | 0 | 0 | 0 | 0 | true |

Winner **`embed`**. Δ **−0.015585**. `v` **worsened** RMS on this stack. REST-CLASS `lm_head` ranking is stale here.

### Table 20 — g4 embed native (EVAL-20260912-AGY-WARC-EMBED-G4)

| path | argmax | max_abs | rms | L0 h max_abs | L0 y rms | match 75311 |
| :--- | ---: | ---: | ---: | ---: | ---: | :--- |
| **g4 embed (committed)** | **75311** | **1.267626** | **0.244165** | **0.213484** | **0.036059** | **true** |
| native scalar rec 0 (prior) | 75311 | 1.274693 | 0.259342 | 5.910644 | 0.196872 | true |
| + BF16 embed | 75311 | 1.267349 | 0.243757 | 0.208493 | 0.036065 | true |
| + BF16 `lm_head` | 75311 | 1.334463 | 0.227910 | 0.213484 | 0.036059 | true |
| llama.cpp Q6_K | 75311 | 0.683642 | 0.103875 | n/a | n/a | true |
| all BF16 | 75311 | 0 | 0 | 0 | 0 | true |

Archive **20,021,354,496 B**, **977,605** records. Rec 0 stays scalar leftover and **unrewritten**.

### Table 21 — g2 `lm_head` native (EVAL-20260912-AGY-WARC-LM-HEAD-G2)

| path | `lm_head` | argmax | max_abs | rms | match 75311 |
| :--- | :--- | ---: | ---: | ---: | :--- |
| native g4 embed + g4 head | g4 1×3584 | 75311 | 1.267626 | 0.244165 | true |
| + BF16 `lm_head` (EMBED-G4) | BF16 | 75311 | 1.334463 | 0.227910 | true |
| **g2 `lm_head` (committed)** | **g2 1×3584** | **75311** | **1.334464** | **0.227910** | **true** |
| llama.cpp Q6_K | — | 75311 | 0.683642 | 0.103875 | true |
| all BF16 | — | 75311 | 0 | 0 | true |

Archive **23,135,625,216 B**, **1,129,669** records. Group-2 **hits** the BF16-head ceiling **0.227910**. Head packing on this stack is exhausted.

### Table 22 — remaining class on g2-head + g4-embed, no recode (EVAL-20260912-AGY-WARC-REST-CLASS-3)

| path | argmax | max_abs | rms | L0 h max_abs | L0 y rms | match 75311 |
| :--- | ---: | ---: | ---: | ---: | ---: | :--- |
| native g2 head + g4 embed | 75311 | 1.334464 | 0.227910 | 0.213484 | 0.036059 | true |
| + BF16 `lm_head` (ceiling control) | 75311 | 1.334463 | 0.227910 | 0.213484 | 0.036059 | true |
| **+ BF16 `gate_proj` (all 28 L)** | **75311** | **1.056579** | **0.211582** | **0.159342** | **0.035736** | **true** |
| + BF16 `v_proj` (all 28 L) | 75311 | 1.198385 | 0.220300 | 0.172196 | 0.034045 | true |
| + BF16 `o_proj` (all 28 L) | 75311 | 1.269518 | 0.224032 | 0.134689 | 0.031362 | true |
| + BF16 `down_proj` (forbidden) | 1057 | 1.353622 | 0.289821 | n/a | n/a | false |
| llama.cpp Q6_K | 75311 | 0.683642 | 0.103875 | n/a | n/a | true |
| all BF16 | 75311 | 0 | 0 | 0 | 0 | true |

Winner **`gate`**. Δ **−0.016327**. `lm_head` Δ **0**. Do not reuse this `v`/`o` ranking after L26 is recoded.

### Table 23 — gate band isolate (EVAL-20260912-AGY-WARC-GATE-ISOLATE)

| path | gate L0–25 | L26 | L27 | argmax | max_abs | rms | match 75311 |
| :--- | :--- | :--- | :--- | ---: | ---: | ---: | :--- |
| native (g32 / g16 / g32) | g32 | g16 | g32 | 75311 | 1.334464 | 0.227910 | true |
| + BF16 L0–L25 | BF16 | g16 | g32 | 75311 | 1.109436 | 0.225683 | true |
| **+ BF16 L26** | **g32** | **BF16** | **g32** | **75311** | **1.013324** | **0.211529** | **true** |
| + BF16 L27 | g32 | g16 | BF16 | 75311 | 1.174533 | 0.229818 | true |
| + BF16 all 28 (REST-CLASS-3) | BF16 | BF16 | BF16 | 75311 | 1.056579 | 0.211582 | true |
| llama.cpp Q6_K | — | — | — | 75311 | 0.683642 | 0.103875 | true |
| all BF16 | — | — | — | 75311 | 0 | 0 | true |

Winner **`l26`**. Δ **−0.016381**. L0–25 Δ **−0.002227**. L27 Δ **+0.001908** (worse). REST-CLASS-3 `gate` win was almost entirely L26. Do not recode L27. Do not g32 L26 (**474**).

### Table 24 — g8 L26 `gate` native (EVAL-20260912-AGY-WARC-GATE-L26-G8)

| path | L26 | L0–25 | L27 | argmax | max_abs | rms | match 75311 |
| :--- | :--- | :--- | :--- | ---: | ---: | ---: | :--- |
| native g16 L26 | g16 4×3584 | g32 | g32 | 75311 | 1.334464 | 0.227910 | true |
| + BF16 L26 (GATE-ISOLATE) | BF16 | g32 | g32 | 75311 | 1.013324 | 0.211529 | true |
| **g8 L26 (committed)** | **g8 2×3584** | **g32** | **g32** | **75311** | **1.026797** | **0.209801** | **true** |
| llama.cpp Q6_K | — | — | — | 75311 | 0.683642 | 0.103875 | true |
| all BF16 | — | — | — | 75311 | 0 | 0 | true |

Archive **23,329,611,776 B**, **1,139,141** records. Rec 1129669 reconstruct max_abs **0.003654**. `custom_flags=4`. Capture vs BF16-L26 lever **0.016381** = **1.1055 (110.55%)**. Native **beats** the BF16-L26 hybrid **0.211529** on this stack. That is measured cancellation, not a claim that group-8 is more accurate than BF16. Do not pack group-4 L26.

### Table 25 — remaining class on g8-L26 stack, no recode (EVAL-20260912-AGY-WARC-REST-CLASS-4)

| path | argmax | max_abs | rms | L0 h max_abs | L0 y rms | match 75311 |
| :--- | ---: | ---: | ---: | ---: | ---: | :--- |
| native g8 L26 | 75311 | 1.026797 | 0.209801 | 0.213484 | 0.036059 | true |
| + BF16 `lm_head` (ceiling control) | 75311 | 1.026796 | 0.209801 | 0.213484 | 0.036059 | true |
| + BF16 `gate` L0–L25 (L26 g8, L27 g32) | 75311 | 1.010125 | 0.207292 | 0.159342 | 0.035736 | true |
| + BF16 `v_proj` (all 28 L) | 75311 | 1.033669 | 0.207112 | 0.172196 | 0.034045 | true |
| **+ BF16 `o_proj` (all 28 L)** | **75311** | **0.989152** | **0.206186** | **0.134689** | **0.031362** | **true** |
| + BF16 `down_proj` (forbidden) | 1057 | 1.353622 | 0.289821 | n/a | n/a | false |
| llama.cpp Q6_K | 75311 | 0.683642 | 0.103875 | n/a | n/a | true |
| all BF16 | 75311 | 0 | 0 | 0 | 0 | true |

Winner **`o`**. Δ **−0.003615** (0.209801 − 0.206186). It is the only hybrid with max_abs **< 1**. REST-CLASS-3 `v`/`o` ranking is stale. No tiles were recoded in this mill. Group-16 `o` native RMS is **UNKNOWN**.

If a percentage of error reduction is written, the two RMS values must appear in the same sentence.

## 6. Discussion

The geometry result survives the expanded cut. A 20,480 B memory-mapped record can hold a W2 coded tile in a layout organized around a 17,408 B cell. The record and cell are not interchangeable objects, but their relationship is explicit enough for a reader to map five 4,096 B pages, locate the prefetch region, and expose a stable C ABI. The 16,384 B coded region is a hard budget. The remaining 960 B is not free space to be filled by an arbitrary overflow: it is the semantic payload budget specified by the record layout. A tile that does not fit must be split, and the split must be visible in record accounting.

The archive history makes that point concrete. The first group-32 `down_proj` operation ended at 5,687,320,576 B and 277,701 records. Later tails did not pretend that the archive was still that size. The head ladder, embed, and L26 gate operations successively added records. The final archive is 23,329,611,776 B with 1,139,141 records, while record 0 retains the same digest. This is append-style evidence of what was written and what was left unreferenced. It is not a claim that the final archive is compact or that all prior records are live.

The scalar baseline is a behavioral failure, not merely a storage choice. Scalar-scale four-bit WARC produced argmax 1040 where both the BF16 oracle and Q6_K produced 75311. The result reached the output decision despite the representation fitting its record. The first implication is methodological: byte fit is necessary for a container, but it is not validation of the model path. The forward graph must be run against a named oracle, with token, position, sequence length, and comparison metrics recorded.

Group-32 `down_proj` changed the decision to 75311. That establishes a useful local fact: a tensor-class-specific coding can restore the measured argmax within the same coded-tile budget. It does not establish equivalence. On the g32-down path, max_abs was 6.247759 and RMS was 0.972398, compared with Q6_K RMS 0.103875. Argmax is a coarse statistic; it can agree while many other logits remain displaced. The paper keeps those claims separate: “restored argmax” is not “matched logits.”

The subsequent `lm_head` and attention experiments show why the stack has to be reported in stages. Group-32 `lm_head` on the permitted six-row tail measured 75311 / 0.702873, while its BF16 hybrid measured 75311 / 0.665527. Adding group-32 `v` and `o` to the g32-down-plus-head stack measured 75311 / 0.530739. The L0 x1 RMS after that stack was 0.102155, but the first RMS break later in the graph was L0 y at 0.177989. These changes improve the named path without proving that the next class should be selected by a global ranking.

The L0 y hybrids make the ranking conditional. On the g32-down-plus-head-plus-v-plus-o stack, BF16 `up_proj` measured RMS 0.511859, BF16 `gate_proj` measured 0.357160, and BF16 embed measured 0.577105. Thus embed BF16 worsened RMS on this stack even though it improved an internal L0 quantity and remained argmax-preserving. The q hybrid was numerically identical to native because q is dead for seq_len=1 at position 0. The earlier 474 observation for a BF16 gate hybrid belongs to a different graph and is not substituted into this table. Measurements are ranked on the named stack, not transferred across graph states as if they were universal tensor properties.

The gate series is the clearest refusal of a uniform group-32 policy. Local L0 g32 `W_g` GEMV error was max_abs 0.123071 and RMS 0.015291, yet all-layer g32 gate measured argmax 474. The leftover scalar L0 measurement was 1.274643 / 0.230835, and reconstruction at record 314821 was 0.004291, so the 474 result is not explained by an obvious packer or local GEMV defect. The prefix sweep locates the cliff: layers 0 through 25 remain between RMS 0.354887 and 0.357251, but adding L26 g32 flips 75311 to 474 and raises RMS to 0.464082. Hence `K*=26` is a measured accumulation boundary, not a model-wide theorem.

The split experiments add an important negative result. The g32 prefix through L20 with a scalar tail preserved 75311 but raised RMS to 0.543931. The prefix through L25 with scalar L26–L27 measured 75311 / 0.520725, better than the all-scalar gate stack at 0.530739. Adding g32 at L26 while leaving L27 scalar produced 474 / 0.584634. In other words, more group-32 can preserve a local coding rule and still make the whole graph worse. This is why the final stack records the exception explicitly rather than describing it as a universal gate policy.

The L26/L27 table remains useful as the reason for the later ladder. BF16 at L26 with g32 at L27 measured 75311 / 0.361571, while BF16 at L27 with scalar L26 measured 75311 / 0.538859. The isolated L26 replacement was the single-layer win, and the joint BF16 result was 0.357251. The later g8 L26 replacement moved the live native endpoint to 0.209801. L27 remains g32: the isolate showed an L27-only BF16 delta of +0.001908, and the directive forbids recoding it.

The head ladder demonstrates shape-sensitive coding. Group-8 at four rows would require 21,504 B and fails, but group-8 at three rows fits 16,128 B for `lm_head` because 152064%3=0. Group-4 at one row and group-2 at one row also fit. The live head moved from g32 6×3584 through g16 4×3584, g8 3×3584, g4 1×3584, and finally g2 1×3584. Group-2 measured RMS 0.227910, equal to the BF16-head ceiling on the g4-embed stack. This is a stack-local saturation result, not a claim that the head is globally solved.

The embed ladder adds the same caution. Group-4 embed measured 75311 / 0.244165, while the BF16-embed hybrid on that stack measured 0.243757. Group-2 `lm_head` then measured 0.227910, essentially the BF16-head ceiling, before the L26 g8 change. The live embed is therefore group-4 1×3584, not scalar rec 0. The earlier statement that BF16 embed worsened RMS applied to a different stack and is not a standing law.

The current native endpoint is changed again by the L26 group-8 mill. On the g4-embed and g2-head stack, g8 2×3584 L26 gate measured argmax 75311, RMS 0.209801, and max_abs 1.026797. It improved over the BF16-L26 hybrid RMS 0.211529 by 0.001728 on this stack. The capture of the measured 0.016381 lever was 1.1055, or 110.55%. That is measured cancellation on this named stack, not a claim that group-8 is more accurate than BF16. The prior g16 records remain leftover and unreferenced; the live L26 range is flags 4 at 1129669..1139140.

REST-CLASS-4 was a diagnostic sweep on that native g8-L26 stack. BF16 `lm_head` was flat at RMS 0.209801. BF16 gate L0–L25 measured 0.207292, BF16 `v_proj` 0.207112, and BF16 `o_proj` 0.206186. `o_proj` was the winner and the only hybrid with max_abs below 1, at 0.989152. No tiles were recoded in that mill. The next unmeasured native is group-16 `o_proj`; its RMS remains UNKNOWN. Rankings do not travel across stacks: the earlier head, embed, and gate winners are historical results for their named bases.

The embed result also illustrates why one metric cannot be promoted to policy. On the earlier L0Y stack, BF16 embed worsened RMS to 0.577105. On the g16-L26 stack, BF16 embed improved RMS to 0.358781, a delta of −0.009148, while worsening max_abs to 1.856731. Both statements are true because the graph state differs. The next experiment must name the full base stack and report both RMS and max_abs. A single favorable internal metric is not enough to order the remaining classes.

The Q6_K comparison remains a residual comparison. Q6_K is a six-bit coded path whose measured RMS against the BF16 oracle is 0.103875; it is not the training model and not a target that the WARC path is entitled to reproduce merely because both paths produce 75311. The current WARC native endpoint is 0.209801, so it is not declared better than llama.cpp. The two timing observations are also not a speed comparison: WARC CPU observations use the named Pop!_OS Coffee Lake host, while the Q6_K row uses a GTX 1060 path. No ratio is inferred from those different devices.

The Cactus boundary follows the same discipline. CQ4 and W2 have different coding layouts and kernel contracts. The presence of `cactus_hip_cq4_gemv` does not make W2 bytes valid input to that function. Cactus remains a stepping ground for experiments; historical WARC/W2 is the representation measured in the earlier tables, while `.chpe` is the current owned identity. The current reader, reconstructed weight path, and Zig/C ABI are measured seams, not a claim that every engine stage is complete.

## 7. Limitations and next measurement

This remains a single-host, single-token measurement for the model-output comparison. It uses `token_id=0`, position 0, no extra BOS, and seq_len=1. It does not establish perplexity, generation quality, long-context behavior, throughput, or end-to-end application performance. Tokenizer identity, KV cell geometry, attention, RoPE, and an L0 `o_proj` parity path are now separately measured below; the complete residual, RMSNorm, MLP, 28-layer loop, and sampler are not claimed landed. The BF16 path is an oracle for the logits comparison.

The seq1 geometry has a specific consequence: RoPE is identity at position 0, softmax is `[1.0]`, and `attn = repeat(v)`. Consequently q and k do not affect these logits. That is why q/k remain scalar in the live stack, but it cannot validate their coding for a longer sequence. A later test must use multiple positions and report the KV representation separately.

The historical native result was **75311 / 0.209801** with max_abs **1.026797**. Its live components were g4 embed 1×3584, g2 `lm_head` 1×3584, g8 L26 gate 2×3584, g32 gate at L0–L25 and L27, g32 `up`, `down`, `v`, and `o`, and scalar q/k. That stack remains in the tables as mill history. The current `.chpe` reader instead selects the BF16 flag-128 tail and returns **75311 / 0.000014**; its unread quantized history is not silently counted as live.

The occupancy plan for compiling tokenizer, KV, and weights as one same-geometry object is `docs/BLUEPRINT-20260912-OWN-ENGINE-SAME-GEOMETRY.md`; this RFC cites that plan without rewriting it. The current cut has separate measured tokenizer, KV, attention, RoPE, and weight-tail seams, not a claim that the complete forward runtime is landed.

The next unmeasured native cut is group-16 `o_proj`. Its RMS is **UNKNOWN**. The REST-CLASS-4 `o` result of 0.206186 was a BF16 hybrid and no tile was recoded in that mill. The future group-16 `o` test must report the exact base stack, geometry, flags, record range, reconstruction sample, argmax, max_abs, RMS, and archive accounting. It must not import a ranking from another stack.

Group-8 L26 must not be described as closing the gap to Q6_K. Its 0.209801 result is 0.001728 past the BF16-L26 hybrid 0.211529 on this stack, and its 1.1055 capture is measured cancellation. Group-4 L26 is not to be packed. L27 is not to be recoded. BF16 `down_proj` produced argmax 1057 and remains forbidden for recoding.

Brandys HIP W2 GEMV remains UNKNOWN. No HIP number is inferred from the GTX 1060 Q6_K row, and no CPU/CUDA speedup is claimed. This RFC also does not claim production readiness, SOTA, a finished tokenizer/KV object, or completion by agents. The status remains a draft pending measured cuts.

The current weight identity is `.chpe`, not ISO WARC as an owned type. Historical WARC records and the live BF16 tail remain distinct in the mill ledger. The complete residual, RMSNorm, MLP, 28-layer loop, and sampler remain outside the claims of this cut. The related-work discussion is intentionally conservative. GGUF/GGML, safetensors, GPTQ, AWQ, and cactus-compute are adjacent containers, warehouses, or coding approaches. Where a specific external source has not been inspected in this draft, the reference is marked `[UNSOURCED]`.

## 2026-09-13 cut — `.chpe` identity and live BF16 tail

This dated cut supersedes the earlier WARC-native endpoint without deleting it from the record. The owned extension is **`.chpe`**, with ASCII magic **`CHPE`** and little-endian value **`0x45504843`** (`inventory/EVAL-20260913-AGY-OWN-CHPE.md`). ISO `WARC/1.0` is present as a historical text/container label, but it is not the owned file type.

The BF16 split/retarget evaluation reports the whole archive at **64368254976 B** and **3142981 records** (`inventory/EVAL-20260913-AGY-WARC-BF16-SPLIT-RETARGET.md`). This is mill-ledger size, not a claim that every record is read by the current native path. Records **0..2044740** are unread mill history, **41876295680 B**, while the live flag-128 BF16 tail is records **2044741..3142980**, **22491955200 B**. The live tail has 1,098,240 records. Record 0 remains byte-stable with SHA-256 `368ea8f6c75a0ecd665cc15a14fe1991644e3ac8ac7222a788d0736ddf1757ee`. The handoff records the same separation and preserved token decision (`inventory/HANDOFF-20260913-AGY-WARC-BF16-SPLIT-RETARGET.md`).

On the live flag-128 tail, native token 0 is **argmax 75311**, RMS **0.000014** against the BF16 oracle. The earlier 0.209801 result belongs to the prior g8-L26 quantized stack and remains in Table 24 as history; it is not the live reader result. The old 0.002929 drop associated with g4 embed at record 825541 is also historical. Q6_K remains the prior residual at 0.103875. This update does not claim that unread quantized history has vanished or that the tail is a completed inference engine.

The tokenizer seam is measured against the GGUF vocabulary: IDs match, overflow raises `SplitRequired`, and `MAX_IDS_PER_CELL` is **4322** (`inventory/EVAL-20260913-AGY-OWN-TOKENIZER.md`). The KV seam uses **4 Records/token**, **57344 B/token**, and **8 Records for two tokens**. The two-token check reports `max_abs==0` against its oracle and uses `RefuseTrim`, not truncation (`inventory/EVAL-20260913-AGY-OWN-KV-CELLS.md`; `inventory/EVAL-20260913-AGY-OWN-KV-CHPE.md`). The 64 B SIMD source chunker remains an LST/AST intake pipe (`docs/polyglot-code-intelligence.md`); it is not engine KV.

Attention at L0 measures GQA **28/4** with `max_abs==0` versus the f32 oracle (`inventory/EVAL-20260913-AGY-OWN-ATTENTION-WALK.md`). RoPE uses θ **1000000**; positions 0 and 1 measure `max_abs==0`, and V is not rotated (`inventory/EVAL-20260913-AGY-OWN-ROPE.md`). The L0 `o_proj` path covers records **2639685..2641476**, runs at **16181445 ns** in ReleaseFast, and measures `max_abs==0` (`inventory/EVAL-20260913-AGY-OWN-O-PROJ.md`). These are named seams, not a claim that residual, RMSNorm, MLP, the 28-layer loop, or sampler is landed. The residual mill is written but not EVALed.

Brandys provides one separately named BF16 HIP tile observation: a two-row tile measures **50920.8 ns** with max_abs **0.00000027**, while the CPU row measures **4228.3 ns** with max_abs **0** (`inventory/EVAL-20260913-AGY-BRANDYS-BF16-HIP.md`). This is not a W2 claim, not a CPU/GPU speedup claim, and not a claim that the Pop host ran HIP. Brandys HIP W2 remains UNKNOWN.

The two-plane boundary remains: the memory plane keeps its 17,408 B cell and 64 B header, while engine KV uses 57344 B/token in four fingerprint Records. The same geometry is a design constraint, not permission to call the 64 B intake header engine KV. These measured additions update the engine-plane paper; the un-EVALed stages remain UNKNOWN and the manuscript status remains DRAFT — NEEDS WORK.

## References

1. Gerganov, G. and contributors. *GGML / llama.cpp documentation and implementation*. [UNSOURCED].
2. Hugging Face. *GGUF file format and Transformers serialization documentation*. [UNSOURCED].
3. Frantar, E., Ashkboos, S., Hoefler, T., and Alistarh, D. *GPTQ: Accurate Post-Training Quantization for Generative Pre-trained Transformers*. [UNSOURCED].
4. Lin, J., Tang, J., Tang, H., Yang, S., Dang, X., Gan, C., and Han, S. *AWQ: Activation-aware Weight Quantization for LLM Compression and Acceleration*. [UNSOURCED].
5. Cactus-compute contributors. *CQ coding and compute documentation*. [UNSOURCED].
6. SQLite Consortium. *SQLite pager and memory-mapped I/O documentation*. [UNSOURCED].

## Appendix A — Follow-on note (outline only)

The follow-on note describes the measured head ladder, embed g4, L26 g8, and residual `o` order. It does not claim a finished universal quantizer. The current native endpoint is WARC/W2 argmax **75311**, RMS **0.209801**, max_abs **1.026797** on seq1 token 0.

1. **Preserve the record contract.** Keep the 20,480 B record, 3,072 B prefetch region, 17,408 B cell-aligned remainder, and 16,384 B coded-tile budget. Overflow splits at the tail. Rec 0 is never rewritten.

2. **Use shape-specific rows.** Group-32 has `R≤6`; width 3584 uses R=4 because 3584%6=2, while early `lm_head` used R=6 because 152064%6=0. Group-8 at four rows is 21504 B and fails; at three rows it is 16128 B and fits `lm_head`; at two rows it is 10752 B and fits L26 gate because 18944%2=0. Group-4 at one row is the embed geometry. Group-2 at one row is the live head geometry.

3. **Keep flags one-hot.** Bits 0–4 are g32=1, g16=2, g8=4, g4=8, and g2=16. `@popCount(flags & 31) > 1` refuses mixed coding. Live g4 embed uses flags 8, g2 head flags 16, and g8 L26 flags 4. Leftover g16 L26 remains flags 2 but is unreferenced.

4. **Keep the L26 cliff explicit.** Group-32 gate fails at `K*=26` with argmax 474. Group-16 L26 measured 0.367929; group-8 L26 is the live 0.209801 result. Do not recode L27, pack g4 L26, or call group-8 generally more accurate than BF16.

5. **Measure group-16 `o_proj` next.** REST-CLASS-4 crowned `o` at 0.206186 as a BF16 hybrid, but no native `o` recode landed. Group-16 `o` RMS is UNKNOWN until measured. The result must retain stack-local provenance and must not be compared as if rankings transfer.

6. **Expand sequence length before q/k claims.** At seq1 position 0, q and k do not affect logits. A multi-token test must include RoPE, softmax, KV, and the relevant token sequence.

7. **Keep comparisons honest.** Q6_K RMS 0.103875 is their residual against BF16, not the training model. Brandys HIP W2 remains UNKNOWN. No CPU/CUDA ratio, production, SOTA, tokenizer/KV completion, or agent-completion claim follows from this RFC.
