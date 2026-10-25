# =============================================================================
#  BeeNote - the document: text storage, cursor and selection, UTF-8 aware
#  navigation, undo / redo, search, and loading / saving files.
#
#  The text is one flat buffer of bytes; positions are byte offsets. Lines
#  end with '\n' (files with CRLF endings are converted and saved back as
#  CRLF). Columns count characters, with tabs going to the next TABW stop.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "beenote.inc"

.globl text
.globl tlen
.globl cur
.globl sel_anchor
.globl want_col
.globl dirty_doc
.globl fname
.globl fname_len
.globl crlf
.globl edit_kind
.globl prev_edit_kind
.globl line_start
.globl line_end
.globl next_char
.globl prev_char
.globl col_of
.globl pos_at_col
.globl count_nl
.globl line_offset
.globl utf8_at
.globl is_word
.globl word_left
.globl word_right
.globl word_bounds
.globl get_sel
.globl delete_selection
.globl do_insert
.globl do_delete
.globl undo_cmd
.globl redo_cmd
.globl find_from
.globl sbuf
.globl slen
.globl doc_reset
.globl doc_load
.globl doc_save
.globl update_want_col
.globl doc_park
.globl doc_unpark
.globl doc_pristine

.equ O_WRCREAT,     0x241               # O_WRONLY | O_CREAT | O_TRUNC
.equ O_RDONLY_CL,   0x80000             # O_RDONLY | O_CLOEXEC
.equ IO_MAX,        65536

.section .rodata
.align 16
nl16:           .fill 16, 1, 10
.align 8
doc_vars:       # a parked document's state, a qword each (PK_* in beenote.inc)
    .quad tlen, cur, want_col, dirty_doc, fname_len, crlf, edit_kind
    .quad prev_edit_kind, undo_top, redo_top, sel_anchor, scroll_y, scroll_x
doc_vars_end:
.equ DOC_NVARS, (doc_vars_end - doc_vars) / 8

.section .data
.align 8
sel_anchor:     .quad -1

.section .bss
.align 16
tlen:           .skip 8
cur:            .skip 8
want_col:       .skip 8
dirty_doc:      .skip 8                 # unsaved changes
fname_len:      .skip 8
crlf:           .skip 8
edit_kind:      .skip 8                 # 1 typing, 2 backspace, 3 delete: merged undo
prev_edit_kind: .skip 8
undo_top:       .skip 8
redo_top:       .skip 8
undo_suspend:   .skip 8
slen:           .skip 8
fname:          .skip FNAME_MAX
sbuf:           .skip PROMPT_MAX        # the search text
iobuf:          .skip IO_MAX
.align 16
undo:           .skip UNDO_MAX
redo:           .skip UNDO_MAX
text:           .skip TEXT_MAX + 16

.text

# =============================================================================
#  Navigation
# =============================================================================
line_start:                             # rdi = pos -> rax = start of its line
    mov     rax, rdi
1:  test    rax, rax
    jz      2f
    cmp     byte ptr [rax+text-1], 10
    je      2f
    dec     rax
    jmp     1b
2:  ret

line_end:                               # rdi = pos -> rax = its '\n', or the end
    mov     rax, rdi
    mov     rcx, [rip+tlen]
1:  cmp     rax, rcx
    jae     2f
    cmp     byte ptr [rax+text], 10
    je      2f
    inc     rax
    jmp     1b
2:  ret

next_char:                              # rdi = pos -> rax = the next character
    mov     rax, rdi
    mov     rcx, [rip+tlen]
    cmp     rax, rcx
    jae     2f
    inc     rax
1:  cmp     rax, rcx
    jae     2f
    movzx   edx, byte ptr [rax+text]
    and     edx, 0xC0
    cmp     edx, 0x80
    jne     2f
    inc     rax
    jmp     1b
2:  ret

prev_char:                              # rdi = pos -> rax = the previous character
    mov     rax, rdi
    test    rax, rax
    jz      2f
    dec     rax
1:  test    rax, rax
    jz      2f
    movzx   edx, byte ptr [rax+text]
    and     edx, 0xC0
    cmp     edx, 0x80
    jne     2f
    dec     rax
    jmp     1b
