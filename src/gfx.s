# =============================================================================
#  BeeNote - fonts and text: the Omarchy font through BeeModel's TrueType
#  engine (ttf.s), line metrics, and anti-aliased glyphs blended into the
#  framebuffer. Without a usable font the built-in 8x16 bitmap font is used.
#
#  Both faces are the same monospace font: FONT_UI for the menus, bars and
#  dialogs, FONT_MONO for the document (its size follows the zoom).
#  Everything here is in physical pixels.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "beenote.inc"

.globl fonts_init
.globl fonts_resize
.globl fonts_ok
.globl ed_px
.globl ui_px
.globl ed_lh
.globl ed_asc
.globl ed_cw16
.globl ui_lh
.globl ui_asc
.globl ui_desc
.globl draw_glyph
.globl ui_text
.globl ui_text_w
.globl font_path

.equ UI_PX_DEF,     14                  # logical px

.section .data
.align 4
ed_px:          .long 16                # the document's font, logical px
ui_px:          .long UI_PX_DEF

.section .bss
.align 8
fonts_ok:       .skip 4                 # 1: a TrueType font is loaded
ed_lh:          .skip 4                 # document line height (px)
ed_asc:         .skip 4                 # baseline below a line's top
ed_cw16:        .skip 4                 # character cell width, 16.16
ui_lh:          .skip 4
ui_asc:         .skip 4
ui_desc:        .skip 4
font_path:      .skip 1024              # the font in use

.section .rodata
mp0: .asciz "/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf"
mp1: .asciz "/usr/share/fonts/TTF/JetBrainsMono-Regular.ttf"
mp2: .asciz "/usr/share/fonts/noto/NotoSansMono-Regular.ttf"
mp3: .asciz "/usr/share/fonts/TTF/DejaVuSansMono.ttf"
mp4: .asciz "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf"
mp5: .asciz "/usr/share/fonts/liberation/LiberationMono-Regular.ttf"
mp6: .asciz "/usr/share/fonts/truetype/noto/NotoSansMono-Regular.ttf"
mp7: .asciz "/C:/Windows/Fonts/consola.ttf"     # (Windows: Consolas, Lucida
mp8: .asciz "/C:/Windows/Fonts/lucon.ttf"       #  Console, Courier New)
mp9: .asciz "/C:/Windows/Fonts/cour.ttf"
.align 8
mono_paths:     .quad mp0, mp1, mp2, mp3, mp4, mp5, mp6, mp7, mp8, mp9, 0
s_env_font:     .asciz "BEENOTE_FONT="

.text

# one colour channel at bit offset \sh: src in r14d, dst in r8d, a in eax,
# 255-a in edx, result OR-ed into r9d
.macro BLEND sh
    mov     ecx, r14d
    shr     ecx, \sh
    and     ecx, 255
    imul    ecx, eax
    mov     esi, r8d
    shr     esi, \sh
    and     esi, 255
    imul    esi, edx
    add     ecx, esi
    add     ecx, 128
    mov     esi, ecx
    shr     esi, 8
    add     ecx, esi
    shr     ecx, 8
    shl     ecx, \sh
    or      r9d, ecx
.endm

# try_font(rsi=path) -> eax = 1 when it loaded (both slots get it)
try_font:
    push    rbx
    mov     rbx, rsi
    cmp     byte ptr [rbx], 0
    je      8f
    mov     edi, FONT_MONO
    call    font_load
    test    eax, eax
    jz      8f
    lea     rsi, [rip+fonts]            # the UI slot: the same face
    lea     rdi, [rsi+FONT_UI*FNT_SZ]
    add     rsi, FONT_MONO*FNT_SZ
    mov     ecx, FNT_SZ
    rep     movsb
    lea     rdi, [rip+font_path]        # (remembered: the status of the config)
    xor     ecx, ecx
1:  mov     al, [rbx+rcx]
    mov     [rdi+rcx], al
    inc     ecx
    test    al, al
    jz      2f
    cmp     ecx, 1023
    jb      1b
    mov     byte ptr [rdi+rcx], 0
2:  mov     dword ptr [rip+fonts_ok], 1
    mov     eax, 1
    pop     rbx
    ret
8:  xor     eax, eax
    pop     rbx
    ret

# fonts_init(rdi=the configured font path or 0) - BEENOTE_FONT, then the
#   configuration's (the Omarchy font), then common monospace fonts
fonts_init:
    push    rbx
    mov     rbx, rdi
    call    gamma_init
    lea     rdi, [rip+s_env_font]
    call    getenv
    test    rax, rax
    jz      1f
    mov     rsi, rax
    call    try_font
    test    eax, eax
    jnz     9f
1:  test    rbx, rbx
    jz      2f
    mov     rsi, rbx
    call    try_font
    test    eax, eax
    jnz     9f
2:  lea     rbx, [rip+mono_paths]
3:  mov     rsi, [rbx]
    test    rsi, rsi
    jz      9f
    call    try_font
    test    eax, eax
    jnz     9f
    add     rbx, 8
    jmp     3b
9:  pop     rbx
    jmp     fonts_resize

