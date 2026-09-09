# Luma fusion and neighbor-cache investigation

This pass implemented the proposed larger CABAC fusion, then investigated
neighbor-cache work using source-level Callgrind attribution and native
instruction-pointer sampling. It did **not** find another substantial native
speedup. The decoder source is restored to the previously published version.
The profiler-summary fix is retained; the decoder prototypes are archived as
patches for review and reproduction.

The comparison baseline is `9d46fe48ba5656deeb9c53efe967ded76de3e822`, whose
decoder code is unchanged from `a4b943bc`. The same minimal configuration and
cached-packet comparison harness were used: one decoder thread, nine loops
per run, three runs per clip, alternating baseline/candidate packet order.
No builds or profiling ran concurrently with native comparisons. No decoder
dependencies were added. Native percentages below are median throughput-ratio
estimates from summed packet medians, not elapsed-time reductions. Raw total
thread CPU times are also retained because this VM has substantial timing
noise.

## Larger fusion

The prototype decodes all luma residual blocks of a non-Intra16 macroblock in
one assembly call. Separate 4x4 and 8x8 variants share the existing arithmetic
macros. They retain low, range, and input position in registers across blocks;
the 4x4 version also decodes coded-block flags and updates the neighbor NNZ
cache. The C caller selects scan, dequantization, and probability-context
tables once per macroblock. Other formats and Intra16 retain their old paths.

The second version skips whole uncoded 8x8 regions and combines the four 8x8
nonzero counts into SIMD stores. It preserves untouched coefficients and
cache entries. Both versions passed the existing 255,840 independent CABAC
cases plus 4,000 new whole-luma-macroblock cases. Those new cases cover all
16 coded-block masks, both transforms, randomized scan permutations and
probability states, evolving neighbor contexts, and untouched-data sentinels.
Both versions matched all 1,253 Sintel frame hashes with one decoder thread.

| Experiment | Full Sintel instructions | Reduction | Sintel native gain |
|---|---:|---:|---:|
| Published baseline | 7,686,274,980 | — | — |
| Initial whole-luma fusion | 7,652,999,769 | 0.433% | -0.431% |
| Fusion with empty-region and NNZ-store improvements | 7,624,399,147 | 0.805% | -0.151% |

The refined version's median gains were 0.387% on High-profile animation,
0.295% on synthetic 720p, and 0.715% on the Main-profile Frinkiac clip. This
does not support retaining the additional decoder implementation. My earlier
expectation that per-block C/assembly transitions were a large remaining cost
was too optimistic.

## Source-level attribution

Only `h264_cabac.o` was rebuilt with debug information. Its `.text` bytes
were verified identical to the refined-fusion object before profiling.
Full-decode Callgrind instructions were also identical: 7,624,399,147.
These source measurements describe that prototype, not the original baseline.

Within `ff_h264_decode_mb_cabac`, source attribution gives:

| Source | Instructions | Share of full decode |
|---|---:|---:|
| Motion prediction and cache header | 638,328,244 | 8.37% |
| Main CABAC C source | 467,550,373 | 6.13% |
| Inline x86 CABAC arithmetic header | 310,540,826 | 4.07% |

The largest helpers in the motion-prediction header are cache filling
(324,117,102), neighbor setup (107,663,765), and motion-list writeback
(72,206,253). Counts here exclude instructions attributed to other headers,
such as SIMD intrinsics. The function named `ff_h264_decode_mb_cabac` includes
considerable non-arithmetic work; its total is not a pure bin-decoding cost.

Source-level profiling exposed a summary-script defect: `callgrind_annotate`
can split a function across source files and omit the object name on some
rows. The old parser discarded those rows. Commit
`41e84140409d62321e19e9b7ce14065e260a15e4` resolves object ownership before
summing rows and avoids guessing if ownership is ambiguous. After the fix,
**every per-function count** in the debug profile matches the corresponding
non-debug profile. Previous full-decode totals and non-debug results are
unaffected.

## Fixed neighbor layout and addresses

With MBAFF disabled, both halves of the left neighbor use the same macroblock
and the block-layout table is fixed. The first cache experiment propagates
that fixed table and the P-skip left-row index. It removes 24,504,579 full-decode
instructions (0.319%) but is flat on Sintel and slower on synthetic 720p.

The broader version also derives top, top-right, top-left, and left motion
addresses from the current macroblock coordinates, retaining the old MBAFF
address path. It reduces full instructions to 7,588,408,499 (1.273%) and
macroblock-CABAC instructions from 1,593,637,894 to 1,495,771,413 (6.141%).

| Clip | Three packet-median ratios | Median gain |
|---|---|---:|
| Sintel | 1.011697, 1.008232, 1.013372 | 1.170% |
| High-profile animation | 0.998801, 1.025430, 1.004050 | 0.405% |
| Synthetic 720p | See raw results | 0.936% |
| Main-profile Frinkiac | See raw results | 0.693% |

This is a modest lead, below the requested substantial gain. Both cache
variants matched the complete single-thread Sintel frame-hash reference;
they were not taken through the broader format/thread regression matrix and
are not enabled in the branch.

## Native sampling cross-check

A separate run sampled instruction pointers with `SIGPROF`/`ITIMER_PROF`
while the exact debug executable decoded cached Sintel packets 20 times:
25,060 frames, 28.232 thread-CPU seconds, and 6,693 samples. The requested
timer interval was 1 ms; actual delivery was coarser. Addresses were binned
at 16 bytes, resolved against that exact executable, and inline stacks were
resolved with `addr2line`. Sampling includes initial setup and shutdown.
It is approximate CPU-time attribution, not hardware cycle accounting.

| Group | Samples | Share of all samples |
|---|---:|---:|
| Entire macroblock CABAC routine | 1,573 | 23.50% |
| Inline CABAC arithmetic within that routine | 564 | 8.43% |
| Motion/cache work within that routine, including inline helpers | 546 | 8.16% |
| Other work within that routine | 463 | 6.92% |
| Fused 8x8 luma kernel | 508 | 7.59% |
| Fused 4x4 luma kernel | 344 | 5.14% |
| MVD-pair kernel | 315 | 4.71% |
| CBP kernel | 158 | 2.36% |

The three macroblock subgroups partition its samples; do not add them to the
entire-routine row. Inline arithmetic accounts for roughly twice the sampled
CPU share suggested by its instruction share. This supports targeting its
serial arithmetic/load dependencies, but does not identify a particular
instruction as the cause. Block fusion did not materially accelerate it.

## Artifacts and reproduction

- [Native runs](h264-fusion-native.csv), including total thread CPU times.
- [Full-decode instruction counts](h264-fusion-instructions.csv).
- [Source-helper instruction counts](h264-fusion-source.csv).
- [Native sampling breakdown](h264-fusion-sampling.csv).
- [Refined luma-fusion patch](h264-experiments/luma-fusion.patch), including
  the independent whole-macroblock tests.
- [Fixed-neighbor-geometry patch](h264-experiments/fixed-neighbor-geometry.patch).

Each patch applies independently to the unchanged decoder source at the
baseline above. Apply one to a clean checkout, use the minimal build described
in [the existing notes](h264-optimization-notes.md), and rebuild the decoder
libraries and harness before measuring. The archived patches are experimental
implementations, not additional enabled optimizations. Patch application was
checked against the restored source. The restored minimal FFmpeg executable
was rebuilt after testing.