2:  ret

# utf8_at(rdi=pos) -> eax = code point there, rdx = the next position
#   (bounded by the text; a broken sequence reads as U+FFFD, one byte)
utf8_at:
    mov     r8, [rip+tlen]
    lea     rdx, [rdi+1]
    movzx   eax, byte ptr [rdi+text]
    cmp     eax, 0x80
    jb      9f
    cmp     eax, 0xC2
    jb      8f
    mov     ecx, 1                      # continuation bytes to come
    and     eax, 0x1F
    cmp     byte ptr [rdi+text], 0xE0
    jb      1f
    mov     ecx, 2
    movzx   eax, byte ptr [rdi+text]
    and     eax, 0x0F
    cmp     byte ptr [rdi+text], 0xF0
    jb      1f
    cmp     byte ptr [rdi+text], 0xF4
    ja      8f
    mov     ecx, 3
    movzx   eax, byte ptr [rdi+text]
    and     eax, 0x07
1:  cmp     rdx, r8
    jae     8f
    movzx   r9d, byte ptr [rdx+text]
    mov     r10d, r9d
    and     r10d, 0xC0
    cmp     r10d, 0x80
    jne     8f
    shl     eax, 6
    and     r9d, 0x3F
    or      eax, r9d
    inc     rdx
    dec     ecx
    jnz     1b
    ret
8:  mov     eax, 0xFFFD
    lea     rdx, [rdi+1]
9:  ret

col_of:                                 # rdi = line start, rsi = pos -> rax = column
    xor     eax, eax
    mov     rcx, rdi
1:  cmp     rcx, rsi
    jae     9f
    movzx   edx, byte ptr [rcx+text]
    inc     rcx
    cmp     edx, 9
    je      3f
    and     edx, 0xC0
    cmp     edx, 0x80
    je      1b
    inc     rax
    jmp     1b
3:  or      rax, TABW-1
    inc     rax
    jmp     1b
9:  ret

pos_at_col:                             # rdi = line start, rsi = column -> rax = pos
    mov     rcx, rdi
    xor     eax, eax
    mov     r9, [rip+tlen]
1:  cmp     rcx, r9
    jae     9f
    movzx   edx, byte ptr [rcx+text]
    cmp     edx, 10
    je      9f
    cmp     edx, 9
    jne     2f
    mov     r8, rax
    or      r8, TABW-1
    inc     r8
    jmp     3f
2:  lea     r8, [rax+1]
3:  cmp     r8, rsi
    ja      9f
    mov     rax, r8
    inc     rcx
4:  cmp     rcx, r9
    jae     1b
    movzx   edx, byte ptr [rcx+text]
    and     edx, 0xC0
    cmp     edx, 0x80
    jne     1b
    inc     rcx
    jmp     4b
9:  mov     rax, rcx
    ret

count_nl:                               # rdi = start, rsi = length -> rax = '\n' count
    xor     eax, eax
    lea     rdi, [rdi+text]
    movdqu  xmm1, [rip+nl16]
1:  cmp     rsi, 16
    jb      2f
    movdqu  xmm0, [rdi]
    pcmpeqb xmm0, xmm1
    pmovmskb ecx, xmm0
    popcnt  ecx, ecx
    add     rax, rcx
    add     rdi, 16
    sub     rsi, 16
    jmp     1b
2:  test    rsi, rsi
    jz      3f
    cmp     byte ptr [rdi], 10
    jne     4f
    inc     rax
4:  inc     rdi
    dec     rsi
    jmp     2b
3:  ret

# line_offset(rdi=line number) -> rax = where that line starts (the last
#   line's start when there are fewer lines)
line_offset:
    test    rdi, rdi
    jz      8f
    mov     r8, rdi                     # newlines still to pass
    xor     ecx, ecx                    # position
    mov     r9, [rip+tlen]
    movdqu  xmm1, [rip+nl16]
1:  lea     rax, [rcx+16]               # whole chunks while they hold fewer
    cmp     rax, r9
    ja      3f
    movdqu  xmm0, [rcx+text]
    pcmpeqb xmm0, xmm1
    pmovmskb eax, xmm0
    popcnt  edx, eax
    cmp     rdx, r8
    jae     3f
    sub     r8, rdx
    add     rcx, 16
    jmp     1b
