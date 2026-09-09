; SPDX-License-Identifier: LGPL-2.1-or-later
; Decode non-DC residual values with CABAC state live across the entire block.

%include "libavutil/x86/x86util.asm"

SECTION .text
cextern h264_cabac_tables

%if ARCH_X86_64

; Live state: r0d=low, r5d=range, r7=bytestream, r8=tables.
; r6 plus the macro argument (default r13) addresses the probability state. r9 returns the decoded bit in bit 0.
; Clobbers r9-r11. H.264's caller provides padded, unchecked CABAC input.
%macro RESIDUAL_GET_CABAC 0-1 r13
    movzx       r9d, byte [r6+%1]
    mov         r10d, r5d
    and         r5d, 0xc0
    lea         r11d, [r9+r5*2]
    movzx       r5d, byte [r8+r11+512]
    sub         r10d, r5d
    mov         r11d, r10d
    shl         r10d, 17
    cmp         r10d, r0d
    cmova       r5d, r11d
    sbb         r11, r11
    and         r10d, r11d
    xor         r9, r11
    sub         r0d, r10d
    movzx       r11d, byte [r8+r5]
    shlx        r5d, r5d, r11d
    shlx        r0d, r0d, r11d
    movzx       r10d, byte [r8+r9+1152]
    mov         [r6+%1], r10b
    test        r0w, r0w
    jnz         %%done
    movzx       r10d, word [r7]
    add         r7, 2
    bswap       r10d
    shr         r10d, 15
    sub         r10d, 65535
    bsf         r11d, r0d
    sub         r11d, 16
    shlx        r10d, r10d, r11d
    add         r0d, r10d
%%done:
%endmacro

; Return a bypass bit in r9d, clobbering r10d.
%macro RESIDUAL_GET_BYPASS 0
    add         r0d, r0d
    test        r0w, r0w
    jnz         %%full
    movzx       r10d, word [r7]
    add         r7, 2
    bswap       r10d
    shr         r10d, 15
    sub         r0d, 65535
    add         r0d, r10d
%%full:
    mov         r10d, r5d
    shl         r10d, 17
    sub         r0d, r10d
    sbb         r9d, r9d
    and         r10d, r9d
    add         r0d, r10d
    inc         r9d
%endmacro

INIT_XMM bmi2
; CABACContext*, block, scan, qmul, significant state, last state,
; absolute-level state, maximum coefficient count, 8x8 significance offsets.
cglobal h264_decode_residual_8, 9, 15, 0, 320
    mov         [rsp], r0
    mov         [rsp+8], r6
    mov         [rsp+16], r4
    mov         [rsp+24], r5
    mov         [rsp+32], r8
    mov         r14d, r7d
    dec         r14d
    lea         r4, [rsp+64]
    mov         [rsp+40], r4
    mov         r6, [rsp+16]
    mov         r5d, [r0+4]
    mov         r7, [r0+16]
    mov         r0d, [r0]
    lea         r8, [h264_cabac_tables]
    xor         r12d, r12d
    cmp         r14d, 63
    je          .significance8
    test        r14d, r14d
    jz          .implicit_last
.significance4:
    mov         r13d, r12d
    RESIDUAL_GET_CABAC
    test        r9d, 1
    jz          .next4
    mov         r6, [rsp+24]
    RESIDUAL_GET_CABAC
    mov         [r4], r12d
    add         r4, 4
    mov         r6, [rsp+16]
    test        r9d, 1
    jnz         .significance_done
.next4:
    inc         r12d
    cmp         r12d, r14d
    jb          .significance4
    jmp         .implicit_last
.significance8:
    mov         r13, [rsp+32]
    movzx       r13d, byte [r13+r12]
    RESIDUAL_GET_CABAC
    test        r9d, 1
    jz          .next8
    movzx       r13d, byte [r8+r12+1280]
    mov         r6, [rsp+24]
    RESIDUAL_GET_CABAC
    mov         [r4], r12d
    add         r4, 4
    mov         r6, [rsp+16]
    test        r9d, 1
    jnz         .significance_done
