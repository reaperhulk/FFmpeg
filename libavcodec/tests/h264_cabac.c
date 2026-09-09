/* SPDX-License-Identifier: LGPL-2.1-or-later */

#include <stdio.h>
#include <string.h>

#include "libavcodec/cabac_functions.h"
#include "libavcodec/h264dsp.h"
#include "libavutil/cpu.h"
#include "libavutil/lfg.h"

/* Independent coefficient-level loop using the existing CABAC bit reader. */
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
        if (!get_cabac(c, state + level1[node])) {
            node = transition[0][node];
        } else {
            uint8_t *ctx = state + greater1[node];
            node = transition[1][node];
            magnitude = 2;
            while (magnitude < 15 && get_cabac(c, ctx))
                magnitude++;
            if (magnitude == 15) {
                int k = 0;
                while (get_cabac_bypass(c) && k < 23)
                    k++;
                magnitude = 1;
                while (k--)
                    magnitude = 2 * magnitude + get_cabac_bypass(c);
                magnitude += 14;
            }
        }
        if (get_cabac_bypass(c))
            magnitude = -magnitude;
        block[j] = (int32_t)(magnitude * qmul[j] + 32) >> 6;
    }
}

int main(void)
{
    static uint8_t data[8192];
    H264DSPContext dsp = { 0 };
    AVLFG rng;
    ff_h264dsp_init(&dsp, 8, 1);
#if ARCH_X86_64 && HAVE_X86ASM
    if ((av_get_cpu_flags() & AV_CPU_FLAG_BMI2) && !dsp.decode_residual) {
        fprintf(stderr, "H.264 CABAC BMI2 dispatch was not installed\n");
        return 1;
    }
#endif
    if (!dsp.decode_residual) {
        fprintf(stderr, "Skipping optimized H.264 CABAC: unavailable on this CPU/build\n");
        return 0;
    }
    av_lfg_init(&rng, 0x48323634);
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
            if (get_cabac(&ref, sig0 + (max_coeff == 64 ? offsets[pos] : pos))) {
                index[count++] = pos;
                if (get_cabac(&ref, last0 + (max_coeff == 64 ? ff_h264_last_coeff_flag_offset_8x8[pos] : pos)))
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
    fprintf(stderr, "20000 optimized H.264 CABAC comparisons passed\n");
    return 0;
}
