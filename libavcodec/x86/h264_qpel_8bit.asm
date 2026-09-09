;*****************************************************************************
;* MMX/SSE2/SSSE3-optimized H.264 QPEL code
;*****************************************************************************
;* Copyright (c) 2004-2005 Michael Niedermayer, Loren Merritt
;* Copyright (C) 2012 Daniel Kang
;*
;* Authors: Daniel Kang <daniel.d.kang@gmail.com>
;*
;* This file is part of FFmpeg.
;*
;* FFmpeg is free software; you can redistribute it and/or
;* modify it under the terms of the GNU Lesser General Public
;* License as published by the Free Software Foundation; either
;* version 2.1 of the License, or (at your option) any later version.
;*
;* FFmpeg is distributed in the hope that it will be useful,
;* but WITHOUT ANY WARRANTY; without even the implied warranty of
;* MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;* Lesser General Public License for more details.
;*
;* You should have received a copy of the GNU Lesser General Public
;* License along with FFmpeg; if not, write to the Free Software
;* Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
;******************************************************************************

%include "libavutil/x86/x86util.asm"

cextern pw_16
cextern pw_5
cextern pb_0

SECTION_RODATA 32

qpel_h01: times 2 db 0,1,1,2,2,3,3,4,4,5,5,6,6,7,7,8
qpel_h23: times 2 db 2,3,3,4,4,5,5,6,6,7,7,8,8,9,9,10
qpel_h45: times 2 db 4,5,5,6,6,7,7,8,8,9,9,10,10,11,11,12
qpel_c01: times 16 db 1,-5
qpel_c23: times 32 db 20
qpel_c45: times 16 db -5,1

SECTION .text

%if ARCH_X86_64
; Each lane filters eight adjacent outputs. The two source loads cover the
; same 24-byte span as the existing pair of eight-pixel filters.
%macro QPEL16_H_AVX2 2
INIT_YMM avx2
cglobal %1_h264_qpel16_mc%{2}0, 3, 4, 10
    mov          r3d, 16
    vpbroadcastw m3, [pw_16]
    mova         m4, [qpel_h01]
    mova         m5, [qpel_h23]
    mova         m6, [qpel_h45]
    mova         m7, [qpel_c01]
    mova         m8, [qpel_c23]
    mova         m9, [qpel_c45]
.loop:
    movu         xm0, [r1-2]
    vinserti128  m0, m0, [r1+6], 1
    pshufb       m1, m0, m4
    pshufb       m2, m0, m5
    pmaddubsw    m1, m7
    pmaddubsw    m2, m8
    pshufb       m0, m6
    paddw        m1, m2
    pmaddubsw    m0, m9
    paddw        m1, m0
    paddw        m1, m3
    psraw        m1, 5
    vextracti128 xm2, m1, 1
    packuswb     xm1, xm2
%if %2 == 1
    pavgb        xm1, [r1]
%elif %2 == 3
    pavgb        xm1, [r1+1]
%endif
%ifidn %1, avg
    pavgb        xm1, [r0]
%endif
    movu         [r0], xm1
    add          r0, r2
    add          r1, r2
    dec          r3d
    jnz .loop
    RET
%endmacro

QPEL16_H_AVX2 put, 1
QPEL16_H_AVX2 put, 2
QPEL16_H_AVX2 put, 3
QPEL16_H_AVX2 avg, 1
QPEL16_H_AVX2 avg, 2
QPEL16_H_AVX2 avg, 3
%endif

; Full-width 8-bit vertical interpolation, with quarter-pel averaging fused.
; Six-tap filter: (a - 5*b + 20*c + 20*d - 5*e + f + 16) >> 5.
%if ARCH_X86_64
%macro QPEL16_V_AVX2 2
INIT_YMM avx2
cglobal %1_h264_qpel16_mc0%2, 3, 4, 11
    sub          r1, r2
    sub          r1, r2
%if %2 == 1
    lea          r3, [r2*3]
    neg          r3
%elif %2 == 3
    mov          r3, r2
    neg          r3
    add          r3, r3
%endif
    vpbroadcastw m9, [pw_5]
    vpbroadcastw m10, [pw_16]
%assign i 0
%rep 5
    pmovzxbw     m %+ i, [r1]
    add          r1, r2
%assign i i+1
%endrep
%rep 16
    pmovzxbw     m5, [r1]
    paddw        m6, m2, m3
    psllw        m6, 2
    psubw        m6, m1
    psubw        m6, m4
    pmullw       m6, m9
    paddw        m7, m0, m5
    paddw        m7, m10
    paddw        m6, m7
    psraw        m6, 5
    vextracti128 xm7, m6, 1
    packuswb     xm6, xm7
