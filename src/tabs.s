# =============================================================================
#  BeeNote - tabs: several documents open at once.
#
#  The active tab's document is in buffer.s's buffers, where all the editing
#  code finds it. Every other tab is parked: its state, name, text and undo /
#  redo histories copied to a block of memory of its own (doc_park), which
#  comes back into the buffers when the tab is chosen again (doc_unpark).
#  A switch copies the two documents once; editing costs nothing extra.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "beenote.inc"

.globl tab_n
.globl tab_cur
.globl tab_info
.globl tab_new
.globl tab_switch
.globl tab_drop
.globl tab_open

.section .data
.align 8
tab_n:          .quad 1                 # tabs open (there is always one)

.section .bss
.align 8
tab_cur:        .skip 8                 # the active tab
tab_mem:        .skip 8*TABS_MAX        # each parked tab's block (the active: 0)
tab_size:       .skip 8*TABS_MAX
open_req:       .skip FNAME_MAX         # (tab_open: the path asked for)

.text

# tab_info(rdi=tab) -> rsi = its file's path (asciz), rdx = the path's
#   length (0: untitled), rcx = 1 when it has unsaved changes
tab_info:
    cmp     rdi, [rip+tab_cur]
    jne     1f
    lea     rsi, [rip+fname]
    mov     rdx, [rip+fname_len]
    mov     rcx, [rip+dirty_doc]
    ret
1:  lea     rax, [rip+tab_mem]
    mov     rax, [rax+rdi*8]
    lea     rsi, [rax+PK_NAME]
    mov     rdx, [rax+PK_FNLEN]
    mov     rcx, [rax+PK_DIRTY]
    ret

# park_cur - the active tab's document goes to its block -> eax = 0, or -1
#   (no memory: the message says so, nothing changed)
park_cur:
    call    doc_park
    test    rax, rax
    jz      8f
    mov     rcx, [rip+tab_cur]
    lea     r8, [rip+tab_mem]
    mov     [r8+rcx*8], rax
    lea     r8, [rip+tab_size]
    mov     [r8+rcx*8], rdx
    xor     eax, eax
    ret
8:  ERRMSG  "Not enough memory for another tab"
    mov     eax, -1
    ret

# unpark(rdi=tab) - that parked tab becomes the active one
unpark:
    mov     [rip+tab_cur], rdi
    lea     rax, [rip+tab_size]
    mov     rsi, [rax+rdi*8]
    lea     rax, [rip+tab_mem]
    lea     rcx, [rax+rdi*8]
    mov     rdi, [rcx]
    mov     qword ptr [rcx], 0
    call    doc_unpark
    mov     dword ptr [rip+dirty], 1
    ret

# busy -> eax = 1 while a prompt or dialog is open: it belongs to the
#   active document, so the tabs stay as they are
busy:
    xor     eax, eax
    cmp     qword ptr [rip+modal], 0
    setne   al
    ret

# tab_switch(rdi=tab) - make it the active one -> eax = 0, or -1
tab_switch:
    push    rbx
    mov     rbx, rdi
    call    busy
    test    eax, eax
    jnz     8f
    cmp     rbx, [rip+tab_cur]
    je      9f
    cmp     rbx, [rip+tab_n]
    jae     8f
    call    park_cur
    test    eax, eax
    jnz     8f
    mov     rdi, rbx
    call    unpark
    xor     eax, eax
    jmp     9f
8:  mov     eax, -1
9:  pop     rbx
    ret

# blank - the active document becomes an empty, untitled one
blank:
    call    doc_reset
    mov     qword ptr [rip+fname_len], 0
    mov     byte ptr [rip+fname], 0
    xor     eax, eax
    mov     [rip+scroll_y], rax
    mov     [rip+scroll_x], rax
    mov     qword ptr [rip+follow], 1
    mov     dword ptr [rip+dirty], 1
    ret

# tab_new - a new tab (the last one) with an empty, untitled document
#   -> eax = 0, or -1 (the message says why)
tab_new:
    call    busy
    test    eax, eax
    jnz     8f
    cmp     qword ptr [rip+tab_n], TABS_MAX
    jb      1f
    ERRMSG  "64 tabs are open: close one first"
    jmp     8f
