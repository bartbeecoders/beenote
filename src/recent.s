# =============================================================================
#  BeeNote - the recent files: the last RECENT_N documents opened or saved,
#  newest first, kept in ~/.local/state/beenote/recent (one absolute path a
#  line). The File menu lists them between Save As and Quit: rc_menu writes
#  those items into view.s's mi_file.
#
#  The file is read again before every change, so BeeNote windows running
#  side by side keep one list; it is replaced in one step (rename).
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "beenote.inc"

.globl recent_init
.globl recent_add
.globl recent_path
.globl recent_forget
.globl recent_clear

.equ SYS_GETCWD,    79
.equ SYS_RENAME,    82
.equ SYS_MKDIR,     83
.equ LBL_SZ,        64                  # a menu label or folder, with its 0
.equ NAME_MAX_B,    40                  # the file name shown, in bytes
.equ DIR_MAX_B,     36                  # its folder, in bytes
.equ RC_BUF,        (RECENT_N+1)*FNAME_MAX

.section .bss
.align 8
rc_n:           .skip 8
rc_path:        .skip RECENT_N*FNAME_MAX
rc_lbl:         .skip RECENT_N*LBL_SZ   # "1 notes.txt"
rc_dir:         .skip RECENT_N*LBL_SZ   # "~/docs"
rc_abs:         .skip FNAME_MAX         # the path being added or forgotten
rc_fold:        .skip FNAME_MAX         # a folder, before it is shortened
rc_file:        .skip 512
rc_new:         .skip 512
rc_mk:          .skip 512
rc_buf:         .skip RC_BUF

.section .rodata
s_rc_home:      .asciz "HOME="
s_rc_rel:       .asciz "/.local/state/beenote/recent"
s_rc_new:       .asciz "/.local/state/beenote/recent.new"
s_rc_dirs:      .asciz "/.local"        # made one by one (mkdir -p)
                .asciz "/.local/state"
                .asciz "/.local/state/beenote"
                .byte 0
.align 8
rc_menu_end:                            # after the recent files ...
    SEP
    ITEM "Clear Recent Files", "", CMD_RCLEAR, 0
    SEP
rc_quit:                                # ... and always last
    ITEM "Quit", "Ctrl+Q", CMD_QUIT, 0

.text

# recent_init - the list as saved, into the File menu
recent_init:
    lea     rdi, [rip+rc_file]
    lea     rsi, [rip+s_rc_rel]
    call    home_path
    lea     rdi, [rip+rc_new]
    lea     rsi, [rip+s_rc_new]
    call    home_path
    call    rc_read
    jmp     rc_menu

# recent_add - [fname] was opened or saved: it goes to the top of the list
recent_add:
    push    rbx
    lea     rdi, [rip+rc_abs]
    lea     rsi, [rip+fname]
    cmp     byte ptr [rsi], '/'
    je      3f
    mov     eax, SYS_GETCWD             # a relative name: after the working folder
    mov     esi, FNAME_MAX
    call    plat_sys
    test    rax, rax
    js      9f
    lea     rdi, [rip+rc_abs]
    call    str_len
    lea     rdi, [rip+rc_abs]
    add     rdi, rax
    cmp     rax, 1                      # (the root: no second '/')
    je      1f
    mov     byte ptr [rdi], '/'
    inc     rdi
1:  lea     rsi, [rip+fname]
    cmp     word ptr [rsi], 0x2f2e      # "./"
    jne     3f
    add     rsi, 2
3:  lea     rax, [rip+rc_abs+FNAME_MAX-1]
4:  cmp     rdi, rax
    jae     9f                          # (too long to list)
    mov     cl, [rsi]
    mov     [rdi], cl
    inc     rsi
    inc     rdi
    test    cl, cl
    jnz     4b
    call    rc_read                     # (another window may have changed it)
    lea     rdi, [rip+rc_abs]
    call    rc_find
    test    rax, rax
    js      5f
    mov     rdi, rax                    # listed already: it moves up
    call    rc_drop