%if %2 != 2
    pavgb        xm6, [r1+r3]
%endif
%ifidn %1, avg
    pavgb        xm6, [r0]
%endif
    movu         [r0], xm6
    add          r0, r2
    add          r1, r2
    SWAP         0, 1, 2, 3, 4, 5
%endrep
    RET
%endmacro

QPEL16_V_AVX2 put, 1
QPEL16_V_AVX2 put, 2
QPEL16_V_AVX2 put, 3
QPEL16_V_AVX2 avg, 1
QPEL16_V_AVX2 avg, 2
QPEL16_V_AVX2 avg, 3
%endif

; Odd/odd quarter-pel positions average independently clipped horizontal
; and vertical half-pel samples. Fuse both filters and the two averages to
; avoid temporary blocks and repeated calls through the C wrappers.
%if ARCH_X86_64
%macro QPEL_HV_AVX2 4 ; operation, width, horizontal fraction, vertical fraction
%if %2 == 16
INIT_YMM avx2
%else
INIT_XMM avx2
%endif
cglobal %1_h264_qpel%2_mc%3%4, 3, 4, 16
    mov          r3, r1
%if %4 == 3
    add          r3, r2
%endif
%if %3 == 3
    inc          r1
%endif
    sub          r1, r2
    sub          r1, r2
    vpbroadcastw m11, [pw_16]
    vpbroadcastw m12, [pw_5]
    mova         m13, [qpel_c01]
    mova         m14, [qpel_c23]
    mova         m15, [qpel_c45]
%assign i 0
%rep 5
    pmovzxbw     m %+ i, [r1]
    add          r1, r2
%assign i i+1
%endrep
%rep %2
    pmovzxbw     m5, [r1]
    paddw        m6, m2, m3
    psllw        m6, 2
    psubw        m6, m1
    psubw        m6, m4
    pmullw       m6, m12
    paddw        m7, m0, m5
    paddw        m7, m11
    paddw        m6, m7
    psraw        m6, 5
%if %2 == 16
    vextracti128 xm7, m6, 1
    packuswb     xm6, xm7
%else
    packuswb     m6, m6
%endif
    movu         xm8, [r3-2]
%if %2 == 16
    vinserti128  m8, m8, [r3+6], 1
%endif
    pshufb       m9, m8, [qpel_h01]
    pshufb       m10, m8, [qpel_h23]
    pmaddubsw    m9, m13
    pmaddubsw    m10, m14
    pshufb       m8, [qpel_h45]
    paddw        m9, m10
    pmaddubsw    m8, m15
    paddw        m9, m8
    paddw        m9, m11
    psraw        m9, 5
%if %2 == 16
    vextracti128 xm10, m9, 1
    packuswb     xm9, xm10
%else
    packuswb     m9, m9
%endif
    pavgb        xm6, xm9
%ifidn %1, avg
%if %2 == 16
    pavgb        xm6, [r0]
%else
    movq         xm7, [r0]
    pavgb        xm6, xm7
%endif
%endif
%if %2 == 16
    movu         [r0], xm6
%else
    movq         [r0], xm6
%endif
    add          r0, r2
    add          r1, r2
    add          r3, r2
    SWAP         0, 1, 2, 3, 4, 5
%endrep
    RET
%endmacro

%macro QPEL_HV_AVX2_SET 2
QPEL_HV_AVX2 %1, %2, 1, 1
QPEL_HV_AVX2 %1, %2, 3, 1
QPEL_HV_AVX2 %1, %2, 1, 3
QPEL_HV_AVX2 %1, %2, 3, 3
%endmacro
QPEL_HV_AVX2_SET put, 16
QPEL_HV_AVX2_SET avg, 16
QPEL_HV_AVX2_SET put, 8
QPEL_HV_AVX2_SET avg, 8
%endif

; void ff_avg_pixels4_mmxext(uint8_t *block, const uint8_t *pixels,
;                            ptrdiff_t line_size)
INIT_MMX mmxext
cglobal avg_pixels4, 3,4
    lea          r3, [r2*3]
    movh         m0, [r1]
    movh         m1, [r1+r2]
    movh         m2, [r1+r2*2]
    movh         m3, [r1+r3]
    pavgb        m0, [r0]
    pavgb        m1, [r0+r2]
    pavgb        m2, [r0+r2*2]
    pavgb        m3, [r0+r3]
    movh       [r0], m0
    movh    [r0+r2], m1
    movh  [r0+r2*2], m2
    movh    [r0+r3], m3
    RET

