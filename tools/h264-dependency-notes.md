# CABAC dependency-chain experiments

Baseline: e27dec112b0d67c13d7a354ce979be9862255328 (decoder code unchanged
from a4b943bc). These are independent prototypes against that baseline,
not cumulative optimizations. The minimal build configuration and cached-packet
A/B harness are unchanged. No additional decoder dependencies were introduced.

## Prototypes

- Direct LZCNT replaces the range normalization table lookup with
  `lzcnt(range) - 23` in the fused residual, MVD, and CBP kernels.
- Left-aligned range keeps `range << 23` inside those kernels, uses a private
  table of scaled LPS ranges, and obtains normalization directly with LZCNT.
  Entry and exit convert to the canonical CABAC context representation.
- Register-held unary state keeps a coefficient-level probability state in
  a register throughout the unary loop and stores it once on exit. It saves
  and restores the residual node register around the loop. This removes
  repeated state stores and their store-to-load dependency at the expense
  of setup and exit work.

The LZCNT variants are host-only experiments: this machine advertises ABM.
Their archived patches retain the existing BMI2 dispatch, which is **not**
adequate for deployment because BMI2 does not imply LZCNT. A retained version
would require explicit LZCNT detection and a fallback. The patches are not
applied to the published decoder.

All three prototypes passed 255,840 independent CABAC cases, including exact
arithmetic state, probability updates, input positions, residual output, MVD,
and CBP comparisons. All matched every frame hash of the 1,253-frame Sintel
decode with one thread. No broader-format validation is claimed for these
rejected prototypes.

Native measurements use nine loops per run and three runs per clip, alternating
baseline/candidate order per cached packet. The reported gain is the median
of the three ratios of summed packet medians, expressed as throughput change.
Raw thread CPU measurements are included in the CSV; this VM exhibits
substantial timing noise. Builds and profiling do not overlap native timing.

| Experiment | Sintel native gain | Synthetic 720p native gain |
|---|---:|---:|
| lzcnt-direct | -0.608% | +1.787% |
| lzcnt-scaled | -1.066% | +0.864% |
| unary-register | +0.069% | +0.662% |

None meets the threshold for a substantial, consistent native improvement.
All decoder changes were reverted. Each archived patch applies independently
to the baseline; do not apply them cumulatively.

## Full-decode instruction check

Callgrind on the register-held unary-state version counted 7,687,201,862 instructions
versus 7,686,274,980 for the baseline: **926,882 more instructions
(+0.012%)**. The entire difference is in
`ff_h264_decode_residual_8_bmi2`, which rises from 442,784,514 to 443,711,396
instructions (+0.209%). The save/restore and loop-exit overhead
outweighs the removed stores on this clip. All other attributed function counts
are unchanged.

The cached-packet harness decoded all 1,253 frames once with one thread;
collection was restricted to `h264_bench_decode_cached*`. The exact candidate
executable was supplied to the NASM-aware summary tool. Native timing was
complete before profiling began. Neither LZCNT prototype was profiled after
its native results failed the retention criterion.

This pass does not establish a new decoder speedup. In particular, replacing
a dependent lookup with an arithmetic instruction is insufficient by itself:
its operand preparation, surrounding dependency chain, and stream workload
also affect the result.