1:  call    park_cur
    test    eax, eax
    jnz     8f
    mov     rax, [rip+tab_n]
    mov     [rip+tab_cur], rax
    inc     qword ptr [rip+tab_n]
    call    blank
    xor     eax, eax
    ret
8:  mov     eax, -1
    ret

# tab_drop(rdi=the tab to show next, -1: a neighbour) - the active tab is
#   closed, unsaved changes and all (the last one becomes an empty document)
tab_drop:
    cmp     qword ptr [rip+tab_n], 1
    jbe     blank
    mov     rcx, [rip+tab_cur]          # the tabs after it move down
    lea     rdx, [rip+tab_mem]
    lea     r8, [rip+tab_size]
1:  lea     rax, [rcx+1]
    cmp     rax, [rip+tab_n]
    jae     2f
    mov     r9, [rdx+rax*8]
    mov     [rdx+rcx*8], r9
    mov     r9, [r8+rax*8]
    mov     [r8+rcx*8], r9
    mov     rcx, rax
    jmp     1b
2:  dec     qword ptr [rip+tab_n]
    mov     rcx, [rip+tab_cur]
    test    rdi, rdi
    jns     3f
    mov     rdi, rcx                    # the one after it, or before the last
    cmp     rdi, [rip+tab_n]
    jb      4f
    dec     rdi
    jmp     4f
3:  cmp     rdi, rcx                    # (one after it moved down)
    jbe     4f
    dec     rdi
4:  jmp     unpark

# tab_open(rsi=path) - open a file: its tab when it is open already, else
#   in a new tab (or in this one, when it is empty and untitled)
#   -> eax = 0 opened, 1 a new file, -1 it could not be read (the tab it
#   was given goes again), -2 no tab for it
tab_open:
    push    rbx
    push    r12
    lea     rdi, [rip+open_req]         # (the path may live in what changes)
    xor     ecx, ecx
1:  mov     al, [rsi+rcx]
    mov     [rdi+rcx], al
    test    al, al
    jz      2f
    inc     ecx
    cmp     ecx, FNAME_MAX-1
    jb      1b
    mov     byte ptr [rdi+rcx], 0
2:  xor     ebx, ebx                    # open already?
3:  cmp     rbx, [rip+tab_n]
    jae     5f
    mov     rdi, rbx
    call    tab_info
    test    rdx, rdx
    jz      4f
    lea     rdi, [rip+open_req]
    call    str_eq
    test    eax, eax
    jz      4f
    mov     rdi, rbx
    call    tab_switch
    test    eax, eax
    jnz     .Lto_none
    SETMSG  "Already open"
    call    recent_add
    xor     eax, eax
    jmp     .Lto_ret
4:  inc     rbx
    jmp     3b
5:  mov     rbx, [rip+tab_cur]          # the tab to go back to
    xor     r12d, r12d                  # 1: a new tab
    call    doc_pristine
    test    eax, eax
    jnz     6f
    call    tab_new
    test    eax, eax
    jnz     .Lto_none
    mov     r12d, 1
6:  lea     rsi, [rip+open_req]
    lea     rdi, [rip+fname]
    xor     ecx, ecx
7:  mov     al, [rsi+rcx]
    mov     [rdi+rcx], al
    test    al, al
    jz      8f
    inc     ecx
    jmp     7b
8:  mov     [rip+fname_len], rcx
    call    doc_load
    push    rax
    xor     eax, eax
    mov     [rip+scroll_y], rax
    mov     [rip+scroll_x], rax
    mov     qword ptr [rip+follow], 1
    mov     dword ptr [rip+dirty], 1
    pop     rax
    cmp     eax, -1
    jne     .Lto_ret
    test    r12d, r12d
    jz      .Lto_ret
    mov     rdi, rbx                    # (the message stays)
    call    tab_drop
    mov     eax, -1
    jmp     .Lto_ret
.Lto_none:
    mov     eax, -2
.Lto_ret:
    pop     r12
    pop     rbx
    ret

.section .note.GNU-stack,"",@progbits