%macro op_avgh 3
    movh   %3, %2
    pavgb  %1, %3
    movh   %2, %1
%endmacro

%macro op_avg 2-3
    pavgb  %1, %2
    mova   %2, %1
%endmacro

%macro op_puth 2-3
    movh   %2, %1
%endmacro

%macro op_put 2-3
    mova   %2, %1
%endmacro

; void ff_put/avg_pixels4x4_l2_mmxext(uint8_t *dst, const uint8_t *src1, const uint8_t *src2,
;                                     ptrdiff_t stride)
%macro PIXELS4_L2 1
%define OP op_%1h
cglobal %1_pixels4x4_l2, 4,4
    mova         m0, [r1]
    mova         m1, [r1+r3]
    lea          r1, [r1+2*r3]
    pavgb        m0, [r2]
    pavgb        m1, [r2+4]
    OP           m0, [r0], m3
    OP           m1, [r0+r3], m3
    lea          r0, [r0+2*r3]
    mova         m0, [r1]
    mova         m1, [r1+r3]
    pavgb        m0, [r2+8]
    pavgb        m1, [r2+12]
    OP           m0, [r0], m3
    OP           m1, [r0+r3], m3
    RET
%endmacro

INIT_MMX mmxext
PIXELS4_L2 put
PIXELS4_L2 avg

%macro QPEL4_H_LOWPASS_OP 1
cglobal %1_h264_qpel4_h_lowpass, 4,5 ; dst, src, dstStride, srcStride
    pxor          m7, m7
    mova          m4, [pw_5]
    mova          m5, [pw_16]
    mov          r4d, 4
.loop:
    movh          m1, [r1-1]
    movh          m2, [r1+0]
    movh          m3, [r1+1]
    movh          m0, [r1+2]
    punpcklbw     m1, m7
    punpcklbw     m2, m7
    punpcklbw     m3, m7
    punpcklbw     m0, m7
    paddw         m1, m0
    paddw         m2, m3
    movh          m0, [r1-2]
    movh          m3, [r1+3]
    punpcklbw     m0, m7
    punpcklbw     m3, m7
    paddw         m0, m3
    psllw         m2, 2
    psubw         m2, m1
    pmullw        m2, m4
    paddw         m0, m5
    paddw         m0, m2
    psraw         m0, 5
    packuswb      m0, m0
    op_%1h        m0, [r0], m6
    add           r0, r2
    add           r1, r3
    dec          r4d
    jg         .loop
    RET
%endmacro

INIT_MMX mmxext
QPEL4_H_LOWPASS_OP put
QPEL4_H_LOWPASS_OP avg

%macro QPEL8_H_LOWPASS_OP_XMM 1
cglobal %1_h264_qpel8_h_lowpass, 4,5,8 ; dst, src, dstStride, srcStride
    mov          r4d, 8
    pxor          m7, m7
    mova          m6, [pw_5]
.loop:
    movu          m1, [r1-2]
    mova          m0, m1
    punpckhbw     m1, m7
    punpcklbw     m0, m7
    mova          m2, m1
    mova          m3, m1
    mova          m4, m1
    mova          m5, m1
    palignr       m4, m0, 2
    palignr       m3, m0, 4
    palignr       m2, m0, 6
    palignr       m1, m0, 8
    palignr       m5, m0, 10
    paddw         m0, m5
    paddw         m2, m3
    paddw         m1, m4
    psllw         m2, 2
    psubw         m2, m1
    paddw         m0, [pw_16]
    pmullw        m2, m6
    paddw         m2, m0
    psraw         m2, 5
    packuswb      m2, m2
    op_%1h        m2, [r0], m4
    add           r1, r3
    add           r0, r2
    dec          r4d
    jne        .loop
    RET
%endmacro

INIT_XMM ssse3
QPEL8_H_LOWPASS_OP_XMM put
QPEL8_H_LOWPASS_OP_XMM avg


%macro QPEL4_H_LOWPASS_L2_OP 1
cglobal %1_h264_qpel4_h_lowpass_l2, 5,6 ; dst, src, src2, dstStride, srcStride
    pxor          m7, m7
    mova          m4, [pw_5]
    mova          m5, [pw_16]
    mov          r5d, 4
