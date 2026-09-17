# Research & Development Lane: The Hamil Memory Controller

**Principal Investigator & System Architect**: Christopher Hamil  
**Laboratory**: Tree of Thoughts Hybrid Systems Laboratory (`tot_hybrid`)  
**Core Specification**: [`RFC-0001-HAMIL-CELLULAR-MEMORY-SUBSTRATE.md`](./RFC-0001-HAMIL-CELLULAR-MEMORY-SUBSTRATE.md)  
**Status**: Active Research & Defensive Publication Track

---

## 1. Mission & Scope

The Research & Development (R&D) Lane translates the physical engineering breakthroughs proven on bare metal into formal scientific publications, defensive technical specifications, and reproducible benchmarks. 

The primary objectives are:
1. **Unassailable Authorship & Attribution**: Cement Christopher Hamil's name to the 17,408B cellular geometry, 64B instruction header, Spoke DB manifold principle, and Semantic Sidecar architecture.
2. **Defensive Prior Art Shield**: Publicly publish and timestamp specifications and preprints to permanently block third-party corporate software patents under 35 U.S.C. § 102.
3. **Academic & Industry Publication**: Prepare publication-ready preprints for ArXiv, TechRxiv, and Zenodo (minting a permanent CERN-backed DOI).

---

## 2. Council Arena R&D Workstream Division

The 4-Way Council Arena is organized into complementary scientific research desks:

| Seat | Agent / Engine | Research Role | Immediate R&D Deliverables |
| :---: | :---: | :--- | :--- |
| **Seat 0** | **Claude Opus 5** (`council-claude`) | **Chief Theorist & Systems Co-Author** | Mathematical formulation of Invariants A-1 & A-2; microarchitectural cache-coherence proofs; draft Sections 1, 2, & 4 of the Whitepaper. |
| **Seat 1** | **Grok 4.6** (`council-grok`) | **Adversarial Peer Reviewer & Prior Art** | Comprehensive literature review across Stonebraker (C-Store/H-Store), Gray (ACID), Hipp (SQLite), and modern systems (DuckDB, ClickHouse, Limbo). Counter-argument synthesis and stress testing. |
| **Seat 2** | **Claude Sonnet 3.7** (`council-sonnet`) | **Empirical Benchmark & Reproducibility Lead** | Automated chart, table, and data pipeline generation from `tests/test_1m_query_bench.zig` and `tests/test_multiprocess_shm.zig`. Reproducibility package builder. |
| **Seat 3** | **OpenAI Codex** (`council-codex`) | **Publishing & Typesetting Architect** | LaTeX / Typst whitepaper templates, BibTeX citation graph (`references.bib`), ArXiv packaging, and PDF export toolchains. |

---

## 3. Core Deliverables Roadmap

- [x] **RFC-0001 Specification**: Formal technical specification published in `research/RFC-0001-HAMIL-CELLULAR-MEMORY-SUBSTRATE.md`.
- [x] **BibTeX & Citation Index**: `research/references.bib` covering 40 years of database prior art (`council/grok` Seat 1).
- [x] **Related Work**: `research/sections/07_related_work.md` (sidecar vs engine-rewrite; JOIN Gegenrede; heterogeneous accelerators).
- [x] **Tripartite architecture**: `research/sections/04_tripartite_heterogeneous_architecture.md` (Zen 4 AVX-512 + XDNA 118.174 GiB/s + GPU \(\varnothing\) skip).
- [x] **Whitepaper Draft (`research/WHITEPAPER_HAMIL_CONTROLLER.md`)**: Full academic paper ready for preprint distribution (1,109 lines assembled, commit `05dc9cf`).
- **Engine-plane companion RFC**: `research/RFC-20260912-full-floats-model-weight-coding.md` has a 2026-09-13 `.chpe` / live-BF16-tail cut; status remains **DRAFT — NEEDS WORK**.
- [x] **Tokenizer corpus (Seat 1)**: N=100 Arm A/B pair in `research/corpus/tokenizer_eval/` (runtime mirror `run/tokenizer_eval/`); Gemma 4 E2B **68.87×** / Qwen2.5-Coder-7B **68.05×** expansion vs one 64 B header (`inventory/EVAL-TOKENIZER-CORPUS-BPE-20260908.md`).
- [ ] **Zenodo DOI Registration**: Package archive for permanent digital object identifier minting.