3:  cmp     rcx, r9                     # then byte by byte
    jae     7f
    cmp     byte ptr [rcx+text], 10
    jne     4f
    dec     r8
    jz      5f
4:  inc     rcx
    jmp     3b
5:  lea     rax, [rcx+1]
    ret
7:  mov     rdi, r9
    jmp     line_start
8:  xor     eax, eax
    ret

update_want_col:
    mov     rdi, [rip+cur]
    call    line_start
    mov     rdi, rax
    mov     rsi, [rip+cur]
    call    col_of
    mov     [rip+want_col], rax
    ret

is_word:                                # edx = byte -> eax = 1 for a word character
    mov     eax, 1
    cmp     edx, 0x80
    jae     1f
    cmp     edx, '_'
    je      1f
    cmp     edx, '0'
    jb      0f
    cmp     edx, '9'
    jbe     1f
    mov     ecx, edx
    or      ecx, 0x20
    cmp     ecx, 'a'
    jb      0f
    cmp     ecx, 'z'
    jbe     1f
0:  xor     eax, eax
1:  ret

word_left:                              # rdi = pos -> rax = start of the word before
    push    rbx
    mov     rbx, rdi
1:  test    rbx, rbx
    jz      3f
    movzx   edx, byte ptr [rbx+text-1]
    call    is_word
    test    eax, eax
    jnz     2f
    dec     rbx
    jmp     1b
2:  test    rbx, rbx
    jz      3f
    movzx   edx, byte ptr [rbx+text-1]
    call    is_word
    test    eax, eax
    jz      3f
    dec     rbx
    jmp     2b
3:  mov     rax, rbx
    pop     rbx
    ret

word_right:                             # rdi = pos -> rax = end of the word after
    push    rbx
    mov     rbx, rdi
1:  cmp     rbx, [rip+tlen]
    jae     3f
    movzx   edx, byte ptr [rbx+text]
    call    is_word
    test    eax, eax
    jnz     2f
    inc     rbx
    jmp     1b
2:  cmp     rbx, [rip+tlen]
    jae     3f
    movzx   edx, byte ptr [rbx+text]
    call    is_word
    test    eax, eax
    jz      3f
    inc     rbx
    jmp     2b
3:  mov     rax, rbx
    pop     rbx
    ret

# word_bounds(rdi=pos) -> rax = start, rdx = end of the word there (a
#   double click); not on a word: the one character
word_bounds:
    push    rbx
    push    r12
    mov     rbx, rdi
    mov     r12, rdi
    cmp     rbx, [rip+tlen]
    jae     5f
    movzx   edx, byte ptr [rbx+text]
    call    is_word
    test    eax, eax
    jz      5f
1:  test    rbx, rbx                    # back to the word's start
    jz      2f
    movzx   edx, byte ptr [rbx+text-1]
    call    is_word
    test    eax, eax
    jz      2f
    dec     rbx
    jmp     1b
2:  cmp     r12, [rip+tlen]             # on to its end
    jae     6f
    movzx   edx, byte ptr [r12+text]
    call    is_word
    test    eax, eax
    jz      6f
    inc     r12
    jmp     2b
5:  mov     rdi, rbx
    call    next_char
    mov     r12, rax
6:  mov     rax, rbx
    mov     rdx, r12
    pop     r12
    pop     rbx
    ret

# get_sel -> rax = selection start, rdx = end; rax = -1 when nothing is selected
get_sel:
    mov     rax, [rip+sel_anchor]
    cmp     rax, -1
    je      2f
    mov     rdx, [rip+cur]
    cmp     rax, rdx
    je      1f
    jb      2f
    xchg    rax, rdx
    ret
1:  mov     rax, -1
2:  ret

delete_selection:                       # rax = 1 when a selection was removed
    call    get_sel
    mov     qword ptr [rip+sel_anchor], -1
    cmp     rax, -1
    je      1f
    mov     rdi, rax
    mov     rsi, rdx
    sub     rsi, rax
    call    do_delete
    mov     eax, 1
    ret
1:  xor     eax, eax
    ret