.loop:
    movh          m1, [r1-1]
    movh          m2, [r1+0]
    movh          m3, [r1+1]
    movh          m0, [r1+2]
    punpcklbw     m1, m7
    punpcklbw     m2, m7
    punpcklbw     m3, m7
    punpcklbw     m0, m7
    paddw         m1, m0
    paddw         m2, m3
    movh          m0, [r1-2]
    movh          m3, [r1+3]
    punpcklbw     m0, m7
    punpcklbw     m3, m7
    paddw         m0, m3
    psllw         m2, 2
    psubw         m2, m1
    pmullw        m2, m4
    paddw         m0, m5
    paddw         m0, m2
    movh          m3, [r2]
    psraw         m0, 5
    packuswb      m0, m0
    pavgb         m0, m3
    op_%1h        m0, [r0], m6
    add           r0, r3
    add           r1, r3
    add           r2, r4
    dec          r5d
    jg         .loop
    RET
%endmacro

INIT_MMX mmxext
QPEL4_H_LOWPASS_L2_OP put
QPEL4_H_LOWPASS_L2_OP avg


%macro QPEL8_H_LOWPASS_L2_OP 1
cglobal %1_h264_qpel8_h_lowpass_l2, 5,6,6 ; dst, src, src2, dstStride, srcStride
    mova          m3, [pw_16]
    mov          r5d, 8
    pxor          m5, m5
    mova          m4, [pw_5]
.loop:
    movh          m0, [r1]
    movh          m1, [r1+1]
    punpcklbw     m0, m5
    punpcklbw     m1, m5
    paddw         m0, m1
    psllw         m0, 2
    movh          m1, [r1-1]
    movh          m2, [r1+2]
    punpcklbw     m1, m5
    punpcklbw     m2, m5
    paddw         m1, m2
    psubw         m0, m1
    pmullw        m0, m4
    movh          m1, [r1-2]
    movh          m2, [r1+3]
    punpcklbw     m1, m5
    punpcklbw     m2, m5
    paddw         m0, m1
    paddw         m0, m2
    paddw         m0, m3
    psraw         m0, 5
    packuswb      m0, m5
    movh          m2, [r2]
    pavgb         m0, m2
    op_%1h        m0, [r0], m2
    add           r0, r3
    add           r1, r3
    add           r2, r4
    dec          r5d
    jg         .loop
    RET
%endmacro

INIT_XMM sse2
QPEL8_H_LOWPASS_L2_OP put
QPEL8_H_LOWPASS_L2_OP avg


%macro QPEL16_H_LOWPASS_L2 1
%if ARCH_X86_64
cglobal %1_h264_qpel16_h_lowpass_l2, 5,6,9 ; dst, src, src2, dstStride, srcStride
    mova          m8, [pw_16]
%define PW_16 m8
%else
cglobal %1_h264_qpel16_h_lowpass_l2, 5,6,8 ; dst, src, src2, dstStride, srcStride
%define PW_16 [pw_16]
%endif
    mov          r5d, 16
    pxor          m7, m7
    mova          m6, [pw_5]
.loop:
    movu          m0, [r1]
    movu          m2, [r1+1]
    mova          m1, m0
    mova          m3, m2
    punpcklbw     m0, m7
    punpcklbw     m2, m7
    punpckhbw     m1, m7
    punpckhbw     m3, m7
    paddw         m0, m2
    paddw         m1, m3
    psllw         m0, 2
    psllw         m1, 2
    movu          m2, [r1-1]
    movu          m4, [r1+2]
    mova          m3, m2
    mova          m5, m4
    punpcklbw     m2, m7
    punpcklbw     m4, m7
    punpckhbw     m3, m7
    punpckhbw     m5, m7
    paddw         m2, m4
    paddw         m3, m5
    psubw         m0, m2
    psubw         m1, m3
    pmullw        m0, m6
    pmullw        m1, m6
    movu          m2, [r1-2]
    movu          m4, [r1+3]
    mova          m3, m2
    mova          m5, m4
    punpcklbw     m2, m7
    punpcklbw     m4, m7
    punpckhbw     m3, m7
    punpckhbw     m5, m7
    paddw         m2, m4
    paddw         m3, m5
    paddw         m0, m2
    paddw         m1, m3
    paddw         m0, PW_16
    paddw         m1, PW_16
    psraw         m0, 5
    psraw         m1, 5
    packuswb      m0, m1
    movu          m4, [r2]
    pavgb         m0, m4
    op_%1         m0, [r0], m4
    add           r0, r3
    add           r1, r3
    add           r2, r4
    dec          r5d
    jg         .loop
    RET
