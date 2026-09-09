# Deblock, prefetch, and separable AVX2 interpolation experiments

Baseline: `199ed0a18d9eb467b06399258df89a37393f2d41`. Decoder code is unchanged
from the previously retained a4b943bc/a127376 work. This pass found substantial
instruction reductions inside another interpolation kernel, but no substantial
full-decoder speedup. All four prototypes are rejected from the runtime source
and archived as independent patches under `tools/h264-experiments/`.

## Native comparisons

The minimal FFmpeg configuration is unchanged, with no new dependencies.
The cached-packet A/B harness alternates baseline/candidate packet order and
uses one decoding thread. Each experiment has three runs; the table states
loops per run. The five-loop interpolation measurements are screening runs,
not a claim of a statistically resolved sub-percent effect. Percentages are
median throughput ratios from summed packet medians. Raw thread CPU totals
and all three packet statistics are in `h264-pixel-followup-native.csv`.

| Experiment | Loops/run | Sintel throughput gain | Synthetic 720p gain |
|---|---:|---:|---:|
| deblock-empty | 9 | -0.456% | -0.750% |
| no-prefetch | 9 | -2.955% | -5.592% |
| hv2 | 5 | -0.451% | Not run |
| hv12 | 5 | +0.230% | -0.782% |

No compilation, profiling, or other benchmark ran alongside any retained native
measurement. The prefetch experiment's 720p job continued after rejection on
Sintel; it also completed without overlapping builds, so its results are included.
This VM remains noisy; microbenchmarks and full-decode timing must be considered
separately.

## Deblock empty-mask exit

The AVX luma kernel tests the combined pixel/strength mask and returns when
no pixels can change. This skips most arithmetic and stores for those calls.
It passes all 88 H.264 DSP checkasm tests and matches every Sintel frame hash,
but the native results do not justify adding the branch. The unchanged SSE2
fallback and other deblock kernels are not modified by this patch.

## Removing software prefetch

This prototype disables motion-reference prefetching and the two destination
prefetch calls in the non-4:4:4 macroblock template. It matches the full Sintel
decode. It removes both prefetch calls and the address calculations feeding
them, but decoding becomes slower. Fewer instructions coincides with slower decoding here, consistent with
prefetching hiding memory latency. Instruction count is not by itself a valid
retention criterion. This does not identify exact cache-miss counts because
hardware performance counters remain unavailable.

## AVX2 separable interpolation

The second-pass prototype handles all sixteen columns in one YMM vector,
using unaligned word loads rather than assembling two eight-column halves
with SSSE3 alignment shuffles. Packing joins the two lanes into the final
sixteen pixels. Both put and average operations are provided. Dispatch uses
the existing 64-bit fast-AVX2 eligibility and changes only 8-bit 16x16 fractions
(2,1), (1,2), (2,2), (3,2), and (2,3).

The second prototype adds an AVX2 vertical first pass for sixteen temporary
columns. The existing SSE2 kernel supplies the remaining eight columns of the
24-column temporary buffer. The arithmetic and intermediate rounding follow
the existing implementation; this removes one SSE2 call and processes twice
as many first-pass columns per vector. The `hv12` patch includes both changes;
each archived patch applies independently to the baseline.

Both versions pass all 282 H.264 qpel checkasm tests and match every frame hash
of the full 1,253-frame Sintel decode. These checks cover both put/average
operations and all interpolation fractions. No broader frame-format validation
is claimed for the rejected prototypes.

A short checkasm benchmark for `put_h264_qpel_16_mc22_8` measured 334.7 cycles
for SSSE3 versus 187.3 for the second-pass AVX2 version in one run. A separate
run with both passes measured 267.2 versus 160.6 cycles. Those are approximately
44% and 40% lower, respectively, but absolute timings varied substantially
between runs. They do not measure the first pass's incremental benefit, and
neither establishes a corresponding full-decode gain. Raw logs are preserved
in `h264-pixel-followup-micro.txt`.

## Full-decode Callgrind

Collection is restricted to `h264_bench_decode_cached*`: one complete Sintel
decode, one thread, 1,253 frames. Each NASM-aware summary uses the exact candidate
executable. All three profiled runs completed the full frame count. The deblock
prototype was not profiled after failing the native screen.

| Experiment | Full decode instructions | Reduction |
|---|---:|---:|
| Baseline | 7,686,274,980 | — |
| hv2 | 7,637,593,129 | 0.633% |
| hv12 | 7,605,943,132 | 1.045% |
| no-prefetch | 7,387,691,598 | 3.885% |

The put half-pel second-pass kernel alone falls from 79,913,444 SSSE3
instructions to 34,233,478 AVX2 instructions, a 57.16% reduction. The combined
version removes about 1% of all decode instructions, which limits the possible
overall benefit. Its native results remain flat to slightly slower in this
screen, so it is preserved as a reproducible prototype rather than enabled
in the published decoder.

The previously validated decoder was restored and rebuilt after profiling.