# =============================================================================
#  Editing primitives, recorded for undo
# =============================================================================
do_insert:                              # rdi = pos, rsi = src, rdx = n; cur = pos + n
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r12, rsi
    mov     r13, rdx
    test    r13, r13
    jz      9f
    mov     rax, [rip+tlen]
    add     rax, r13
    cmp     rax, TEXT_MAX
    ja      8f
    cmp     qword ptr [rip+undo_suspend], 0
    jne     1f
    mov     edi, U_INS
    mov     rsi, rbx
    mov     rdx, r12
    mov     rcx, r13
    call    undo_push
1:  lea     rdi, [rbx+r13+text]
    lea     rsi, [rbx+text]
    mov     rdx, [rip+tlen]
    sub     rdx, rbx
    call    memmove
    lea     rdi, [rbx+text]
    mov     rsi, r12
    mov     rdx, r13
    call    memmove
    add     [rip+tlen], r13
    lea     rax, [rbx+r13]
    mov     [rip+cur], rax
    mov     qword ptr [rip+dirty_doc], 1
    jmp     9f
8:  ERRMSG  "The document is full (16 MB is the limit)"
9:  pop     r13
    pop     r12
    pop     rbx
    ret

do_delete:                              # rdi = pos, rsi = n; cur = pos
    push    rbx
    push    r12
    mov     rbx, rdi
    mov     r12, rsi
    test    r12, r12
    jz      9f
    cmp     qword ptr [rip+undo_suspend], 0
    jne     1f
    mov     edi, U_DEL
    mov     rsi, rbx
    lea     rdx, [rbx+text]
    mov     rcx, r12
    call    undo_push
1:  lea     rdi, [rbx+text]
    lea     rsi, [rbx+r12+text]
    mov     rdx, [rip+tlen]
    sub     rdx, rbx
    sub     rdx, r12
    call    memmove
    sub     [rip+tlen], r12
    mov     [rip+cur], rbx
    mov     qword ptr [rip+dirty_doc], 1
9:  pop     r12
    pop     rbx
    ret

# The undo and redo histories are stacks of records:
#   [kind:8][pos:8][len:8][data:len][offset of the record:8]
# rec_append(rdi=log, rsi=&top, rdx=kind, rcx=pos, r8=src, r9=n)
rec_append:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    rbp
    mov     rbx, rdi
    mov     r12, rsi
    mov     r13, rdx
    mov     r14, rcx
    mov     r15, r8
    mov     rbp, r9
    mov     rax, [r12]
    lea     rcx, [rax+rbp+32]
    cmp     rcx, UNDO_MAX
    jbe     1f
    xor     eax, eax                    # full: the older history goes
    lea     rcx, [rbp+32]
    cmp     rcx, UNDO_MAX
    jbe     1f
    mov     [r12], rax
    jmp     9f
1:  mov     [rbx+rax], r13
    mov     [rbx+rax+8], r14
    mov     [rbx+rax+16], rbp
    push    rax
    lea     rdi, [rbx+rax+24]
    mov     rsi, r15
    mov     rdx, rbp
    call    memmove
    pop     rax
    lea     rcx, [rax+rbp+32]
    mov     [rbx+rcx-8], rax
    mov     [r12], rcx
9:  pop     rbp
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# undo_push(rdi=kind, rsi=pos, rdx=src, rcx=n) - typing, backspacing or
#   deleting in a row grows the last record instead of adding one
undo_push:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r12, rdi
    mov     r13, rsi
    mov     r14, rdx
    mov     r15, rcx
    mov     qword ptr [rip+redo_top], 0
    mov     rax, [rip+edit_kind]
    test    rax, rax
    jz      .Lup_new
    cmp     rax, [rip+prev_edit_kind]
    jne     .Lup_new
    mov     rax, [rip+undo_top]
    test    rax, rax
    jz      .Lup_new
    lea     rcx, [rax+r15]
    cmp     rcx, UNDO_MAX
    ja      .Lup_new
    lea     rdx, [rip+undo]
    mov     rbx, [rdx+rax-8]            # the last record
    add     rbx, rdx                    # (as an address)
    cmp     [rbx], r12
    jne     .Lup_new
    cmp     r12, U_INS
    jne     .Lup_del
    mov     rax, [rbx+8]
    add     rax, [rbx+16]
    cmp     rax, r13
    jne     .Lup_new