%endmacro

INIT_XMM sse2
QPEL16_H_LOWPASS_L2 put
QPEL16_H_LOWPASS_L2 avg


%macro QPEL8_H_LOWPASS_L2_OP_XMM 1
cglobal %1_h264_qpel8_h_lowpass_l2, 5,6,8 ; dst, src, src2, dstStride, src2Stride
    mov          r5d, 8
    pxor          m7, m7
    mova          m6, [pw_5]
.loop:
    lddqu         m1, [r1-2]
    mova          m0, m1
    punpckhbw     m1, m7
    punpcklbw     m0, m7
    mova          m2, m1
    mova          m3, m1
    mova          m4, m1
    mova          m5, m1
    palignr       m4, m0, 2
    palignr       m3, m0, 4
    palignr       m2, m0, 6
    palignr       m1, m0, 8
    palignr       m5, m0, 10
    paddw         m0, m5
    paddw         m2, m3
    paddw         m1, m4
    psllw         m2, 2
    movh          m3, [r2]
    psubw         m2, m1
    paddw         m0, [pw_16]
    pmullw        m2, m6
    paddw         m2, m0
    psraw         m2, 5
    packuswb      m2, m2
    pavgb         m2, m3
    op_%1h        m2, [r0], m4
    add           r1, r3
    add           r0, r3
    add           r2, r4
    dec          r5d
    jg         .loop
    RET
%endmacro

INIT_XMM ssse3
QPEL8_H_LOWPASS_L2_OP_XMM put
QPEL8_H_LOWPASS_L2_OP_XMM avg


; All functions that call this are required to have function arguments of
; dst, src, dstStride, srcStride
%macro FILT_V 1-2
%ifnidn %2, last
    mova      m6, m2
%else
    SWAP       6, 2
%endif
    movh      m5, [r1]
    paddw     m6, m3
    psllw     m6, 2
    psubw     m6, m1
    psubw     m6, m4
    punpcklbw m5, m7
    pmullw    m6, [pw_5]
    paddw     m0, [pw_16]
    add       r1, r3
    paddw     m0, m5
    paddw     m6, m0
    psraw     m6, 5
    packuswb  m6, m6
    op_%1h    m6, [r0], m0 ; 1
%ifnidn %2, last
    add       r0, r2
%endif
    SWAP       0, 1, 2, 3, 4, 5
%endmacro

%macro QPEL4_V_LOWPASS_OP 1
cglobal %1_h264_qpel4_v_lowpass, 4,4 ; dst, src, dstStride, srcStride
    sub           r1, r3
    sub           r1, r3
    pxor          m7, m7
    movh          m0, [r1]
    movh          m1, [r1+r3]
    lea           r1, [r1+2*r3]
    movh          m2, [r1]
    movh          m3, [r1+r3]
    lea           r1, [r1+2*r3]
    movh          m4, [r1]
    add           r1, r3
    punpcklbw     m0, m7
    punpcklbw     m1, m7
    punpcklbw     m2, m7
    punpcklbw     m3, m7
    punpcklbw     m4, m7
    FILT_V        %1
    FILT_V        %1
    FILT_V        %1
    FILT_V        %1, last
    RET
%endmacro

INIT_MMX mmxext
QPEL4_V_LOWPASS_OP put
QPEL4_V_LOWPASS_OP avg



%macro QPEL8OR16_V_LOWPASS_OP 1
cglobal %1_h264_qpel8or16_v_lowpass, 5,5,8 ; dst, src, dstStride, srcStride, h
    sub           r1, r3
    sub           r1, r3
    pxor          m7, m7
    movh          m0, [r1]
    movh          m1, [r1+r3]
    lea           r1, [r1+2*r3]
    movh          m2, [r1]
    movh          m3, [r1+r3]
    lea           r1, [r1+2*r3]
    movh          m4, [r1]
    add           r1, r3
    punpcklbw     m0, m7
    punpcklbw     m1, m7
    punpcklbw     m2, m7
    punpcklbw     m3, m7
    punpcklbw     m4, m7
    FILT_V        %1
    FILT_V        %1
    FILT_V        %1
    FILT_V        %1
    FILT_V        %1
    FILT_V        %1
    FILT_V        %1
    FILT_V        %1
    cmp          r4d, 16
    jne         .end
    FILT_V        %1
    FILT_V        %1
    FILT_V        %1
    FILT_V        %1
    FILT_V        %1
    FILT_V        %1
    FILT_V        %1
    FILT_V        %1, last
