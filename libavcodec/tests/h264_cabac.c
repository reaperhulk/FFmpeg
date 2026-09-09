/* SPDX-License-Identifier: LGPL-2.1-or-later */

#include <limits.h>
#include <stdio.h>
#include <string.h>

#define H264_CABAC_BSF 1
#define UNCHECKED_BITSTREAM_READER 1
#include "libavcodec/cabac_functions.h"
#include "libavcodec/h264dsp.h"
#include "libavutil/cpu.h"
#include "libavutil/lfg.h"
#include "libavutil/intreadwrite.h"

/* Keep the arithmetic reference independent of the x86 bin readers under
 * test. The test inputs are padded and cannot exhaust their 8192-byte buffer. */
static void reference_refill(CABACContext *c, int shift)
{
    uint32_t value = 2U * AV_RB16(c->bytestream) - CABAC_MASK;
    c->low = (uint32_t)c->low + (value << shift);
    c->bytestream += 2;
}

static int reference_bin(CABACContext *c, uint8_t *state)
{
    int s = *state;
    int lps = ff_h264_lps_range[2 * (c->range & 0xc0) + s];
    int mps = c->range - lps;
    int shift;
    if (c->low >= (mps << 17)) {
        c->low -= mps << 17;
        c->range = lps;
        s = ~s;
    } else {
        c->range = mps;
    }
    *state = ff_h264_mlps_state[128 + s];
    shift = ff_h264_norm_shift[c->range];
    c->range <<= shift;
    c->low <<= shift;
    if (!(c->low & CABAC_MASK))
        reference_refill(c, ff_ctz(c->low) - CABAC_BITS);
    return s & 1;
}

static int reference_bypass(CABACContext *c)
{
    c->low *= 2;
    if (!(c->low & CABAC_MASK))
        reference_refill(c, 0);
    if (c->low >= c->range << 17) {
        c->low -= c->range << 17;
        return 1;
    }
    return 0;
}

/* Independent coefficient-level loop using the independent CABAC bit reader. */
static void residual_values(CABACContext *c, int16_t *block,
                            const uint8_t *scan, const uint32_t *qmul,
                            const int *index, int count, uint8_t *state)
{
    static const uint8_t level1[8] = { 1, 2, 3, 4, 0, 0, 0, 0 };
    static const uint8_t greater1[8] = { 5, 5, 5, 5, 6, 7, 8, 9 };
    static const uint8_t transition[2][8] = {
        { 1, 2, 3, 3, 4, 5, 6, 7 },
        { 4, 4, 4, 4, 5, 6, 7, 7 },
    };
    int node = 0;
    while (count) {
        uint32_t magnitude = 1;
        int j = scan[index[--count]];
        if (!reference_bin(c, state + level1[node])) {
            node = transition[0][node];
        } else {
            uint8_t *ctx = state + greater1[node];
            node = transition[1][node];
            magnitude = 2;
            while (magnitude < 15 && reference_bin(c, ctx))
                magnitude++;
            if (magnitude == 15) {
                int k = 0;
                while (reference_bypass(c) && k < 23)
                    k++;
                magnitude = 1;
                while (k--)
                    magnitude = 2 * magnitude + reference_bypass(c);
                magnitude += 14;
            }
        }
        if (reference_bypass(c))
            magnitude = -magnitude;
        block[j] = (int32_t)(magnitude * qmul[j] + 32) >> 6;
    }
}

static int reference_mvd(CABACContext *c, uint8_t *state, int amvd, int *abs)
{
    int mvd = 1, ctx = 3;
    if (!reference_bin(c, state + (amvd > 2) + (amvd > 32))) {
        *abs = 0;
        return 0;
    }
    while (mvd < 9 && reference_bin(c, state + ctx)) {
        if (mvd < 4)
            ctx++;
        mvd++;
    }
    if (mvd >= 9) {
        int k = 3;
        while (reference_bypass(c)) {
            mvd += 1 << k;
            if (++k > 24)
                return INT_MIN;
        }
        while (k--)
            mvd += reference_bypass(c) << k;
    }
    *abs = FFMIN(mvd, 70);
    return reference_bypass(c) ? -mvd : mvd;
}