.Lup_append:
    mov     rdi, [rip+undo_top]
    lea     rax, [rip+undo]
    lea     rdi, [rax+rdi-8]
    mov     rsi, r14
    mov     rdx, r15
    call    memmove
    add     [rbx+16], r15
    jmp     .Lup_trailer
.Lup_del:
    cmp     [rbx+8], r13                # Delete: the same position, appended
    je      .Lup_append
    lea     rax, [r13+r15]              # Backspace: ends where it began, prepended
    cmp     rax, [rbx+8]
    jne     .Lup_new
    lea     rsi, [rbx+24]
    lea     rdi, [rsi+r15]
    mov     rdx, [rbx+16]
    call    memmove
    lea     rdi, [rbx+24]
    mov     rsi, r14
    mov     rdx, r15
    call    memmove
    add     [rbx+16], r15
    mov     [rbx+8], r13
.Lup_trailer:
    mov     rax, [rip+undo_top]
    add     rax, r15
    mov     [rip+undo_top], rax
    lea     rdx, [rip+undo]
    sub     rbx, rdx
    mov     [rdx+rax-8], rbx
    jmp     .Lup_ret
.Lup_new:
    lea     rdi, [rip+undo]
    lea     rsi, [rip+undo_top]
    mov     rdx, r12
    mov     rcx, r13
    mov     r8, r14
    mov     r9, r15
    call    rec_append
.Lup_ret:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# history_step(rdi=from log, rsi=&from top, rdx=to log, rcx=&to top, r8d=1
#   to apply the record as it was done (redo), 0 to reverse it (undo))
#   -> eax = 0 when the history is empty
history_step:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r12, rdi
    mov     r13, rsi
    mov     r14, rdx
    mov     r15, rcx
    mov     rax, [r13]
    test    rax, rax
    jz      8f
    mov     rbx, [r12+rax-8]
    mov     [r13], rbx
    add     rbx, r12                    # the record
    push    r8
    sub     rsp, 8
    mov     rdi, r14                    # it goes on the other stack
    mov     rsi, r15
    mov     rdx, [rbx]
    mov     rcx, [rbx+8]
    lea     r8, [rbx+24]
    mov     r9, [rbx+16]
    call    rec_append
    add     rsp, 8
    pop     r8
    mov     qword ptr [rip+undo_suspend], 1
    mov     rax, [rbx]                  # insert when (kind == U_INS) == redo
    cmp     rax, U_INS
    sete    al
    movzx   eax, al
    cmp     eax, r8d
    jne     1f
    mov     rdi, [rbx+8]
    lea     rsi, [rbx+24]
    mov     rdx, [rbx+16]
    call    do_insert
    jmp     2f
1:  mov     rdi, [rbx+8]
    mov     rsi, [rbx+16]
    call    do_delete
2:  mov     qword ptr [rip+undo_suspend], 0
    mov     qword ptr [rip+sel_anchor], -1
    mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

undo_cmd:
    lea     rdi, [rip+undo]
    lea     rsi, [rip+undo_top]
    lea     rdx, [rip+redo]
    lea     rcx, [rip+redo_top]
    xor     r8d, r8d
    call    history_step
    test    eax, eax
    jnz     1f
    SETMSG  "Nothing to undo"
1:  ret

redo_cmd:
    lea     rdi, [rip+redo]
    lea     rsi, [rip+redo_top]
    lea     rdx, [rip+undo]
    lea     rcx, [rip+undo_top]
    mov     r8d, 1
    call    history_step
    test    eax, eax
    jnz     1f
    SETMSG  "Nothing to redo"
1:  ret

# =============================================================================
#  Search (case-insensitive for ASCII letters)
# =============================================================================
# match_at(rdi=pos) -> eax = 1 when sbuf matches there
match_at:
    mov     r8, [rip+slen]
    lea     rax, [rdi+r8]
    cmp     rax, [rip+tlen]
    ja      8f
    xor     ecx, ecx