5:  cmp     qword ptr [rip+rc_n], RECENT_N
    jb      6f
    dec     qword ptr [rip+rc_n]        # full: the oldest goes
6:  lea     rsi, [rip+rc_path]          # every path one slot down ...
    lea     rdi, [rsi+FNAME_MAX]
    imul    rdx, [rip+rc_n], FNAME_MAX
    call    memmove
    lea     rsi, [rip+rc_abs]           # ... and this one first
    lea     rdi, [rip+rc_path]
    mov     ecx, FNAME_MAX
    rep     movsb
    inc     qword ptr [rip+rc_n]
    call    rc_write
    call    rc_menu
9:  pop     rbx
    ret

# recent_path(edi=index) -> rax = that recent file's path, or 0
recent_path:
    mov     edi, edi
    xor     eax, eax
    cmp     rdi, [rip+rc_n]
    jae     9f
    imul    rax, rdi, FNAME_MAX
    lea     rcx, [rip+rc_path]
    add     rax, rcx
9:  ret

# recent_forget(edi=index) - take a file that no longer opens off the list
recent_forget:
    call    recent_path
    test    rax, rax
    jz      9f
    mov     rsi, rax
    lea     rdi, [rip+rc_abs]
    mov     ecx, FNAME_MAX
    rep     movsb
    call    rc_read                     # (by name: the list may have changed)
    lea     rdi, [rip+rc_abs]
    call    rc_find
    test    rax, rax
    js      8f
    mov     rdi, rax
    call    rc_drop
    call    rc_write
8:  jmp     rc_menu
9:  ret

recent_clear:
    mov     qword ptr [rip+rc_n], 0
    call    rc_write
    jmp     rc_menu

# rc_read - the saved list -> rc_path, rc_n (lines that are not absolute
#   paths are skipped; an absent file is an empty list)
rc_read:
    push    rbx
    push    r12
    mov     qword ptr [rip+rc_n], 0
    mov     eax, 2                      # open
    lea     rdi, [rip+rc_file]
    mov     esi, 0x80000                # O_RDONLY | O_CLOEXEC
    xor     edx, edx
    call    plat_sys
    test    rax, rax
    js      9f
    mov     rbx, rax
    xor     r12d, r12d                  # bytes read
1:  mov     edx, RC_BUF-1
    sub     rdx, r12
    jz      2f
    xor     eax, eax                    # read
    mov     rdi, rbx
    lea     rsi, [rip+rc_buf]
    add     rsi, r12
    call    plat_sys
    cmp     rax, -4
    je      1b
    test    rax, rax
    jle     2f
    add     r12, rax
    jmp     1b
2:  mov     eax, SYS_CLOSE
    mov     rdi, rbx
    call    plat_sys
    lea     rsi, [rip+rc_buf]
    lea     r8, [rsi+r12]               # the end, ...
    mov     byte ptr [r8], 10           # ... where the last line ends too
3:  cmp     rsi, r8
    jae     9f
    cmp     qword ptr [rip+rc_n], RECENT_N
    jae     9f
    mov     rdi, rsi
4:  cmp     byte ptr [rdi], 10
    je      5f
    inc     rdi
    jmp     4b
5:  mov     rcx, rdi
    sub     rcx, rsi                    # the line's length
    lea     rdx, [rdi+1]                # the next line
    cmp     byte ptr [rsi], '/'
    jne     6f
    cmp     rcx, FNAME_MAX-1
    jae     6f
    imul    rdi, [rip+rc_n], FNAME_MAX
    lea     rax, [rip+rc_path]
    add     rdi, rax
    rep     movsb
    mov     byte ptr [rdi], 0
    inc     qword ptr [rip+rc_n]
6:  mov     rsi, rdx
    jmp     3b
9:  pop     r12
    pop     rbx
    ret

# rc_write - rc_path -> the file (through recent.new, then a rename)
rc_write:
    push    rbx
    push    r12
    lea     r12, [rip+s_rc_dirs]        # its folders first