.next8:
    inc         r12d
    cmp         r12d, 63
    jb          .significance8
.implicit_last:
    mov         [r4], r12d
    add         r4, 4
.significance_done:
    mov         r10, r4
    sub         r10, [rsp+40]
    shr         r10d, 2
    mov         [rsp+48], r10d
    mov         r6, [rsp+8]
    xor         r12d, r12d
.coefficient:
    sub         r4, 4
    ; ctx(level == 1): node < 4 ? node + 1 : 0.
    lea         r13d, [r12+1]
    xor         r10d, r10d
    cmp         r12d, 4
    cmovae      r13d, r10d
    RESIDUAL_GET_CABAC
    mov         r14d, 1
    test        r9d, 1
    jnz         .greater_one
    ; Level-one nodes saturate at 3; nodes 4..7 remain unchanged.
    cmp         r12d, 3
    adc         r12d, 0
    jmp         .sign
.greater_one:
    ; ctx(level > 1): node < 4 ? 5 : node + 2.
    lea         r13d, [r12+2]
    mov         r10d, 5
    cmp         r12d, 4
    cmovb       r13d, r10d
    ; Transition to node 4, or increment with saturation at 7.
    lea         r10d, [r12+1]
    mov         r11d, 4
    cmovb       r10d, r11d
    cmp         r12d, 7
    cmovb       r12d, r10d
    mov         r14d, 2
.unary:
    RESIDUAL_GET_CABAC
    test        r9d, 1
    jz          .sign
    inc         r14d
    cmp         r14d, 15
    jb          .unary
    xor         r13d, r13d
.prefix:
    RESIDUAL_GET_BYPASS
    test        r9d, r9d
    jz          .suffix_start
    cmp         r13d, 23
    jae         .suffix_start
    inc         r13d
    jmp         .prefix
.suffix_start:
    mov         r14d, 1
    test        r13d, r13d
    jz          .suffix_done
.suffix:
    RESIDUAL_GET_BYPASS
    lea         r14d, [r14*2+r9]
    dec         r13d
    jnz         .suffix
.suffix_done:
    add         r14d, 14
.sign:
    RESIDUAL_GET_BYPASS
    neg         r9d
    xor         r14d, r9d
    sub         r14d, r9d
    mov         r13d, [r4]
    movzx       r13d, byte [r2+r13]
    imul        r14d, [r3+r13*4]
    add         r14d, 32
    sar         r14d, 6
    mov         [r1+r13*2], r14w
    cmp         r4, [rsp+40]
    jne         .coefficient
    mov         r4, [rsp]
    mov         [r4], r0d
    mov         [r4+4], r5d
    mov         [r4+16], r7
    mov         eax, [rsp+48]
    RET

; Decode horizontal and vertical MVDs while keeping CABAC state live.
; Arguments: CABACContext*, states at offset 40, amvd_x, amvd_y, out[4].
; Output is { mvd_x, mvd_y, abs_x_clipped_to_70, abs_y_clipped_to_70 }.
%macro MVD_COMPONENT 1
    cmp         r2d, 3
    sbb         r4d, r4d
    cmp         r2d, 33
    sbb         r4d, -2
    RESIDUAL_GET_CABAC r4
    xor         r2d, r2d
    xor         r11d, r11d
    test        r9d, 1
    jz          %%store
    inc         r2d
    mov         r4d, 3
%%unary:
    RESIDUAL_GET_CABAC r4
    test        r9d, 1
    jz          %%sign
    cmp         r2d, 4
    adc         r4d, 0
    inc         r2d
    cmp         r2d, 9
    jb          %%unary
    mov         r4d, 3
%%prefix:
    RESIDUAL_GET_BYPASS
    test        r9d, r9d
    jz          %%suffix
    mov         r11d, 1
    shlx        r11d, r11d, r4d
    add         r2d, r11d
    inc         r4d
    cmp         r4d, 24
    jbe         %%prefix
    mov         r2d, 0x80000000
    mov         dword [rsp+8], 1
    jmp         %%store_mvd