1:  cmp     rcx, r8
    jae     7f
    movzx   eax, byte ptr [rdi+rcx+text]
    lea     rdx, [rip+sbuf]
    movzx   edx, byte ptr [rdx+rcx]
    lea     r9d, [rax-'A']
    cmp     r9d, 25
    ja      2f
    or      eax, 0x20
2:  lea     r9d, [rdx-'A']
    cmp     r9d, 25
    ja      3f
    or      edx, 0x20
3:  cmp     eax, edx
    jne     8f
    inc     rcx
    jmp     1b
7:  mov     eax, 1
    ret
8:  xor     eax, eax
    ret

# find_from(rdi=start, esi=direction 1 / -1) -> rax = the next match's
#   position (wrapping around the document), or -1
find_from:
    push    rbx
    push    r12
    push    r13
    push    r14
    mov     rbx, rdi
    mov     r12d, esi
    mov     r14, -1
    cmp     qword ptr [rip+slen], 0
    je      9f
    mov     r13, [rip+tlen]             # positions 0 .. tlen - slen
    sub     r13, [rip+slen]
    jb      9f
    cmp     rbx, r13
    jbe     1f
    mov     rbx, r13
    test    r12d, r12d
    jns     1f
1:  mov     rcx, r13                    # every position once, wrapping
    inc     rcx
    mov     r14, rcx                    # (the count to try)
2:  mov     rdi, rbx
    call    match_at
    test    eax, eax
    jnz     5f
    test    r12d, r12d
    js      3f
    inc     rbx
    cmp     rbx, r13
    jbe     4f
    xor     ebx, ebx
    jmp     4f
3:  test    rbx, rbx
    jnz     31f
    mov     rbx, r13
    jmp     4f
31: dec     rbx
4:  dec     r14
    jnz     2b
    mov     r14, -1
    jmp     9f
5:  mov     r14, rbx
9:  mov     rax, r14
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  Files
# =============================================================================
doc_reset:                              # an empty document, no history
    xor     eax, eax
    mov     [rip+tlen], rax
    mov     [rip+cur], rax
    mov     [rip+want_col], rax
    mov     [rip+dirty_doc], rax
    mov     [rip+undo_top], rax
    mov     [rip+redo_top], rax
    mov     [rip+crlf], rax
    mov     [rip+edit_kind], rax
    mov     [rip+prev_edit_kind], rax
    mov     qword ptr [rip+sel_anchor], -1
    ret

doc_pristine:                           # eax = 1: untitled, empty, never edited
    xor     eax, eax
    mov     rcx, [rip+fname_len]
    or      rcx, [rip+tlen]
    or      rcx, [rip+dirty_doc]
    or      rcx, [rip+undo_top]
    or      rcx, [rip+redo_top]
    sete    al
    ret

# doc_park - the document (its state, name, text and both histories) is
#   copied to memory of its own -> rax = that block, rdx = its size; rax =
#   0 when there is no memory for it. The buffers are left as they were.
#   Block: [state: PK_NAME][name: FNAME_MAX][text][undo][redo]
doc_park:
    push    rbx
    push    r12
    push    r13
    mov     r12, [rip+tlen]
    add     r12, [rip+undo_top]
    add     r12, [rip+redo_top]
    add     r12, PK_HDR + 4095
    and     r12, -4096
    mov     eax, SYS_MMAP
    xor     edi, edi
    mov     rsi, r12
    mov     edx, PROT_RW
    mov     r10d, 0x22                  # MAP_PRIVATE | MAP_ANONYMOUS
    mov     r8, -1
    xor     r9d, r9d
    call    plat_sys
    test    rax, rax
    js      8f
    mov     rbx, rax
    lea     rsi, [rip+doc_vars]
    xor     ecx, ecx
