# H.264 follow-up experiments

This pass tested ten candidates against published revision
`a4b943bc01be3b25c971e4d4ebc0ad31eb7be40a`. No new decoder change is retained:
none established a substantial, repeatable native improvement across the
tested clips. The previously published decoder and its measurements remain
unchanged. This report records negative results as well as the strongest
remaining lead.

## Method

The minimal configuration, Xeon Platinum 8573C, GCC 13.3, NASM 2.16.03,
and cached-packet harness are unchanged from
[the preceding investigation](h264-deblock-notes.md). No external decoder
dependencies were added. Each native comparison uses separately linked
decoder libraries, `-Bsymbolic` and `dlopen` with `RTLD_DEEPBIND`, one decoding
thread, nine complete decode loops per run, and three runs. Execution order
alternates by packet. Builds and profiling do not run concurrently with native
measurements.

Reported gains are the median of the three baseline/candidate ratios of
summed packet medians, minus one. They are throughput estimates, not elapsed
time reductions. [Raw native results](h264-followup-native.csv) retain every
run, both total thread CPU time and the packet statistic. Scheduling noise is
substantial; small gains on one clip do not establish a general improvement.
Hardware performance counters remain unavailable on this host.

Callgrind collects only inside `h264_bench_decode_cached`, excluding demuxing
and initialization. Counts cover all 1,253 Sintel frames and are resolved
against each candidate's exact executable. The baseline is **7,686,274,980**
instructions. [Raw instruction results](h264-followup-instructions.csv) use
that same baseline throughout; negative reductions mean more instructions.

## Results

| Candidate | Full Sintel instruction reduction | Sintel native gain | Disposition |
|---|---:|---:|---|
| Propagate simple-mode constants through motion compensation | 0.156% | Not timed separately | Too small to pursue alone |
| Above plus inline the common 16x16 motion-compensation path | 1.306% | 0.344% | Rejected: negligible native gain |
| AVX2 two-row chroma8 bilinear interpolation | 0.170% | Not timed | Too little full-decode instruction benefit to pursue in this pass |
| Inline fixed prefetch sequences | 1.588% | 0.195% | Rejected: animation also flat |
| Share Cb/Cr deblocking threshold setup | 0.447% | Not timed | Too little full-decode instruction benefit for the added complexity |
| Packed CABAC range/normalization lookup, implicit range bit | -1.156% | 1.128% | Best lead, but insufficient and clip-dependent |
| Packed lookup, reconstruct canonical range after every bin | Not collected | -0.126% | Rejected: loses the Sintel benefit |
| Conditional move for CABAC low-value subtraction | Not collected | -0.213% | Rejected: flat or slower |
| Precise assembly memory operands plus register-held input pointer | Not collected | -0.038% | Rejected: flat or slower |
| Allow reuse of the constant CABAC table address | Not collected | -0.167% | Rejected: flat |

The motion-compensation and prefetch experiments illustrate why removing
instructions is insufficient: their 1.3–1.6% full-decode instruction savings
yielded only about 0.2–0.3% on Sintel. The prefetch candidate's median gain
was -0.151% on animation and 1.303% on synthetic 720p. It changes how the same
prefetch hints are issued, not the actual pixel or entropy work.

The paired chroma setup reduced instructions in `ff_h264_filter_mb_fast`
from 552,821,223 to 518,488,976 (6.21%), but that is only 0.447% of the full
decode. This is an instruction-based screening decision, not a measured native
regression. The AVX2 chroma candidate was also screened before native timing.

## Packed CABAC lookup

This experiment replaces the dependent normalization-byte lookup with a
16-bit table entry containing both LPS range and normalization shift.
Normalized ranges are always 256–511; the private assembly representation
retains the low byte and reconstructs the implicit bit 8 where needed.
MPS ranges are 128–511, allowing their zero-or-one normalization shift to be
encoded arithmetically. Canonical range is restored when returning to C.
State transition and 8x8 last-coefficient tables retain their existing offsets
in a private read-only table. The scalar representation is unchanged.

| Clip | Three packet-median speedup ratios | Median gain |
|---|---|---:|
| Sintel | 1.012100, 1.007625, 1.011281 | 1.128% |
| Animation | 0.998421, 1.021722, 0.992201 | -0.158% |
| Synthetic 720p | 1.024557, 1.035545, 1.011319 | 2.456% |

Full-decode instructions **increase** to **7,775,111,404**, or 1.156%.
Exclusive instructions in the fused residual, MVD-pair, and CBP routines
increase from 755,331,000 to 844,167,424. The general macroblock CABAC reader
is unchanged. A shorter load-dependency chain is a plausible explanation for
the small native benefit despite more instructions; these measurements do not
directly establish cycle latency or hardware cache behavior.

Reconstructing canonical range after every bin instead gives a median Sintel
gain of -0.126%, with 1.476% on 720p. Neither representation is retained.
The original packed representation is the most useful candidate to revisit
on a quiet physical host with hardware counters, particularly with additional
entropy-heavy real-world clips. It is not claimed as another breakthrough.

## Correctness and final state

All four CABAC arithmetic/compiler variants and the table-address variant
passed `fate-h264-cabac`, including the independent arithmetic/state checks
across 255,840 cases. Full Sintel frame hashes matched the retained decoder
for the implicit packed lookup, register-input-pointer, and table-address
variants. The canonical packed and conditional-move variants passed the
independent tests but did not receive a separate full-frame hash comparison.

The AVX2 chroma prototype passed 24 chroma checkasm tests and the full Sintel
frame-hash comparison; the existing chroma checkasm cases alone do not cover
all interpolation fractions. Motion-compensation, prefetch, and paired
chroma-setup candidates also matched the full Sintel reference. No rejected
candidate is presented as having passed the broader retained-code regression
matrix.

The source and minimal executable were restored to the published decoder
after the experiments. This commit adds measurements and analysis only.
