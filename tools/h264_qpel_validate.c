/* SPDX-License-Identifier: LGPL-2.1-or-later */
/* Extra 8-bit H.264 qpel coverage for the AVX2 investigation.
 * See h264-optimization-notes.md for build instructions.
 */
#include <stdio.h>
#include <string.h>

#include "libavcodec/h264qpel.h"
#include "libavutil/cpu.h"
#include "libavutil/common.h"
#include "libavutil/mem_internal.h"

static DECLARE_ALIGNED(64, uint8_t, src)[32768];
static DECLARE_ALIGNED(64, uint8_t, ref_dst)[32768];
static DECLARE_ALIGNED(64, uint8_t, opt_dst)[32768];

int main(void)
{
    static const int strides[] = { 32, 48, 64, 96, 512 };
    static const int positions[] = { 1, 2, 3, 4, 5, 7, 8, 12, 13, 15 };
    H264QpelContext ref, opt;
    uint32_t rng = 123;
    unsigned count = 0;

    av_force_cpu_flags(0);
    ff_h264qpel_init(&ref, 8);
    av_force_cpu_flags(-1);
    ff_h264qpel_init(&opt, 8);
    for (int s = 0; s < FF_ARRAY_ELEMS(strides); s++) {
        int stride = strides[s];
        for (int offset = 0; offset < 16; offset++) {
            for (int pattern = 0; pattern < 8; pattern++) {
                for (int i = 0; i < sizeof(src); i++) {
                    rng = 1664525 * rng + 1013904223;
                    src[i] = pattern == 0 ? 0 : pattern == 1 ? 255 :
                             pattern == 2 ? (i & 1 ? 255 : 0) :
                             pattern == 3 ? ((i / stride) & 1 ? 255 : 0) : rng >> 24;
                }
                for (int avg = 0; avg < 2; avg++) {
                    for (int size = 0; size < 2; size++) {
                        for (int p = 0; p < FF_ARRAY_ELEMS(positions); p++) {
                            int pos = positions[p];
                            qpel_mc_func f = avg ? ref.avg_h264_qpel_pixels_tab[size][pos] :
                                                   ref.put_h264_qpel_pixels_tab[size][pos];
                            qpel_mc_func g = avg ? opt.avg_h264_qpel_pixels_tab[size][pos] :
                                                   opt.put_h264_qpel_pixels_tab[size][pos];
                            for (int i = 0; i < sizeof(ref_dst); i++) {
                                rng = 1664525 * rng + 1013904223;
                                ref_dst[i] = opt_dst[i] = rng >> 24;
                            }
                            f(ref_dst + 64, src + 3 * stride + offset, stride);
                            g(opt_dst + 64, src + 3 * stride + offset, stride);
                            if (memcmp(ref_dst, opt_dst, sizeof(ref_dst))) {
                                fprintf(stderr, "Mismatch: stride=%d offset=%d pattern=%d avg=%d width=%d pos=%d\n",
                                        stride, offset, pattern, avg, 16 >> size, pos);
                                return 1;
                            }
                            count++;
                        }
                    }
                }
            }
        }
    }
    printf("%u full-buffer qpel comparisons passed\n", count);
    return 0;
}