1:  mov     rdx, [rsi+rcx*8]
    mov     rdx, [rdx]
    mov     [rbx+rcx*8], rdx
    inc     ecx
    cmp     ecx, DOC_NVARS
    jb      1b
    lea     rdi, [rbx+PK_NAME]
    lea     rsi, [rip+fname]
    mov     rdx, [rip+fname_len]
    inc     rdx                         # (with its 0)
    call    memmove
    lea     r13, [rbx+PK_HDR]
    mov     rdi, r13
    lea     rsi, [rip+text]
    mov     rdx, [rip+tlen]
    call    memmove
    add     r13, [rip+tlen]
    mov     rdi, r13
    lea     rsi, [rip+undo]
    mov     rdx, [rip+undo_top]
    call    memmove
    add     r13, [rip+undo_top]
    mov     rdi, r13
    lea     rsi, [rip+redo]
    mov     rdx, [rip+redo_top]
    call    memmove
    mov     rax, rbx
    mov     rdx, r12
    jmp     9f
8:  xor     eax, eax
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# doc_unpark(rdi=block, rsi=its size) - a parked document comes back into
#   the buffers; its block is freed
doc_unpark:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r12, rsi
    lea     rsi, [rip+doc_vars]
    xor     ecx, ecx
1:  mov     rdx, [rbx+rcx*8]
    mov     rax, [rsi+rcx*8]
    mov     [rax], rdx
    inc     ecx
    cmp     ecx, DOC_NVARS
    jb      1b
    lea     rdi, [rip+fname]
    lea     rsi, [rbx+PK_NAME]
    mov     rdx, [rip+fname_len]
    inc     rdx
    call    memmove
    lea     r13, [rbx+PK_HDR]
    lea     rdi, [rip+text]
    mov     rsi, r13
    mov     rdx, [rip+tlen]
    call    memmove
    add     r13, [rip+tlen]
    lea     rdi, [rip+undo]
    mov     rsi, r13
    mov     rdx, [rip+undo_top]
    call    memmove
    add     r13, [rip+undo_top]
    lea     rdi, [rip+redo]
    mov     rsi, r13
    mov     rdx, [rip+redo_top]
    call    memmove
    mov     eax, SYS_MUNMAP
    mov     rdi, rbx
    mov     rsi, r12
    call    plat_sys
    pop     r13
    pop     r12
    pop     rbx
    ret

msg_add_name:                           # the file's name (not its folders)
    mov     rdx, [rip+fname_len]
    lea     rax, [rip+fname]
    lea     rsi, [rax+rdx]
1:  cmp     rsi, rax
    jbe     2f
    cmp     byte ptr [rsi-1], '/'
    je      2f
    dec     rsi
    jmp     1b
2:  add     rdx, rax
    sub     rdx, rsi
    jmp     msg_add

# doc_load - read [fname] -> eax = 0 opened, 1 a new file, -1 an error
#   (the document is replaced in every case; the message says what happened)
doc_load:
    push    rbx
    push    r12
    push    r13
    call    doc_reset
    mov     eax, 2                      # open
    lea     rdi, [rip+fname]
    mov     esi, O_RDONLY_CL
    xor     edx, edx
    call    plat_sys
    cmp     rax, -2                     # ENOENT: a new file of that name
    jne     1f
    SETMSG  "New file: "
    call    msg_add_name
    mov     eax, 1
    jmp     9f
1:  test    rax, rax
    jns     2f
    neg     rax
    mov     rbx, rax
    ERRMSG  "Cannot open "
    call    msg_add_name
    MSGADD  " (error "
    mov     rdi, rbx
    call    msg_num
    MSGADD  ")"
    mov     qword ptr [rip+fname_len], 0
    mov     byte ptr [rip+fname], 0
    mov     eax, -1
    jmp     9f
2:  mov     rbx, rax                    # fd
    xor     r12d, r12d                  # 1: too large
    xor     r13d, r13d                  # 1: a read error
3:  mov     rdx, TEXT_MAX
    sub     rdx, [rip+tlen]
    jz      4f
    mov     rsi, [rip+tlen]
    lea     rax, [rip+text]
    add     rsi, rax
    xor     eax, eax                    # read
    mov     rdi, rbx
    call    plat_sys
    cmp     rax, -4
    je      3b
    test    rax, rax
    js      5f
    jz      6f
    add     [rip+tlen], rax
    jmp     3b
4:  xor     eax, eax                    # full: is there more?
    mov     rdi, rbx
    lea     rsi, [rip+iobuf]
    mov     edx, 1
    call    plat_sys
    test    rax, rax
    jle     6f
    mov     r12d, 1
    jmp     6f