.end:
    RET
%endmacro

INIT_XMM sse2
QPEL8OR16_V_LOWPASS_OP put
QPEL8OR16_V_LOWPASS_OP avg


; All functions that use this are required to have args:
; src, tmp, srcSize
%macro FILT_HV 1-2 ; offset, last
%ifnidn %2, last
    mova           m6, m2
%else
    SWAP            2, 6
%endif
    movh           m5, [r0]
    paddw          m6, m3
    psllw          m6, 2
    paddw          m0, [pw_16]
    psubw          m6, m1
    psubw          m6, m4
    punpcklbw      m5, m7
    pmullw         m6, [pw_5]
    paddw          m0, m5
%ifnidn %2, last
    add            r0, r2
%endif
    paddw          m6, m0
    mova      [r1+%1], m6
    SWAP            0, 1, 2, 3, 4, 5
%endmacro

INIT_MMX mmxext
cglobal put_h264_qpel4_hv_lowpass_v, 3,5 ; src, tmp, srcStride
    mov          r4d, 3
    mov           r3, r0
    pxor          m7, m7
.loop:
    movh          m0, [r0]
    movh          m1, [r0+r2]
    lea           r0, [r0+2*r2]
    movh          m2, [r0]
    movh          m3, [r0+r2]
    lea           r0, [r0+2*r2]
    movh          m4, [r0]
    add           r0, r2
    punpcklbw     m0, m7
    punpcklbw     m1, m7
    punpcklbw     m2, m7
    punpcklbw     m3, m7
    punpcklbw     m4, m7
    FILT_HV       0*24
    FILT_HV       1*24
    FILT_HV       2*24
    FILT_HV       3*24, last
    add           r3, 4
    add           r1, 8
    mov           r0, r3
    dec          r4d
    jnz        .loop
    RET

%macro QPEL4_HV1_LOWPASS_OP 1
cglobal %1_h264_qpel4_hv_lowpass_h, 3,4 ; tmp, dst, dstStride
    mov          r3d, 4
.loop:
    mova          m0, [r0]
    paddw         m0, [r0+10]
    mova          m1, [r0+2]
    paddw         m1, [r0+8]
    mova          m2, [r0+4]
    paddw         m2, [r0+6]
    psubw         m0, m1
    psraw         m0, 2
    psubw         m0, m1
    paddsw        m0, m2
    psraw         m0, 2
    paddw         m0, m2
    psraw         m0, 6
    packuswb      m0, m0
    op_%1h        m0, [r1], m7
    add           r0, 24
    add           r1, r2
    dec          r3d
    jnz        .loop
    RET
%endmacro

INIT_MMX mmxext
QPEL4_HV1_LOWPASS_OP put
QPEL4_HV1_LOWPASS_OP avg

INIT_XMM sse2
cglobal put_h264_qpel8or16_hv1_lowpass_op, 4,4,8 ; src, tmp, srcStride, size
    pxor          m7, m7
    movh          m0, [r0]
    movh          m1, [r0+r2]
    lea           r0, [r0+2*r2]
    movh          m2, [r0]
    movh          m3, [r0+r2]
    lea           r0, [r0+2*r2]
    movh          m4, [r0]
    add           r0, r2
    punpcklbw     m0, m7
    punpcklbw     m1, m7
    punpcklbw     m2, m7
    punpcklbw     m3, m7
    punpcklbw     m4, m7
    FILT_HV     0*48
    FILT_HV     1*48
    FILT_HV     2*48
    FILT_HV     3*48
    FILT_HV     4*48
    FILT_HV     5*48
    FILT_HV     6*48
    FILT_HV     7*48
    cmp          r3d, 16
    jne         .end
    FILT_HV     8*48
    FILT_HV     9*48
    FILT_HV    10*48
    FILT_HV    11*48
    FILT_HV    12*48
    FILT_HV    13*48
    FILT_HV    14*48
    FILT_HV    15*48, last
.end:
    RET

%macro HV2_LOWPASS 2
    mova          %1, [r1+%2]
    movu          m1, [r1+2+%2]
    movu          m3, [r1+10+%2]
    movu          m4, [r1+8+%2]
    movu          m2, [r1+4+%2]
    paddw         %1, m3
    movu          m3, [r1+6+%2]
    paddw         m1, m4
    psubw         %1, m1
    psraw         %1, 2
    paddw         m2, m3
    psubw         %1, m1
    paddsw        %1, m2
    psraw         %1, 2
    paddw         %1, m2
    psraw         %1, 6