int main(void)
{
    static uint8_t data[8192];
    H264DSPContext dsp = { 0 };
    AVLFG rng;
    ff_h264dsp_init(&dsp, 8, 1);
#if ARCH_X86_64 && HAVE_X86ASM
    if ((av_get_cpu_flags() & AV_CPU_FLAG_BMI2) && (!dsp.decode_residual || !dsp.decode_mvd_pair)) {
        fprintf(stderr, "H.264 CABAC BMI2 dispatch was not installed\n");
        return 1;
    }
#endif
    if (!dsp.decode_residual) {
        fprintf(stderr, "Skipping optimized H.264 CABAC: unavailable on this CPU/build\n");
        return 0;
    }
    for (int depth = 8; depth <= 10; depth += 2) {
        for (int chroma = 0; chroma <= 3; chroma++) {
            H264DSPContext other = { 0 };
            if (depth == 8 && chroma == 1)
                continue;
            ff_h264dsp_init(&other, depth, chroma);
            if (other.decode_residual || other.decode_mvd_pair) {
                fprintf(stderr, "Unexpected CABAC dispatch for depth %d chroma %d\n",
                        depth, chroma);
                return 1;
            }
        }
    }
    av_lfg_init(&rng, 0x48323634);
    /* Exercise both symbol outcomes and one/multiple-bit refill boundaries
     * for every probability state and normalized arithmetic range. */
    memset(data, 0xA5, sizeof(data));
    for (int state = 0; state < 128; state++) {
        for (int range = 256; range < 511; range++) {
            unsigned split = (range - ff_h264_lps_range[2 * (range & 0xc0) + state]) << 17;
            unsigned lows[] = { 1, 0x8000, split - 1, split + 1,
                                split + 0x8000, ((unsigned)range << 17) - 1 };
            for (int i = 0; i < FF_ARRAY_ELEMS(lows); i++) {
                CABACContext ref, opt;
                uint8_t s0 = state, s1 = state;
                if (ff_init_cabac_decoder(&ref, data, sizeof(data)) < 0)
                    return 1;
                ref.low = lows[i];
                ref.range = range;
                opt = ref;
                int expected = reference_bin(&ref, &s0);
                if (get_cabac_inline(&opt, &s1) != expected || s0 != s1 ||
                    ref.low != opt.low || ref.range != opt.range ||
                    ref.bytestream != opt.bytestream) {
                    fprintf(stderr, "Bin mismatch: state %d range %d case %d\n",
                            state, range, i);
                    return 1;
                }
            }
        }
    }
    for (int test = 0; test < 20000; test++) {
        CABACContext ref, opt;
        uint8_t state0[10], state1[10], scan[64], sig0[64], sig1[64], last0[64], last1[64], offsets[63];
        uint32_t qmul[64];
        int16_t block0[64], block1[64];
        int index[64], count = 0, max_coeff = 1 + (test % 64), result;
        for (int i = 0; i < sizeof(data); i++)
            data[i] = test % 4 == 0 ? 0 : test % 4 == 1 ? 255 : av_lfg_get(&rng);
        data[0] &= 127;
        for (int i = 0; i < 10; i++)
            state0[i] = state1[i] = av_lfg_get(&rng) & 127;
        for (int i = 0; i < 64; i++) {
            qmul[i] = av_lfg_get(&rng);
            block0[i] = block1[i] = av_lfg_get(&rng);
            scan[i] = i;
            sig0[i] = sig1[i] = av_lfg_get(&rng) & 127;
            last0[i] = last1[i] = av_lfg_get(&rng) & 127;
            if (i < 63)
                offsets[i] = av_lfg_get(&rng) % 15;
        }
        for (int i = 63; i > 0; i--) {
            int j = av_lfg_get(&rng) % (i + 1);
            FFSWAP(uint8_t, scan[i], scan[j]);
        }
        if (ff_init_cabac_decoder(&ref, data, sizeof(data)) < 0)
            return 1;
        opt = ref;
        for (int pos = 0; ; pos++) {
            if (pos == max_coeff - 1) {
                index[count++] = pos;
                break;
            }
            if (reference_bin(&ref, sig0 + (max_coeff == 64 ? offsets[pos] : pos))) {
                index[count++] = pos;
                if (reference_bin(&ref, last0 + (max_coeff == 64 ? ff_h264_last_coeff_flag_offset_8x8[pos] : pos)))
                    break;
            }
        }
        residual_values(&ref, block0, scan, qmul, index, count, state0);
        result = dsp.decode_residual(&opt, block1, scan, qmul, sig1, last1,
                                      state1, max_coeff, offsets);
        if (result != count ||
            memcmp(sig0, sig1, sizeof(sig0)) ||
            memcmp(last0, last1, sizeof(last0)) ||
            memcmp(block0, block1, sizeof(block0)) ||
            memcmp(state0, state1, sizeof(state0)) ||
            ref.low != opt.low || ref.range != opt.range ||
            ref.bytestream != opt.bytestream) {
            fprintf(stderr, "Residual mismatch on case %d, count %d\n", test, count);
            return 1;
        }
    }
    for (int test = 0; test < 20000; test++) {
        CABACContext ref, opt;
        uint8_t state0[14], state1[14];
        int out0[4] = { 12345, 12345, 12345, 12345 }, out1[4];
        int ax = av_lfg_get(&rng) % 141, ay = av_lfg_get(&rng) % 141;
        int result;
        memcpy(out1, out0, sizeof(out0));
        for (int i = 0; i < sizeof(data); i++)
            data[i] = test % 4 == 0 ? 0 : test % 4 == 1 ? 255 : av_lfg_get(&rng);
        data[0] &= 127;
        for (int i = 0; i < 14; i++)
            state0[i] = state1[i] = av_lfg_get(&rng) & 127;
        if (ff_init_cabac_decoder(&ref, data, sizeof(data)) < 0)
            return 1;
        opt = ref;
        out0[0] = reference_mvd(&ref, state0, ax, &out0[2]);
        out0[1] = reference_mvd(&ref, state0 + 7, ay, &out0[3]);
        result = dsp.decode_mvd_pair(&opt, state1, ax, ay, out1);
        if (result != -(out0[0] == INT_MIN || out0[1] == INT_MIN) ||
            memcmp(out0, out1, sizeof(out0)) ||
            memcmp(state0, state1, sizeof(state0)) ||
            ref.low != opt.low || ref.range != opt.range ||
            ref.bytestream != opt.bytestream) {
            fprintf(stderr, "MVD mismatch on case %d\n", test);
            return 1;
        }
    }
    fprintf(stderr, "195840 bins, 20000 residuals, 20000 MVDs passed\n");
    return 0;
}
