# H.264 High / yuv420p optimization investigation

Target: software decoding of High-profile, 8-bit 4:2:0 H.264 on x86-64.
Baseline: `705286a8a7a8f9118465b2bd83f99a6f066dcbbc` from
[reaperhulk/FFmpeg](https://github.com/reaperhulk/FFmpeg).
Measurements: Intel Xeon Platinum 8573C, GCC 13.3, NASM 2.16.03,
Linux virtual machine; one decoding thread unless stated otherwise.

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

CABAC prototype `7856287` was reverted by `5251fa1`. It remains available
on branch `h264-cabac-prototype`, together with its randomized correctness
test. In isolated measurements its repeated-packet median gain was about
1.5% on synthetic video, while Sintel regressed by about 0.6%. That did not
justify enabling a new entropy-decoding implementation. The active branch
retains the original CABAC decoder.

Rejected experiments were not left enabled: two AVX-512 horizontal kernels
(including a VBMI masked-load variant), an AVX-512 weighted-prediction
variant, an 8-wide vertical AVX2 variant,
branchy CABAC arithmetic, aggressive C inlining, and an extra CABAC
normalization table/state cache. They failed to show sufficiently convincing
additional gains or regressed some cases. AVX-512 correctness alone was not
a reason to select it over the AVX2 implementations.

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
All runs were pinned to CPU 2.

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

The remaining profile is dominated by CABAC, C macroblock/cache handling,
and deblocking. On Sintel, `loop_filter` alone executes 865 million
instructions and the MMXEXT strength calculation executes 377 million.
These are stronger leads for further work than blindly widening every
small interpolation kernel. Their instruction counts still need native
cycle measurements to establish the payoff of an actual implementation.

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
both block sizes. The final full checkasm run passed 588 tests, including native calling
conventions and the 9-/10-bit paths. On the separate CABAC prototype branch, `make
fate-h264-cabac` compares 20,000 randomized residual blocks,
including coefficient output, all context states, coefficient count, input
position, and arithmetic low/range state. It explicitly checks that BMI2
runtime dispatch is installed, preventing a silent C-only test pass.
Initial prototype measurements taken before that assertion was added were
discarded because the optimized dispatch had not been installed.

Compare candidate frame hashes with the original revision, at both one and
four decoder threads. The three benchmark clips passed those comparisons. Weighted prediction
also passed 100 randomized checkasm rounds, with explicit default weight
128 and signed saturation extremes added to the existing test.