%endmacro

%macro QPEL8AND16_HV2_LOWPASS_OP 1
cglobal %1_h264_qpel8_hv2_lowpass, 3,4,6 ; dst, tmp, dstStride
    mov          r3d, 8
.loop:
    HV2_LOWPASS   m0, 0
    packuswb      m0, m0
    op_%1h        m0, [r0], m3
    add           r1, 48
    add           r0, r2
    dec          r3d
    jne        .loop
    RET

cglobal %1_h264_qpel16_hv2_lowpass, 3,4,6 ; dst, tmp, dstStride
    mov          r3d, 16
.loop:
    HV2_LOWPASS   m0, 0
    HV2_LOWPASS   m5, 16
    packuswb      m0, m5
    op_%1         m0, [r0], m3
    add           r1, 48
    add           r0, r2
    dec          r3d
    jne        .loop
    RET
%endmacro

INIT_XMM sse2
QPEL8AND16_HV2_LOWPASS_OP put
QPEL8AND16_HV2_LOWPASS_OP avg

%macro QPEL8OR16_HV2_LOWPASS_OP_XMM 1
cglobal %1_h264_qpel8_hv2_lowpass, 3,4,6 ; dst, tmp, dstStride
    mov          r3d, 8
.loop:
    mova          m1, [r1+16]
    mova          m0, [r1]
    mova          m2, m1
    mova          m3, m1
    mova          m4, m1
    mova          m5, m1
    palignr       m5, m0, 10
    palignr       m4, m0, 8
    palignr       m3, m0, 6
    palignr       m2, m0, 4
    palignr       m1, m0, 2
    paddw         m0, m5
    paddw         m1, m4
    paddw         m2, m3
    psubw         m0, m1
    psraw         m0, 2
    psubw         m0, m1
    paddw         m0, m2
    psraw         m0, 2
    paddw         m0, m2
    psraw         m0, 6
    packuswb      m0, m0
    op_%1h        m0, [r0], m5
    add           r1, 48
    add           r0, r2
    dec          r3d
    jne        .loop
    RET

cglobal %1_h264_qpel16_hv2_lowpass, 3,4,8 ; dst, tmp, dstStride
    mov          r3d, 16
.loop:
    mova          m4, [r1+32]
    mova          m5, [r1+16]
    mova          m7, [r1]
    mova          m3, m4
    mova          m2, m4
    mova          m1, m4
    mova          m0, m4
    palignr       m0, m5, 10
    palignr       m1, m5, 8
    palignr       m2, m5, 6
    palignr       m3, m5, 4
    palignr       m4, m5, 2
    paddw         m0, m5
    paddw         m1, m4
    paddw         m2, m3
    mova          m6, m5
    mova          m4, m5
    mova          m3, m5
    palignr       m4, m7, 8
    palignr       m6, m7, 2
    palignr       m3, m7, 10
    paddw         m4, m6
    mova          m6, m5
    palignr       m5, m7, 6
    palignr       m6, m7, 4
    paddw         m3, m7
    paddw         m5, m6
    psubw         m0, m1
    psubw         m3, m4
    psraw         m0, 2
    psraw         m3, 2
    psubw         m0, m1
    psubw         m3, m4
    paddw         m0, m2
    paddw         m3, m5
    psraw         m0, 2
    psraw         m3, 2
    paddw         m0, m2
    paddw         m3, m5
    psraw         m0, 6
    psraw         m3, 6
    packuswb      m3, m0
    op_%1         m3, [r0], m7
    add           r1, 48
    add           r0, r2
    dec          r3d
    jne        .loop
    RET
%endmacro

INIT_XMM ssse3
QPEL8OR16_HV2_LOWPASS_OP_XMM put
QPEL8OR16_HV2_LOWPASS_OP_XMM avg


%macro PIXELS4_L2_SHIFT5 1
cglobal %1_pixels4_l2_shift5,4,4 ; dst, src16, src8, dstStride
    mova          m0, [r1]
    mova          m1, [r1+24]
    psraw         m0, 5
    psraw         m1, 5
    packuswb      m0, m0
    packuswb      m1, m1
    pavgb         m0, [r2]
    pavgb         m1, [r2+4]
    op_%1h        m0, [r0], m4
    op_%1h        m1, [r0+r3], m5
    lea           r0, [r0+r3*2]
    mova          m0, [r1+48]
    mova          m1, [r1+72]
    psraw         m0, 5
    psraw         m1, 5
    packuswb      m0, m0
    packuswb      m1, m1
    pavgb         m0, [r2+2*4]
    pavgb         m1, [r2+3*4]
    op_%1h        m0, [r0], m4
    op_%1h        m1, [r0+r3], m5
    RET
