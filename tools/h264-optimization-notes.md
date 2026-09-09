# H.264 High / yuv420p optimization investigation

Target: software decoding of High-profile, 8-bit 4:2:0 H.264 on x86-64.
Baseline: `705286a8a7a8f9118465b2bd83f99a6f066dcbbc` from
[reaperhulk/FFmpeg](https://github.com/reaperhulk/FFmpeg).
Measurements: Intel Xeon Platinum 8573C, GCC 13.3, NASM 2.16.03,
Linux virtual machine; one decoding thread unless stated otherwise.

The subsequent [deblocking follow-up](h264-deblock-notes.md) adds two
optimizations, reaching 11.44% fewer full-decode instructions on Sintel versus
the original revision. A cumulative native comparison against that same original
revision estimates 7.0% higher packet-median throughput on Sintel, 3.7% on animation,
and 4.3% on synthetic 720p. Details and timing limitations are in the follow-up.

## What the original source uses

- `libavcodec/x86/h264_qpel.c` dispatches 8-bit quarter-pixel interpolation
  primarily to SSE2/SSSE3. Many positions use C wrappers that call several
  assembly filters and combine temporary blocks. The original 16-wide
  vertical path filters the two eight-pixel halves separately.
- `libavcodec/x86/h264dsp_init.c` selects MMXEXT for deblocking-strength
  calculation and SSE2/SSSE3/128-bit AVX for several pixel operations.
- `libavcodec/x86/h264_intrapred_init.c` has some AVX2 dispatch, but that does
  not make the whole 8-bit decoding pipeline AVX2-wide.
- `libavcodec/x86/cabac.h` has scalar inline assembly. CABAC's arithmetic
  state depends on preceding bins; widening pixel kernels does not remove
  this serial entropy-decoding bottleneck.

Software sampling identified entropy decoding as a major cost, especially
on the synthetic clip. This was a timer-based instruction-pointer sampler,
not hardware performance-counter profiling. Kernel speedups below must not
be read as whole-decoder speedups.

## Separate optimization commits

| Commit | Change | Kernel measurements on this CPU |
|---|---|---|
| `1375d7a` | Full-width 16x16 vertical AVX2, fused quarter-pixel averaging | About 1.7x |
| `dbd4f09` | Full-width 16x16 horizontal AVX2 | About 2.4–2.8x |
| `f8c3cc5` | Fused horizontal/vertical filters for odd/odd diagonal positions | About 2x at 16x16; 1.3–1.4x at 8x8 |
| `34db062` | Two 8-pixel horizontal rows per AVX2 vector | Usually 2.3–2.8x; the half-pixel average case showed a much smaller gain |
| `a9daa66` | Two 16-pixel weighted-prediction rows per AVX2 vector | About 1.28x; 45% fewer instructions in this function on Sintel |

Pixel-kernel comparisons use checkasm against the preceding SSE2/SSSE3
implementation, not against C. These are indicative ranges from this host,
not guarantees for other processors. New AVX2 dispatch is gated by
`EXTERNAL_AVX2_FAST` and 8-bit depth.

The earlier residual-only prototype `7856287` was reverted by `5251fa1`
after inconclusive native timings. It is now reintroduced by `bc30b26` as
part of the measured CABAC changes below. The final branch retains the
branchless arithmetic update, not the instruction-minimizing MPS branch.

| CABAC commit | Change |
|---|---|
| `bc30b26` | Reintroduce fused BMI2 residual decoding |
| `41f300b` | Inline syntax readers and residual wrappers |
| `0561138` | Inline neighbor/cache setup and skipped-macroblock handling |
| `b216fc3` | Decode horizontal/vertical motion-vector differences with shared register-resident CABAC state |
| `38cbb1c` | Fuse the luma/chroma coded-block-pattern bins |
| `eac5830` | Compute the refill position directly with BSF in H.264's x86 reader |
| `16e2ee7` | Specialize 8-bit 4:2:0 without MBAFF and propagate constants into cache helpers |

Fused assembly dispatch requires x86-64, BMI2, 8-bit depth, and chroma
format 4:2:0. The format specialization retains field-picture handling;
other depths, chroma formats, and MBAFF use the general path.

Rejected experiments were not left enabled: two AVX-512 horizontal kernels
(including a VBMI masked-load variant), AVX-512 weighted prediction, an
8-wide vertical AVX2 variant, MPS-branch CABAC, a conditional normalization
shortcut, a C-only bin reader, precise inline-assembly memory constraints,
and cache-pointer restrict annotations. Several reduced instruction counts
but lost native performance. The MPS version reached about 12.7% fewer
CABAC instructions on Sintel yet regressed repeated-packet timing by 5–7%.
The retained version obtains its savings mainly from fusion, inlining, and
format specialization.

## Decoder measurements

Both revisions were built with the identical minimal configuration below.
The A/B tool caches demuxed H.264 packets, loads isolated decoder libraries,
and alternates which decoder processes each packet first. Both decoders
use one thread. This excludes demuxing, output, filtering, and decoder setup.
It measures send/receive calls, including reference-frame management.

The host showed substantial timing noise. In addition to total thread CPU
time, the tool records each packet repeatedly, takes its median across
loops, and sums those packet medians for each decoder. This is a diagnostic
estimate; it is **not** an end-to-end elapsed-time measurement. The table
reports the median ratio across three runs; ratios above 1 favor the branch.
The earlier pixel-kernel runs below were pinned to CPU 2. The later CABAC
continuation measurements are described separately and were not pinned.

The qpel-only revision (`5251fa1`) measured as follows:

| Clip | Frames per clip | Loops/run | Total CPU ratio | Repeated-packet median ratio |
|---|---:|---:|---:|---:|
| Sintel trailer, High/yuv420p, 854x480 | 1253 | 7 | 0.978 | 1.021 |
| testsrc2, High/yuv420p, 1280x720 | 300 | 9 | 0.954 | 1.008 |
| Short animation, High/yuv420p, 480x360 | 90 | 31 | 1.066 | 1.011 |

After adding weighted prediction (`a9daa66`), three Sintel runs gave total
CPU ratios 1.071, 1.053, and 1.029; repeated-packet median ratios were 1.040,
1.021, and 1.013. The median packet-based estimate is therefore about 2.1%,
with enough spread that the instruction counts below are stronger evidence
of the work actually removed.

The disagreement between total CPU ratios and packet medians demonstrates
why small whole-decoder timing claims are unreliable on this VM. These
results support substantial improvements in selected interpolation kernels,
but **do not establish a large whole-decoder speedup**. Earlier ~5% CABAC
estimates from total CPU timings were not confirmed by the more
noise-resistant measurements. Broader physical-machine benchmarks and the
user's actual footage remain necessary before treating this investigation
branch as production-ready.

The real trailer is available from
[W3C's Sintel test video](https://media.w3.org/2010/05/sintel/trailer.mp4).
The animation test was a short Main-profile clip re-encoded to High profile;
it is too small and specialized to stand in for a production corpus.
The synthetic clip can be regenerated with an external input-generation
FFmpeg that has libx264:

```sh
ffmpeg -f lavfi -i testsrc2=size=1280x720:rate=30 -t 10 -an \
  -c:v libx264 -preset medium -crf 20 -threads 4 -pix_fmt yuv420p testsrc2-720p.mp4
```

The tested decoder builds do not contain libx264 or any other external
codec dependency.

## Instruction profiling

Hardware instruction counters were unavailable: a direct `perf_event_open`
request for user-space retired instructions returned `ENOENT`, and
`/sys/bus/event_source/devices` exposed only `breakpoint`, `msr`, and
`software`, with no CPU PMU. Instead, Valgrind 3.27.1 was built locally and
Callgrind counted executed instructions inside `h264_bench_decode_cached`
and its callees. The minimal decoder gained no profiler dependency.

| Clip / revision | Original instructions | Candidate instructions | Reduction |
|---|---:|---:|---:|
| Sintel, qpel only | 8,679,272,738 | 8,382,220,629 | 3.42% |
| Sintel, qpel + weighted prediction (`a9daa66`) | 8,679,272,738 | 8,306,554,408 | 4.29% |
| testsrc2, qpel only | 5,016,590,654 | 4,979,506,019 | 0.74% |
| Animation, qpel only | 238,055,788 | 234,509,095 | 1.49% |

On Sintel, exclusive counts for functions whose names contain `qpel` fell
from 765,443,087 to 475,448,962 (37.9%). All 34 new AVX2 qpel entry points
appear in the resolved profile. The subsequent weighted-prediction change
reduced `ff_h264_weight_16` from 168,117,133 to 92,450,907 instructions
(45.0%). Its reduction exactly accounts for the difference between the
two candidate whole-loop instruction totals.

This separates real instruction savings from timing noise. Instruction
counts are not cycle counts, retired micro-ops, or proof of equal speedups.
Branch-miss columns in `h264-instruction-results.csv` are Callgrind's
simulated predictor results, not hardware measurements. See the
[Callgrind manual](https://valgrind.org/docs/manual/cl-manual.html).

The remaining profile still includes substantial deblocking work. On
Sintel, `loop_filter` alone executes 865 million instructions and the
MMXEXT strength calculation executes 377 million. These remain useful
future targets; instruction counts alone do not establish cycle savings.

## CABAC continuation: target and controls

The acceptance metric is **inclusive executed instructions in
`ff_h264_decode_mb_cabac` over an entire clip**, including syntax decoding,
residuals, motion prediction, and macroblock/cache setup. It is not a claim
of 10% fewer instructions in every individual arithmetic-bin reader.

For the final CABAC comparison, the baseline is `5251fa1` (original CABAC,
new qpel kernels), and the candidate is the same pixel-kernel set plus the
CABAC changes, on `h264-cabac-instruction-investigation` at `d784bf1`.
Both use the same minimal configuration, compiler, input packets, one
thread, one loop, and profiling boundary. No SIMD pixel kernels are
disabled. Initial same-binary BMI2-on/off experiments used `34db062`;
their disabled path still includes callback-check overhead, so the final
reported reductions use the actual original-CABAC baseline instead.

| Clip | Frames | Original CABAC Ir | Retained CABAC Ir | CABAC reduction | Full decode reduction, fixed pixel kernels |
|---|---:|---:|---:|---:|---:|
| animation | 90 | 116,637,829 | 102,923,522 | 11.76% | 5.85% |
| sintel | 1253 | 2,926,573,144 | 2,582,076,452 | 11.77% | 4.11% |
| testsrc2-720p | 300 | 2,547,369,624 | 2,222,135,043 | 12.77% | 6.53% |

CABAC instruction totals and all valid iteration measurements are recorded in
`tools/h264-cabac-results.csv`. Counts are deterministic for a fixed binary,
input, dispatch, and thread configuration. Final detailed runs also collect
simulated cache/branch events and data-reference counts. Two invalid early
MPS runs (a label collision and a stale binary after a build failure) were
discarded and are excluded from the CSV. Intermediate rows are individual
experiments, not a promise that all changes accumulated monotonically.

At the CABAC/weighted-prediction checkpoint, including qpel, weighted prediction, and
CABAC, Sintel's complete cached-decode loop falls from **8,679,272,738**
instructions at `705286a` to **7,962,063,936** at `16e2ee7`: **8.26%** fewer.
The CABAC-only controlled comparison is reported separately in the CSV.

Native CABAC comparison uses the same qpel pixel kernels in both isolated
libraries, alternating packet order, five loops and three runs, without
concurrent compilation/profiling. Repeated-packet median ratios are
**1.023322, 1.029101, 1.023759** (roughly 2.3–2.9% faster; median 2.4%).
Total thread-CPU ratios are **0.923227, 1.037270, 0.997357**. The disagreement
shows substantial host noise; the packet statistic is a diagnostic estimate,
not proof of an end-to-end wall-clock gain, and these results do not establish
a 10% native decoding speedup. No hardware retired-instruction or cycle
counter was available. Do not substitute Callgrind runtime for native timing.

To extract inclusive CABAC costs, use the matching profiler's annotate
script (it may need to be invoked with `perl`):

```sh
perl /path/to/callgrind_annotate --auto=no --inclusive=yes \
  --show=Ir --show-percs=no --threshold=100 decode.callgrind \
  | rg 'PROGRAM TOTALS|ff_h264_decode_mb_cabac'
```

Add `--cache-sim=yes --branch-sim=yes` to the profiling command for data and
simulated branch/cache statistics. `H264_BENCH_CPU_FLAGS=-bmi2` in the
benchmark environment clears only BMI2, retaining AVX2 pixel dispatch;
it isolates the fused callbacks but does not undo C inlining/specialization
or the BSF change. Build the baseline revision to measure the whole CABAC
optimization set.

Build the same profiling harness against each revision's libraries:

```sh
cc -O2 -g -I. -I.. "$candidate_source/tools/h264_decode_bench.c" \
  libavformat/libavformat.a libavcodec/libavcodec.a libavutil/libavutil.a \
  -lm -pthread -o h264-bench-callgrind
valgrind --tool=callgrind --branch-sim=yes \
  --toggle-collect='h264_bench_decode_cached*' \
  --callgrind-out-file=decode.callgrind \
  ./h264-bench-callgrind input.mp4 1 1 1
python3 "$candidate_source/tools/h264_callgrind_summary.py" \
  decode.callgrind ./h264-bench-callgrind \
  --annotate /path/to/callgrind_annotate
```

Keep the exact profiled executable: NASM symbols have zero size and
Callgrind reports many as addresses. The summary tool resolves them with
that executable's `nm` symbols and groups local/compiler suffixes. Using a
newly linked binary to resolve an older profile produces incorrect names.
The timed/profiling loops operate on cached packets; parsing and decoder
initialization are outside the profiling boundary. Each count above covers
one complete clip, one decoding thread, and one loop.

## Minimal build and reproduction

Run this in a separate `build-minimal` directory in each source checkout.
Use the same compiler and assembler for both. No autodetected external
libraries, network support, scaling, resampling, playback, or probing are
included. File demuxing and frame hashing are retained for validation.

```sh
../configure --x86asmexe=nasm \
  --disable-autodetect --disable-everything --disable-network --disable-doc \
  --disable-ffplay --disable-ffprobe --disable-swscale --disable-swresample \
  --disable-shared --enable-static --disable-debug \
  --enable-decoder=h264 --enable-parser=h264 \
  --enable-demuxer=h264,mov,matroska --enable-protocol=file,pipe \
  --enable-encoder=wrapped_avframe,rawvideo --enable-muxer=null,framemd5 \
  --enable-filter=null
make -j8 ffmpeg
```

Set `candidate_source` to the absolute path of this branch's source tree.
From **each** build directory, compile the same wrapper source against that
build's static libraries. The two revisions must have compatible public
FFmpeg ABIs because the harness shares packets and codec parameters.

```sh
cc -O2 -fPIC -shared -Wl,-Bsymbolic -DH264_BENCH_VARIANT -I. -I.. \
  "$candidate_source/tools/h264_decode_compare.c" \
  libavcodec/libavcodec.a libavutil/libavutil.a -lm -pthread -o decoder.so
```

From either build directory, compile the harness:

```sh
cc -O2 -I. -I.. "$candidate_source/tools/h264_decode_compare.c" \
  libavformat/libavformat.a libavcodec/libavcodec.a libavutil/libavutil.a \
  -lm -pthread -ldl -o h264_decode_compare
taskset -c 2 ./h264_decode_compare input.mp4 \
  /absolute/baseline/build-minimal/decoder.so \
  /absolute/candidate/build-minimal/decoder.so 9 3
```

For CABAC isolation, compile a second candidate wrapper with
`-DH264_BENCH_NO_BMI2`; it clears BMI2 dispatch inside that library while
retaining the AVX2 pixel kernels. Do not compare libraries from incompatible
FFmpeg versions. Run benchmarks sequentially, without compilation or other
CPU-heavy work in parallel. The harness checks frame counts, not contents;
frame-hash validation is a separate required step.

For an ordinary cached-packet benchmark with configurable threading, use
`tools/h264_decode_bench.c`; its build command is in the file header.

## Correctness checks

```sh
make -j8 tests/checkasm/checkasm
./tests/checkasm/checkasm --test=h264qpel --bench
./tests/checkasm/checkasm
cc -O2 -I. -I.. ../tools/h264_qpel_validate.c \
  libavcodec/libavcodec.a libavutil/libavutil.a -lm -pthread -o h264_qpel_validate
./h264_qpel_validate
./ffmpeg -v error -threads 1 -i input.mp4 -an -f framemd5 output.framemd5
```

The standalone qpel test makes 25,600 full-destination-buffer comparisons
against C: five padded strides, sixteen source alignments, zero/255,
alternating rows/columns, random pixels, both put/average operations, and
both block sizes. The CABAC/weighted-prediction checkpoint passed 588 checkasm tests, including native calling
conventions and the 9-/10-bit paths. Both `fate-cabac` and
`fate-h264-cabac` pass on the retained branch. The H.264 test compares
195,840 bins, 20,000 residual blocks, 20,000 motion-vector pairs, and 20,000
coded-block patterns against an independent C arithmetic decoder. It checks
outputs, all probability states, input position, and arithmetic low/range,
including refill boundaries and malformed motion-vector magnitudes. It
asserts the BMI2 callbacks are installed and absent for unsupported depth/
chroma combinations, preventing a silent scalar-only pass.

Compare candidate frame hashes with the original revision, at both one and
four decoder threads. All four complete clips passed those comparisons after integration. Additional
30-frame CAVLC, MBAFF, High 10, High 4:2:2, and High 4:4:4 regression clips
match the original decoder. The BMI2-disabled animation fallback also matches.
Weighted prediction
also passed 100 randomized checkasm rounds, with explicit default weight
128 and signed saturation extremes added to the existing test.
