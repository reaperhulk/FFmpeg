# H.264 deblocking follow-up

This continues the High-profile, 8-bit yuv420p investigation from the published
`d38575b441dad25485f8f005fc2cb5ab512aa906` checkpoint. Both retained changes are
separate commits. Measurements use the same Xeon Platinum 8573C, GCC 13.3,
NASM 2.16.03, minimal configuration, and cached-packet harness as
[h264-optimization-notes.md](h264-optimization-notes.md).

## Retained changes

| Published commit | Change | Exclusive instruction reduction on full Sintel |
|---|---|---:|
| `ccc286f5d09818a973414dd5aeaddce29d54fa45` | AVX boundary-strength kernel | 24.82% of strength calculation |
| `35a818dbdfca39d71314f7a79c80cda05f0b98ce` | Progressive 8-bit 4:2:0 CABAC filter setup | 21.06% of `loop_filter` setup |

Four motion vectors fit in one 128-bit AVX register. The new kernel compares
normal and crossed B-list reference/motion pairings, combines them before
expanding four strength bytes to words, and uses a shorter 4x4 transpose.
Its four-byte reference/NNZ loads read only the useful cache entries.
Dispatch requires x86-64 and fast AVX; the existing MMX kernel remains the
fallback. Boundary strengths are independent of pixel depth, so the dispatch
retains the existing monochrome/4:2:0 format eligibility.

The C change propagates a constant simple-mode flag through the row loop,
border backup, and filter-cache helpers. It removes repeated depth, chroma,
field, and CABAC tests and simplifies address calculations. The selection
requires progressive 8-bit 4:2:0 CABAC pictures. Other formats and field
pictures retain the general path; small builds do not instantiate the extra
specialization. Gray-mode checks are preserved.

## Full-decode instruction counts

Callgrind 3.27.1 collects `Ir` only inside `h264_bench_decode_cached`; setup
and input demuxing are outside the collection region. Each row decodes the
complete 1,253-frame Sintel clip once with one decoding thread. Symbols are
resolved against each exact executable, including zero-sized NASM symbols.

| Revision | Decode instructions | Reduction from preceding retained row |
|---|---:|---:|
| Previously published decoder | 7,962,063,936 | — |
| AVX strength | 7,868,511,017 | 1.17% |
| AVX strength + specialized setup | 7,686,274,980 | 2.32% |

Together these remove **3.46%** of instructions beyond the published decoder.
Against the original `705286a8a7a8f9118465b2bd83f99a6f066dcbbc` count of
8,679,272,738, the accumulated reduction is **11.44%**. The previously measured
CABAC improvements are unchanged; these new changes target deblocking.
[Raw instruction results](h264-deblock-results.csv) include the rejected
experiments with explicit stage labels.

## Native timing

The Linux `dlmopen` harness alternates baseline/candidate order for every
packet, performs nine decode loops per run and three runs per clip, and uses
thread CPU time. No compilation or profiling runs concurrently with these
measurements. Each packet's median across loops is summed; the ratios below
are baseline/candidate. The final comparison includes both retained changes
against the previously published decoder, keeping the earlier CABAC and
pixel kernels identical in both libraries.

| Clip | Packet-median speedup ratios, three runs | Median ratio |
|---|---|---:|
| Sintel, 1,253 frames | 1.027342, 1.028114, 1.023170 | 1.027342 |
| Animation, 90 frames | 1.054794, 1.028039, 1.035566 | 1.035566 |
| Synthetic 720p, 300 frames | 1.027782, 1.021573, 1.018866 | 1.021573 |

The isolated strength change had a median ratio of 1.018257; specialized
setup then had 1.017058. Use the combined measurements above for the overall
result instead of multiplying isolated ratios.

This VM has substantial timing noise. For example, total thread-CPU ratios
for combined Sintel runs were 1.040856, 1.030927, and 0.973978. The packet
statistic estimates a roughly 2–4% improvement across these clips; it does
not establish an equivalent end-to-end wall-clock gain. Hardware counters
remain unavailable. Callgrind instruction reductions are distinct from
native speedups. [All native runs](h264-deblock-native.csv) include total CPU
time as well as packet statistics, including rejected experiments.

## Rejected experiments

- Specializing chroma inside `ff_h264_filter_mb_fast` removed only 0.26% of
  full-decode instructions and added about 12 KiB of function text. Its median
  packet ratio was 1.003076, too small to retain.
- Reusing the previous macroblock's cached right-edge motion/reference data
  removed 6.63% of setup instructions, but its isolated native median ratio
  was 0.999213. The instruction profile for this experiment includes the
  chroma specialization; the native comparison isolates cache reuse against
  the retained setup revision. Neither change is retained.
- Skipping horizontal-edge motion comparisons when all four NNZ strengths
  were already determined increased strength-kernel instructions from
  283,341,980 to 287,349,180. It failed the instruction gate and was discarded.

## Validation and reproduction

The retained decoder passed all **592 checkasm tests**. The new strength test
checks 8,192 cases per implementation against an independent scalar
reference: P/B lists, frame/field thresholds, edge counts and steps, motion
masks, wrapped 16-bit differences, threshold boundaries, and matching normal
and crossed reference pairings. Inputs include padding for full-vector reads
by existing SIMD implementations. Only requested output edges are compared:
legacy implementations may also calculate unused horizontal edges.

Full frame hashes match the original/retained reference for animation,
Sintel, synthetic 720p, and Frinkiac at both one and four decoder threads.
Additional 30-frame High 10, 4:2:2, 4:4:4, MBAFF, and CAVLC clips match the
original decoder. Animation also matches with CPU flags `0` and `-avx`.

The minimal build still disables autodetection, everything by default,
network support, documentation, ffplay/ffprobe, swscale, and swresample. It
explicitly enables H.264 decoding and the small set of demuxers, protocols,
output encoders/muxers, and null filtering used by the existing harness.
`ldd ffmpeg` lists only libc and libm in addition to the loader/vDSO.
Use the configure and harness commands under
[Minimal build and reproduction](h264-optimization-notes.md#minimal-build-and-reproduction).
The new focused correctness command is:

```sh
make -j8 tests/checkasm/checkasm
./tests/checkasm/checkasm --test=h264dsp --function='loop_filter_strength*'
```

For Callgrind, build `tools/h264_decode_bench.c` against each revision's
minimal static libraries, collect only `h264_bench_decode_cached*`, and use
`tools/h264_callgrind_summary.py` with that exact executable. For native
comparisons, build `tools/h264_decode_compare.c` as an isolated shared
library for each revision and run the harness with `INPUT BASELINE.so
CANDIDATE.so 9 3`. Run native timing separately from profiling and builds.