# metrics(edi=slot) -> eax = ascent px, edx = descent px (positive),
#   ecx = advance of '0' (16.16)
metrics:
    push    rbx
    mov     ebx, edi
    imul    edi, FNT_SZ
    lea     rax, [rip+fonts]
    add     rax, rdi
    movss   xmm0, [rax+FNT_SCALE]
    cvtsi2ss xmm1, dword ptr [rax+FNT_ASCU]
    mulss   xmm1, xmm0
    cvtss2si r8d, xmm1
    cvtsi2ss xmm2, dword ptr [rax+FNT_DESCU]
    mulss   xmm2, xmm0
    cvtss2si r9d, xmm2
    neg     r9d
    push    r8
    push    r9
    mov     edi, ebx
    mov     esi, '0'
    call    glyph_get
    mov     ecx, [rax+16]
    pop     rdx
    pop     rax
    pop     rbx
    ret

# fonts_resize - sizes for the current scale and zoom; line metrics
fonts_resize:
    push    rbx
    push    r12
    push    r13
    mov     r12d, [rip+ed_lh]           # (the old metrics: the scroll keeps its line)
    mov     r13d, [rip+ed_cw16]
    cmp     dword ptr [rip+fonts_ok], 0
    je      5f
    mov     edi, FONT_UI
    mov     esi, [rip+ui_px]
    call    font_set_size
    mov     edi, FONT_MONO
    mov     esi, [rip+ed_px]
    call    font_set_size
    mov     edi, FONT_UI
    call    metrics
    mov     [rip+ui_asc], eax
    mov     [rip+ui_desc], edx
    add     eax, edx
    mov     [rip+ui_lh], eax
    mov     edi, FONT_MONO
    call    metrics
    mov     [rip+ed_cw16], ecx
    lea     ebx, [rax+rdx]              # text height
    mov     ecx, ebx                    # line height: + 20 %
    imul    ecx, ecx, 6
    push    rax
    mov     eax, ecx
    xor     edx, edx
    mov     ecx, 5
    div     ecx
    mov     ecx, eax
    pop     rax
    mov     [rip+ed_lh], ecx
    sub     ecx, ebx                    # baseline: centred
    shr     ecx, 1
    add     eax, ecx
    mov     [rip+ed_asc], eax
    jmp     9f
5:  mov     dword ptr [rip+ui_asc], 12  # the bitmap font
    mov     dword ptr [rip+ui_desc], 4
    mov     dword ptr [rip+ui_lh], 16
    mov     dword ptr [rip+ed_lh], 18
    mov     dword ptr [rip+ed_asc], 13
    mov     dword ptr [rip+ed_cw16], 8 << 16
9:  test    r12d, r12d              # the same text stays in view
    jz      10f
    mov     rax, [rip+scroll_y]
    mov     ecx, [rip+ed_lh]
    imul    rax, rcx
    cqo
    idiv    r12
    mov     [rip+scroll_y], rax
    test    r13d, r13d
    jz      10f
    mov     rax, [rip+scroll_x]
    mov     ecx, [rip+ed_cw16]
    imul    rax, rcx
    cqo
    idiv    r13
    mov     [rip+scroll_x], rax
10: mov     dword ptr [rip+dirty], 1
    pop     r13
    pop     r12
    pop     rbx
    ret

# draw_glyph(edi=slot, esi=code point, edx=x, ecx=baseline, r8d=colour)
#   -> eax = its advance (16.16)
draw_glyph:
    cmp     dword ptr [rip+fonts_ok], 0
    je      bm_glyph
    push    rbx
    push    r12
    push    r13
    mov     r12d, edx
    mov     r13d, ecx
    mov     ebx, r8d
    call    glyph_get
    push    rax
    sub     rsp, 8
    movsx   esi, word ptr [rax+12]
    add     esi, r12d                   # x + left
    movsx   edx, word ptr [rax+14]
    add     edx, r13d                   # baseline + top
    mov     rdi, rax
    mov     ecx, ebx
    call    blit_glyph
    add     rsp, 8
    pop     rax
    mov     eax, [rax+16]
    pop     r13
    pop     r12
    pop     rbx
    ret

# bm_glyph - draw_glyph with the 8x16 bitmap font (ASCII; others as '?')
bm_glyph:
    push    rbx
    push    r12
    push    r13
    push    r14
    mov     r12d, edx                   # x
    lea     r13d, [rcx-12]              # top
    mov     r14d, r8d
    cmp     esi, 32
    jb      1f
    cmp     esi, 126
    jbe     2f
1:  mov     esi, '?'
2:  sub     esi, 32
    shl     esi, 4
    lea     rbx, [rip+font_8x16]
    add     rbx, rsi
    xor     r9d, r9d                    # row
3:  cmp     r9d, 16
    jae     8f
    movzx   r10d, byte ptr [rbx+r9]
    xor     r11d, r11d                  # column