5:  mov     r13d, 1
6:  mov     eax, SYS_CLOSE
    mov     rdi, rbx
    call    plat_sys
    xor     ecx, ecx                    # CRLF -> LF (remembered for saving)
    xor     edx, edx
    mov     r8, [rip+tlen]
    lea     r10, [rip+text]
7:  cmp     rcx, r8
    jae     8f
    mov     al, [r10+rcx]
    cmp     al, 13
    jne     71f
    lea     r9, [rcx+1]
    cmp     r9, r8
    jae     71f
    cmp     byte ptr [r10+r9], 10
    jne     71f
    mov     qword ptr [rip+crlf], 1
    inc     rcx
    jmp     7b
71: mov     [r10+rdx], al
    inc     rcx
    inc     rdx
    jmp     7b
8:  mov     [rip+tlen], rdx
    test    r13, r13
    jz      81f
    ERRMSG  "Cannot read "
    call    msg_add_name
    mov     qword ptr [rip+fname_len], 0
    mov     byte ptr [rip+fname], 0
    mov     qword ptr [rip+tlen], 0
    mov     eax, -1
    jmp     9f
81: test    r12, r12
    jz      82f
    ERRMSG  "Too large: only the first 16 MB were loaded. Save it under a new name."
    mov     qword ptr [rip+fname_len], 0
    mov     byte ptr [rip+fname], 0
    xor     eax, eax
    jmp     9f
82: SETMSG  "Opened "
    call    msg_add_name
    call    recent_add
    xor     eax, eax
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# doc_save - write the document to [fname] -> eax = 0, or -1 (message set)
doc_save:
    push    rbx
    push    r12
    push    r13
    push    r14
    mov     eax, 2                      # open
    lea     rdi, [rip+fname]
    mov     esi, O_WRCREAT | 0x80000
    mov     edx, 0644
    call    plat_sys
    test    rax, rax
    js      6f
    mov     rbx, rax                    # fd
    cmp     qword ptr [rip+crlf], 0
    jne     3f
    mov     rdi, rbx
    lea     rsi, [rip+text]
    mov     rdx, [rip+tlen]
    call    write_all
    mov     r12, rax
    mov     r13, [rip+tlen]
    jmp     5f
3:  xor     r12d, r12d                  # CRLF line endings
    xor     r13d, r13d                  # bytes written
    xor     r14d, r14d                  # source position
    xor     ecx, ecx                    # iobuf fill
31: cmp     r14, [rip+tlen]
    jae     33f
    lea     rax, [rip+text]
    mov     al, [rax+r14]
    inc     r14
    lea     rdx, [rip+iobuf]
    cmp     al, 10
    jne     32f
    mov     byte ptr [rdx+rcx], 13
    inc     rcx
32: mov     [rdx+rcx], al
    inc     rcx
    cmp     rcx, IO_MAX-2
    jb      31b
33: test    rcx, rcx
    jz      34f
    add     r13, rcx
    mov     rdi, rbx
    lea     rsi, [rip+iobuf]
    mov     rdx, rcx
    call    write_all
    xor     ecx, ecx
    test    rax, rax
    jns     31b
    mov     r12, rax
    jmp     5f
34: cmp     r14, [rip+tlen]
    jb      31b
5:  mov     eax, SYS_CLOSE
    mov     rdi, rbx
    call    plat_sys
    test    r12, r12
    js      8f
    test    rax, rax
    js      8f
    mov     qword ptr [rip+dirty_doc], 0
    SETMSG  "Saved "
    call    msg_add_name
    MSGADD  " ("
    mov     rdi, r13
    call    msg_num
    MSGADD  " bytes)"
    call    recent_add
    xor     eax, eax
    jmp     9f
6:  neg     rax
    mov     rbx, rax
    ERRMSG  "Cannot write "
    call    msg_add_name
    MSGADD  " (error "
    mov     rdi, rbx
    call    msg_num
    MSGADD  ")"
    mov     eax, -1
    jmp     9f
8:  ERRMSG  "Error while writing "
    call    msg_add_name
    mov     eax, -1
9:  pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.section .note.GNU-stack,"",@progbits