1:  cmp     byte ptr [r12], 0
    je      2f
    lea     rdi, [rip+rc_mk]
    mov     rsi, r12
    call    home_path
    mov     eax, SYS_MKDIR
    lea     rdi, [rip+rc_mk]
    mov     esi, 0755
    call    plat_sys                             # (EEXIST is fine)
    mov     rdi, r12
    call    str_len
    lea     r12, [r12+rax+1]
    jmp     1b
2:  lea     rdi, [rip+rc_buf]           # the lines
    xor     ebx, ebx
3:  cmp     rbx, [rip+rc_n]
    jae     5f
    imul    rsi, rbx, FNAME_MAX
    lea     rax, [rip+rc_path]
    add     rsi, rax
4:  lodsb
    test    al, al
    jz      41f
    stosb
    jmp     4b
41: mov     al, 10
    stosb
    inc     rbx
    jmp     3b
5:  lea     rax, [rip+rc_buf]
    sub     rdi, rax
    mov     r12, rdi                    # their length
    mov     eax, 2                      # open
    lea     rdi, [rip+rc_new]
    mov     esi, 0x241 | 0x80000        # O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC
    mov     edx, 0600
    call    plat_sys
    test    rax, rax
    js      9f
    mov     rbx, rax
    mov     rdi, rax
    lea     rsi, [rip+rc_buf]
    mov     rdx, r12
    call    write_all
    mov     r12, rax
    mov     eax, SYS_CLOSE
    mov     rdi, rbx
    call    plat_sys
    test    r12, r12
    js      9f
    test    rax, rax
    js      9f
    mov     eax, SYS_RENAME             # a reader never sees half a list
    lea     rdi, [rip+rc_new]
    lea     rsi, [rip+rc_file]
    call    plat_sys
9:  pop     r12
    pop     rbx
    ret

# rc_find(rdi=path) -> rax = its index in the list, or -1
rc_find:
    push    rbx
    push    r12
    mov     r12, rdi
    xor     ebx, ebx
1:  cmp     rbx, [rip+rc_n]
    jae     8f
    imul    rsi, rbx, FNAME_MAX
    lea     rax, [rip+rc_path]
    add     rsi, rax
    mov     rdi, r12
    call    str_eq
    test    eax, eax
    jnz     9f
    inc     rbx
    jmp     1b
8:  mov     rbx, -1
9:  mov     rax, rbx
    pop     r12
    pop     rbx
    ret

# rc_drop(rdi=index) - remove that entry; the ones after it move up
rc_drop:
    mov     rax, [rip+rc_n]
    dec     rax
    mov     [rip+rc_n], rax
    sub     rax, rdi
    imul    rdx, rax, FNAME_MAX
    imul    rdi, rdi, FNAME_MAX
    lea     rcx, [rip+rc_path]
    add     rdi, rcx
    lea     rsi, [rdi+FNAME_MAX]
    jmp     memmove

# rc_head(rdi=dest, rsi=text, rdx=length, ecx=most bytes) - copy the start,
#   cut at a character's boundary and ended with "…" if it is longer; 0-ended
rc_head:
    cmp     rdx, rcx
    jbe     2f
    mov     rdx, rcx
1:  test    rdx, rdx                    # not inside a UTF-8 sequence
    jz      11f
    mov     al, [rsi+rdx]
    and     al, 0xc0
    cmp     al, 0x80
    jne     11f
    dec     rdx
    jmp     1b
11: mov     rcx, rdx
    rep     movsb
    mov     dword ptr [rdi], 0x00a680e2 # "…", 0
    ret
2:  mov     rcx, rdx
    rep     movsb
    mov     byte ptr [rdi], 0
    ret

# rc_tail(rdi=dest, rsi=text, rdx=length, ecx=most bytes) - the same for
#   the end: "…" and the last bytes
rc_tail:
    cmp     rdx, rcx
    jbe     2f
    mov     dword ptr [rdi], 0x00a680e2 # "…"
    add     rdi, 3
    add     rsi, rdx
    sub     rsi, rcx
    mov     rdx, rcx