4:  cmp     r11d, 8
    jae     7f
    bt      r10d, 7
    jnc     6f
    lea     eax, [r12+r11]
    cmp     eax, [rip+clip_x0]
    jl      6f
    cmp     eax, [rip+clip_x1]
    jge     6f
    lea     ecx, [r13+r9]
    cmp     ecx, [rip+clip_y0]
    jl      6f
    cmp     ecx, [rip+clip_y1]
    jge     6f
    imul    ecx, [rip+fb_w]
    add     ecx, eax
    mov     rax, [rip+fb_ptr]
    mov     [rax+rcx*4], r14d
6:  shl     r10d, 1
    inc     r11d
    jmp     4b
7:  inc     r9d
    jmp     3b
8:  mov     eax, 8 << 16
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# ui_text(rdi=UTF-8, rsi=bytes, edx=x, ecx=vertical centre, r8d=colour)
#   -> eax = x after, in the UI font
ui_text:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
    mov     rbx, rdi
    lea     rbp, [rdi+rsi]              # end
    mov     r12d, edx
    shl     r12d, 16                    # pen, 16.16
    mov     r13d, [rip+ui_asc]          # baseline = centre + (asc - desc) / 2
    sub     r13d, [rip+ui_desc]
    sar     r13d, 1
    add     r13d, ecx
    mov     r14d, r8d
1:  cmp     rbx, rbp
    jae     9f
    mov     rsi, rbx
    call    utf8_next
    mov     rbx, rsi
    test    eax, eax
    jz      9f
    mov     edi, FONT_UI
    mov     esi, eax
    mov     edx, r12d
    add     edx, 0x8000
    sar     edx, 16
    mov     ecx, r13d
    mov     r8d, r14d
    call    draw_glyph
    add     r12d, eax
    jmp     1b
9:  mov     eax, r12d
    add     eax, 0x8000
    sar     eax, 16
    add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

# ui_text_w(rdi=UTF-8, rsi=bytes) -> eax = its width in the UI font
ui_text_w:
    push    rbx
    push    rbp
    push    r12
    mov     rbx, rdi
    lea     rbp, [rdi+rsi]
    xor     r12d, r12d
1:  cmp     rbx, rbp
    jae     9f
    mov     rsi, rbx
    call    utf8_next
    mov     rbx, rsi
    test    eax, eax
    jz      9f
    cmp     dword ptr [rip+fonts_ok], 0
    je      2f
    mov     edi, FONT_UI
    mov     esi, eax
    call    glyph_get
    add     r12d, [rax+16]
    jmp     1b
2:  add     r12d, 8 << 16
    jmp     1b
9:  mov     eax, r12d
    add     eax, 0x8000
    sar     eax, 16
    pop     r12
    pop     rbp
    pop     rbx
    ret

# blit_glyph(rdi=cache entry, esi=x, edx=y, ecx=colour) - alpha blended,
#   clipped (from BeeModel's text.s)
blit_glyph:
    movzx   eax, word ptr [rdi+8]
    test    eax, eax
    jz      .Lbg_ret
    movzx   r8d, word ptr [rdi+10]
    test    r8d, r8d
    jz      .Lbg_ret
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    mov     ebx, eax                    # w
    mov     ebp, r8d                    # h
    mov     r12d, esi                   # x
    mov     r13d, edx                   # y
    mov     r14d, ecx                   # colour
    mov     r15d, [rdi+4]
    add     r15, [rip+arena]            # bitmap
    xor     r8d, r8d                    # first column inside the clip
    mov     eax, [rip+clip_x0]
    sub     eax, r12d
    cmp     eax, r8d
    cmovg   r8d, eax
    mov     r9d, [rip+clip_x1]          # last column
    sub     r9d, r12d
    cmp     r9d, ebx
    cmovg   r9d, ebx
    cmp     r8d, r9d
    jge     .Lbg_done
    xor     r10d, r10d                  # row
1:  cmp     r10d, ebp
    jge     .Lbg_done
    lea     eax, [r13+r10]
    cmp     eax, [rip+clip_y0]
    jl      6f
    cmp     eax, [rip+clip_y1]
    jge     .Lbg_done
    imul    eax, [rip+fb_w]
    add     eax, r12d
    movsxd  rax, eax
    mov     rdi, [rip+fb_ptr]
    lea     rdi, [rdi+rax*4]
    mov     eax, r10d
    imul    eax, ebx
    lea     rsi, [r15+rax]
    mov     r11d, r8d
2:  cmp     r11d, r9d
    jge     6f
    movzx   eax, byte ptr [rsi+r11]
    test    eax, eax
    jz      5f
    cmp     eax, 255
    jne     3f
    mov     [rdi+r11*4], r14d
    jmp     5f
3:  push    r8
    push    r9
    push    rsi
    mov     r8d, [rdi+r11*4]
    mov     edx, 255
    sub     edx, eax
    xor     r9d, r9d
    BLEND   0
    BLEND   8
    BLEND   16
    mov     [rdi+r11*4], r9d
    pop     rsi
    pop     r9
    pop     r8
5:  inc     r11d
    jmp     2b
6:  inc     r10d
    jmp     1b
.Lbg_done:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
.Lbg_ret:
    ret

.section .note.GNU-stack,"",@progbits
