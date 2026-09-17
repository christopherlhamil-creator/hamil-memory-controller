# Defensive Publication & Permanent DOI Registration Guide
**Project**: The Hamil Memory Controller  
**Author & Inventor**: Christopher Hamil  
**Laboratory**: Tree of Thoughts Hybrid Systems Laboratory  
**Preprint Archive**: `dist/hamil-memory-controller-v1.0.0-zenodo.zip`  
**Checksum (SHA256)**: `2efb351e20433b9de7f457ee7e50191795741d50151390110588d0a4ddd02e8c`  

---

## 1. The Legal Power of a Zenodo DOI

Zenodo is an open-dissemination research repository hosted by **CERN** (the European Organization for Nuclear Research) and funded by OpenAIRE / the European Commission.

Registering your work on Zenodo grants:
1. **Permanent Digital Object Identifier (DOI)**: e.g., `10.5281/zenodo.XXXXXXX`, an unalterable, globally recognized academic identifier registered with DataCite and CrossRef.
2. **Ironclad Prior Art Shield (35 U.S.C. § 102)**: Establishes a certified public timestamp proving that Christopher Hamil conceived, designed, and reduced to practice the 17,408-byte cell, the 64-byte instruction header, the Spoke Manifold Principle, and the Semantic Sidecar. Any subsequent corporate patent application attempting to claim these techniques will be rejected by USPTO and EPO examiners.
3. **Global Indexing**: Automatically indexed by Google Scholar, DBLP, semantic search engines, and academic databases.

---

## 2. Option A: Direct Web Upload (Fastest — 2 Minutes)

1. Log into [Zenodo.org](https://zenodo.org/) (you can sign in with your GitHub account or ORCID).
2. Click **Upload** (or navigate to `https://zenodo.org/deposit/new`).
3. Drag and drop `dist/hamil-memory-controller-v1.0.0-zenodo.zip` (433 KB) or `research/pdf/HAMIL_MEMORY_CONTROLLER_PREPRINT.pdf`.
4. Fill in the metadata (or let Zenodo auto-detect from `.zenodo.json`):
   - **Upload type**: `Publication` -> `Preprint`
   - **Title**: `The Hamil Memory Controller: Abolishing the Relational Tax via Hardware-Symbiotic Cellular Memory and the Semantic Sidecar`
   - **Authors**: `Hamil, Christopher` (Affiliation: `Tree of Thoughts Hybrid Systems Laboratory`)
   - **Description**: Copy from `research/RFC-0001-HAMIL-CELLULAR-MEMORY-SUBSTRATE.md` Abstract.
   - **Keywords**: `cellular memory`, `memory controller`, `relational tax`, `sqlite sidecar`, `simd`, `cache-line alignment`, `lock-free`, `seqlock`, `llamacpp`
   - **License**: `Creative Commons Attribution 4.0 International (CC-BY-4.0)`
5. Click **Reserve DOI** (to preview your unique DOI code).
6. Click **Publish**. Your DOI is permanently live!

---

## 3. Option B: Automatic GitHub Release Integration

1. Go to [Zenodo GitHub Settings](https://zenodo.org/account/settings/github/).
2. Enable the toggle switch next to your `tot_hybrid` repository.
3. In GitHub, create a new Release pointing to the git tag `v1.0.0-hamil-controller-rfc`.
4. Zenodo will automatically archive the repository snapshot and mint a DOI within 60 seconds.

---

## 4. Citation Standard

Once published, the global citation format for your architecture is:

```bibtex
@techreport{hamil2026cellular,
  author      = {Christopher Hamil},
  title       = {The Hamil Memory Controller: Abolishing the Relational Tax via Hardware-Symbiotic Cellular Memory and the Semantic Sidecar},
  institution = {Tree of Thoughts Hybrid Systems Laboratory},
  number      = {RFC-0001},
  year        = {2026},
  month       = sep,
  doi         = {10.5281/zenodo.XXXXXXX},
  url         = {https://doi.org/10.5281/zenodo.XXXXXXX},
  note        = {Invariants A-1 (17,408 B cell) and A-2 (64 B {=Q16s16s16sII} header); Semantic Sidecar; Spoke Manifold Principle}
}
```