1:  test    rdx, rdx                    # from a character's first byte
    jz      2f
    mov     al, [rsi]
    and     al, 0xc0
    cmp     al, 0x80
    jne     2f
    inc     rsi
    dec     rdx
    jmp     1b
2:  mov     rcx, rdx
    rep     movsb
    mov     byte ptr [rdi], 0
    ret

# rc_menu - the File menu's items after Save As: "1 name" with its folder
#   (where the shortcut goes), Clear Recent Files, then Quit
rc_menu:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
    lea     rdi, [rip+s_rc_home]
    call    getenv
    mov     r15, rax                    # $HOME, or 0
    lea     r14, [rip+mi_file_var]      # the next item
    xor     ebx, ebx
1:  cmp     rbx, [rip+rc_n]
    jae     5f
    imul    r12, rbx, FNAME_MAX
    lea     rax, [rip+rc_path]
    add     r12, rax                    # the path
    mov     rdi, r12
    call    str_len
    lea     r13, [r12+rax]              # its end
    mov     rbp, r13                    # the name: after the last '/'
2:  cmp     byte ptr [rbp-1], '/'
    je      3f
    dec     rbp
    jmp     2b
3:  imul    rdi, rbx, LBL_SZ            # the label: its number, the name
    lea     rax, [rip+rc_lbl]
    add     rdi, rax
    mov     [r14], rdi
    lea     eax, [rbx+1]
    cmp     eax, 10
    jb      31f
    mov     byte ptr [rdi], '1'
    inc     rdi
    sub     eax, 10
31: add     al, '0'
    stosb
    mov     al, ' '
    stosb
    mov     rsi, rbp
    mov     rdx, r13
    sub     rdx, rbp
    mov     ecx, NAME_MAX_B
    call    rc_head
    xor     eax, eax                    # the mnemonic: the number's last digit
    cmp     rbx, 9
    sete    al
    mov     [r14+20], eax
    lea     rdi, [rip+rc_fold]          # the folder, ~ for $HOME
    mov     rsi, r12
    lea     rdx, [rbp-1]                # (its end: the last '/')
    cmp     rdx, r12
    jne     32f
    inc     rdx                         # (the root: "/")
32: test    r15, r15
    jz      34f
    xor     ecx, ecx
33: mov     al, [r15+rcx]
    test    al, al
    jz      331f
    cmp     al, [r12+rcx]
    jne     34f
    inc     rcx
    jmp     33b
331: test   rcx, rcx
    jz      34f
    lea     rax, [r12+rcx]
    cmp     rax, rdx
    ja      34f
    je      332f                        # (the home folder itself: "~")
    cmp     byte ptr [rax], '/'
    jne     34f
332: mov    byte ptr [rdi], '~'
    inc     rdi
    mov     rsi, rax
34: mov     rcx, rdx
    sub     rcx, rsi
    rep     movsb
    lea     rsi, [rip+rc_fold]
    mov     rdx, rdi
    sub     rdx, rsi
    imul    rdi, rbx, LBL_SZ
    lea     rax, [rip+rc_dir]
    add     rdi, rax
    mov     [r14+8], rdi
    mov     ecx, DIR_MAX_B
    call    rc_tail
    lea     eax, [rbx+CMD_RECENT]
    mov     [r14+16], eax
    mov     qword ptr [r14+24], 0       # (flags)
    add     r14, MI_SZ
    inc     rbx
    jmp     1b
5:  test    rbx, rbx
    jz      6f
    lea     rsi, [rip+rc_menu_end]      # a separator, Clear Recent Files, a separator
    mov     rdi, r14
    mov     ecx, 3*MI_SZ
    rep     movsb
    mov     r14, rdi
6:  lea     rsi, [rip+rc_quit]
    mov     rdi, r14
    mov     ecx, MI_SZ
    rep     movsb
    lea     rax, [rip+mi_file]
    sub     rdi, rax
    shr     rdi, 5                      # / MI_SZ
    mov     [rip+menu_tab+24], rdi      # the File menu's item count
    mov     dword ptr [rip+dirty], 1
    add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

.section .note.GNU-stack,"",@progbits