%%suffix:
    dec         r4d
    js          %%sign
    RESIDUAL_GET_BYPASS
    shlx        r9d, r9d, r4d
    add         r2d, r9d
    jmp         %%suffix
%%sign:
    mov         r11d, 70
    cmp         r2d, r11d
    cmovb       r11d, r2d
    RESIDUAL_GET_BYPASS
    neg         r9d
    xor         r2d, r9d
    sub         r2d, r9d
%%store:
    mov         [r3+%1+8], r11d
%%store_mvd:
    mov         [r3+%1], r2d
%endmacro

INIT_XMM bmi2
cglobal h264_decode_mvd_pair, 5, 12, 0, 16
    mov         [rsp], r3d
    mov         dword [rsp+8], 0
    mov         r6, r1
    mov         r1, r0
    mov         r3, r4
    mov         r5d, [r0+4]
    mov         r7, [r0+16]
    mov         r0d, [r0]
    lea         r8, [h264_cabac_tables]
    MVD_COMPONENT 0
    add         r6, 7
    mov         r2d, [rsp]
    MVD_COMPONENT 4
    mov         [r1], r0d
    mov         [r1+4], r5d
    mov         [r1+16], r7
    mov         eax, [rsp+8]
    neg         eax
    RET

; Decode the four luma and one/two chroma coded-block-pattern bins.
INIT_XMM bmi2
cglobal h264_decode_cbp, 4, 13, 0, 16
    mov         [rsp], r0
    mov         r6, r1
    mov         r5d, [r0+4]
    mov         r7, [r0+16]
    mov         r0d, [r0]
    lea         r8, [h264_cabac_tables]
    mov         r4d, r2d
    shr         r4d, 1
    and         r4d, 1
    mov         r12d, r3d
    shr         r12d, 1
    and         r12d, 2
    or          r4d, r12d
    xor         r4d, 3
    RESIDUAL_GET_CABAC r4
    mov         r12d, r9d
    and         r12d, 1
    mov         r4d, r3d
    shr         r4d, 2
    and         r4d, 2
    or          r4d, r12d
    xor         r4d, 3
    RESIDUAL_GET_CABAC r4
    and         r9d, 1
    lea         r12d, [r12+r9*2]
    mov         r4d, r2d
    shr         r4d, 3
    and         r4d, 1
    lea         r1d, [r12*2]
    and         r1d, 2
    or          r4d, r1d
    xor         r4d, 3
    RESIDUAL_GET_CABAC r4
    and         r9d, 1
    lea         r12d, [r12+r9*4]
    mov         r4d, r12d
    shr         r4d, 2
    and         r4d, 1
    mov         r1d, r12d
    and         r1d, 2
    or          r4d, r1d
    xor         r4d, 3
    RESIDUAL_GET_CABAC r4
    and         r9d, 1
    lea         r12d, [r12+r9*8]
    add         r6, 4
    shr         r2d, 4
    and         r2d, 3
    shr         r3d, 4
    and         r3d, 3
    xor         r4d, r4d
    test        r2d, r2d
    setnz       r4b
    xor         r1d, r1d
    test        r3d, r3d
    setnz       r1b
    lea         r4d, [r4+r1*2]
    RESIDUAL_GET_CABAC r4
    test        r9d, 1
    jz          .done
    xor         r4d, r4d
    cmp         r2d, 2
    sete        r4b
    xor         r1d, r1d
    cmp         r3d, 2
    sete        r1b
    lea         r4d, [r4+r1*2+4]
    RESIDUAL_GET_CABAC r4
    and         r9d, 1
    shl         r9d, 4
    lea         r12d, [r12+r9+16]
.done:
    mov         r1, [rsp]
    mov         [r1], r0d
    mov         [r1+4], r5d
    mov         [r1+16], r7
    mov         eax, r12d
    RET
%endif