%endmacro

INIT_MMX mmxext
PIXELS4_L2_SHIFT5 put
PIXELS4_L2_SHIFT5 avg

%macro PIXELS8_L2_SHIFT5 1
cglobal %1_pixels8_l2_shift5, 5, 5, 3 ; dst, src16, src8, dstStride
    mov          r4d, 8
.loop:
    movu          m0, [r1]
    movu          m1, [r1+48]
    psraw         m0, 5
    psraw         m1, 5
    packuswb      m0, m1
    pavgb         m0, [r2]
    pshufd        m1, m0, 0xee ; low half of m1 is high half of m0
    op_%1h        m0, [r0], m2
    op_%1h        m1, [r0+r3], m2
    add           r1, 48*2
    add           r2, 8*2
    lea           r0, [r0+2*r3]
    sub          r4d, 2
    jne        .loop
    RET
%endmacro

%macro PIXELS16_L2_SHIFT5 2
cglobal %1_pixels%2_l2_shift5, 5, 5, 4 ; dst, src16, src8, dstStride
    mov          r4d, %2
.loop:
    movu          m0, [r1]
    movu          m1, [r1+%2]
    movu          m2, [r1+48]
    movu          m3, [r1+48+%2]
    psraw         m0, 5
    psraw         m1, 5
    psraw         m2, 5
    psraw         m3, 5
    packuswb      m0, m1
    packuswb      m2, m3
    pavgb         m0, [r2]
    pavgb         m2, [r2+%2]
    op_%1         m0, [r0], m1
    op_%1         m2, [r0+r3], m1
    lea           r2, [r2+2*%2]
    add           r1, 48*2
    lea           r0, [r0+2*r3]
    sub          r4d, 2
    jne        .loop
    RET
%endmacro

INIT_XMM sse2
PIXELS8_L2_SHIFT5 put
PIXELS8_L2_SHIFT5 avg

PIXELS16_L2_SHIFT5 put, 16
PIXELS16_L2_SHIFT5 avg, 16

%if ARCH_X86_64
%macro QPEL16_H_LOWPASS_L2_OP 1
cglobal %1_h264_qpel16_h_lowpass_l2, 5, 6, 16 ; dst, src, src2, dstStride, src2Stride
    mov          r5d, 16
    pxor         m15, m15
    mova         m14, [pw_5]
    mova         m13, [pw_16]
.loop:
    lddqu         m1, [r1+6]
    lddqu         m7, [r1-2]
    mova          m0, m1
    punpckhbw     m1, m15
    punpcklbw     m0, m15
    punpcklbw     m7, m15
    mova          m2, m1
    mova          m6, m0
    mova          m3, m1
    mova          m8, m0
    mova          m4, m1
    mova          m9, m0
    mova         m12, m0
    mova         m11, m1
    palignr      m11, m0, 10
    palignr      m12, m7, 10
    palignr       m4, m0, 2
    palignr       m9, m7, 2
    palignr       m3, m0, 4
    palignr       m8, m7, 4
    palignr       m2, m0, 6
    palignr       m6, m7, 6
    paddw        m11, m0
    palignr       m1, m0, 8
    palignr       m0, m7, 8
    paddw         m7, m12
    paddw         m2, m3
    paddw         m6, m8
    paddw         m1, m4
    paddw         m0, m9
    psllw         m2, 2
    psllw         m6, 2
    psubw         m2, m1
    psubw         m6, m0
    paddw        m11, m13
    paddw         m7, m13
    pmullw        m2, m14
    pmullw        m6, m14
    lddqu         m3, [r2]
    paddw         m2, m11
    paddw         m6, m7
    psraw         m2, 5
    psraw         m6, 5
    packuswb      m6, m2
    pavgb         m6, m3
    op_%1         m6, [r0], m11
    add           r1, r3
    add           r0, r3
    add           r2, r4
    dec          r5d
    jg         .loop
    RET
%endmacro

INIT_XMM ssse3
QPEL16_H_LOWPASS_L2_OP put
QPEL16_H_LOWPASS_L2_OP avg
%endif
