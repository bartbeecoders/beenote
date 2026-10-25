# =============================================================================
#  BeeNote - the Open dialog: a folder's contents (folders first, then files
#  with their sizes), a filter typed at the top (or a path, with '/' or '~'),
#  keyboard and mouse navigation. Drawn in the Omarchy theme like the rest.
#
#  filedlg_run runs it modally (pump); on Open the chosen path is in fname.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "beenote.inc"

.globl filedlg_run
.globl fd_open
.globl draw_filedlg
.globl fd_key
.globl fd_button
.globl fd_wheel

.equ FD_MAX,        16384               # entries in a folder
.equ POOL_MAX,      1048576             # their names
.equ ENT_SZ,        16                  # name offset:4, length:2, flags:2, size:8
.equ F_DIR,         1
.equ F_PARENT,      2                   # the ".." entry
.equ SYS_GETCWD,    79
.equ SYS_GETDENTS64, 217
.equ SYS_NEWFSTATAT, 262
.equ SYS_STAT,      4
.equ FILTER_MAX,    1000

.section .bss
.align 8
fd_open:        .skip 8
fd_result:      .skip 8                 # -1 running, 0 cancelled, 1 a file chosen
fd_dirlen:      .skip 8
fd_n:           .skip 8                 # entries
fd_vn:          .skip 8                 # entries shown (the filter's)
fd_sel:         .skip 8                 # index into fd_vis
fd_top:         .skip 8                 # first row shown
fd_hidden:      .skip 8                 # 1: files starting with '.' too
fd_err:         .skip 8                 # 1: the folder could not be read
fd_flen:        .skip 8
fd_poollen:     .skip 8
fd_restore_len: .skip 8                 # after "up": select the folder we left
fd_click_t:     .skip 8
fd_click_i:     .skip 8
fd_x:           .skip 8                 # geometry of the last frame
fd_y:           .skip 8
fd_w:           .skip 8
fd_h:           .skip 8
fd_list_x:      .skip 8
fd_list_y:      .skip 8
fd_list_w:      .skip 8
fd_rows:        .skip 8
fd_rh:          .skip 8
fd_by:          .skip 8
fd_bh:          .skip 8
fd_bx:          .skip 16                # Open, Cancel
fd_bw:          .skip 16
fd_fmt_len:     .skip 8
fd_dir:         .skip FNAME_MAX
fd_tmp:         .skip FNAME_MAX
fd_filter:      .skip FILTER_MAX+8
fd_restore:     .skip 256
fd_fmt:         .skip 64
fd_stat:        .skip 144
.align 16
fd_ent:         .skip FD_MAX*ENT_SZ
fd_vis:         .skip FD_MAX*4
fd_dbuf:        .skip 32768
fd_pool:        .skip POOL_MAX

.section .rodata
s_title:        .asciz "Open file"
s_open:         .asciz "Open"
s_cancel:       .asciz "Cancel"
s_hint:         .asciz "Enter open   Backspace up   Ctrl+H hidden files"
s_place:        .asciz "Type to filter, or a path"
s_cannot:       .asciz "Cannot read this folder"
s_nomatch:      .asciz "Nothing matches"
s_dotdot:       .asciz ".."
s_ell:          .ascii "\342\200\246"   # …
s_home:         .asciz "HOME="

.text

# ---- small helpers -------------------------------------------------------------
# text_z(rdi=asciz, edx=x, ecx=centre y, r8d=colour) -> eax = x after
text_z:
    push    rdi
    push    rdx
    push    rcx
    push    r8
    call    str_len
    mov     rsi, rax
    pop     r8
    pop     rcx
    pop     rdx
    pop     rdi
    jmp     ui_text
width_z:                                # (rdi=asciz) -> eax
    push    rdi
    call    str_len
    mov     rsi, rax
    pop     rdi
    jmp     ui_text_w

ent_addr:                               # rdi = visible index -> rax = its entry
    lea     rax, [rip+fd_vis]
    mov     eax, [rax+rdi*4]
    shl     rax, 4
    lea     rcx, [rip+fd_ent]
    add     rax, rcx
    ret

ent_name:                               # rdi = entry -> rsi = name, rdx = length
    mov     esi, [rdi]
    lea     rax, [rip+fd_pool]
    add     rsi, rax
    movzx   edx, word ptr [rdi+4]
    ret

lower:                                  # al -> al in lower case (ASCII)
    cmp     al, 'A'
    jb      1f
    cmp     al, 'Z'
    ja      1f
    or      al, 0x20
1:  ret

# filter_is_path -> eax = 1 when the filter is a path ('/' in it, or '~...')
filter_is_path:
    lea     rdi, [rip+fd_filter]        # (C:\x -> /C:/x on Windows)
    lea     rsi, [rip+fd_flen]
    mov     edx, FILTER_MAX
    call    plat_path_in
    xor     eax, eax
    mov     rcx, [rip+fd_flen]
    test    rcx, rcx
    jz      9f
    lea     rdx, [rip+fd_filter]
    cmp     byte ptr [rdx], '~'
    je      8f
1:  dec     rcx
    js      9f
    cmp     byte ptr [rdx+rcx], '/'
    jne     1b
8:  mov     eax, 1
9:  ret

# ---- the folder -------------------------------------------------------------------
# sort the entries from rdi on (insertion into place with a shell-sort gap)
sort_ents:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 24
    mov     r15, rdi                    # first index sorted
    mov     rbp, [rip+fd_n]
    sub     rbp, r15                    # count
    lea     rbx, [rip+fd_ent]
    mov     rax, r15
    shl     rax, 4
    add     rbx, rax                    # base
    mov     r12, rbp                    # gap
1:  shr     r12, 1
    jz      9f
    mov     r13, r12                    # i
2:  cmp     r13, rbp
    jae     1b
    mov     rax, r13                    # tmp = a[i]
    shl     rax, 4
    movdqu  xmm0, [rbx+rax]
    movdqu  [rsp], xmm0
    mov     r14, r13                    # j
3:  cmp     r14, r12
    jb      4f
    mov     rax, r14
    sub     rax, r12
    shl     rax, 4
    lea     rdi, [rbx+rax]              # a[j-gap] after tmp?
    mov     rsi, rsp
    call    cmp_ent_full
    cmp     eax, 0
    jle     4f
    mov     rax, r14
    sub     rax, r12
    shl     rax, 4
    movdqu  xmm0, [rbx+rax]
    mov     rcx, r14
    shl     rcx, 4
    movdqu  [rbx+rcx], xmm0
    sub     r14, r12
    jmp     3b
4:  movdqu  xmm0, [rsp]
    mov     rcx, r14
    shl     rcx, 4
    movdqu  [rbx+rcx], xmm0
    inc     r13
    jmp     2b
9:  add     rsp, 24
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

# cmp_ent_full(rdi=a, rsi=b) -> eax: > 0 when a must go after b
cmp_ent_full:
    movzx   eax, word ptr [rdi+6]
    movzx   ecx, word ptr [rsi+6]
    and     eax, F_DIR
    and     ecx, F_DIR
    cmp     eax, ecx
    je      1f
    sub     ecx, eax                    # a folder (1) before a file (0)
    mov     eax, ecx
    ret
1:  push    rbx
    push    r12
    push    r13
    mov     r8d, [rdi]
    movzx   r9d, word ptr [rdi+4]
    mov     r10d, [rsi]
    movzx   r11d, word ptr [rsi+4]
    lea     rbx, [rip+fd_pool]
    add     r8, rbx
    add     r10, rbx
    xor     ecx, ecx
2:  cmp     ecx, r9d
    jae     4f
    cmp     ecx, r11d
    jae     5f
    mov     al, [r8+rcx]
    call    lower
    mov     r12b, al
    mov     al, [r10+rcx]
    call    lower
    cmp     r12b, al
    jne     3f
    inc     ecx
    jmp     2b
3:  movzx   r13d, al
    movzx   eax, r12b
    sub     eax, r13d
    jmp     9f
4:  mov     eax, r9d                    # all of a matched: shorter first
    sub     eax, r11d
    jmp     9f
5:  mov     eax, 1
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# add_ent(rsi=name, edx=length, ecx=flags, r8=size) - into the list
add_ent:
    mov     rax, [rip+fd_n]
    cmp     rax, FD_MAX
    jae     9f
    mov     r9, [rip+fd_poollen]
    lea     r10, [r9+rdx+1]
    cmp     r10, POOL_MAX
    ja      9f
    shl     rax, 4
    lea     r11, [rip+fd_ent]
    add     r11, rax
    mov     [r11], r9d
    mov     [r11+4], dx
    mov     [r11+6], cx
    mov     [r11+8], r8
    lea     rdi, [rip+fd_pool]
    add     rdi, r9
    mov     ecx, edx
    rep     movsb
    mov     byte ptr [rdi], 0
    mov     [rip+fd_poollen], r10
    inc     qword ptr [rip+fd_n]
9:  ret

# fd_load - read fd_dir into the list
fd_load:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    xor     eax, eax
    mov     [rip+fd_n], rax
    mov     [rip+fd_poollen], rax
    mov     [rip+fd_err], rax
    mov     eax, 2                      # open(dir, O_RDONLY|O_DIRECTORY|O_CLOEXEC)
    lea     rdi, [rip+fd_dir]
    mov     esi, 0x90000
    xor     edx, edx
    call    plat_sys
    test    rax, rax
    jns     1f
    mov     qword ptr [rip+fd_err], 1
1:  mov     rbx, rax                    # fd (or the error)
    cmp     qword ptr [rip+fd_dirlen], 1    # not "/": a ".." first
    jbe     2f
    lea     rsi, [rip+s_dotdot]
    mov     edx, 2
    mov     ecx, F_DIR | F_PARENT
    xor     r8d, r8d
    call    add_ent
2:  test    rbx, rbx
    js      .Lfl_sort
.Lfl_read:
    mov     eax, SYS_GETDENTS64
    mov     rdi, rbx
    lea     rsi, [rip+fd_dbuf]
    mov     edx, 32768
    call    plat_sys
    test    rax, rax
    jle     .Lfl_close
    lea     r12, [rip+fd_dbuf]
    lea     r13, [r12+rax]
.Lfl_ent:
    cmp     r12, r13
    jae     .Lfl_read
    lea     r14, [r12+19]               # name
    cmp     byte ptr [r14], '.'
    jne     3f
    cmp     byte ptr [r14+1], 0         # "." and ".." never
    je      .Lfl_next
    cmp     word ptr [r14+1], '.'
    je      .Lfl_next
    cmp     qword ptr [rip+fd_hidden], 0
    je      .Lfl_next
3:  mov     eax, SYS_NEWFSTATAT         # type and size (links followed)
    mov     rdi, rbx
    mov     rsi, r14
    lea     rdx, [rip+fd_stat]
    xor     r10d, r10d
    call    plat_sys
    xor     ecx, ecx
    xor     r8d, r8d
    test    rax, rax
    jnz     4f                          # (a broken link: a file, no size)
    mov     eax, [rip+fd_stat+24]       # st_mode
    and     eax, 0xF000
    cmp     eax, 0x4000
    jne     31f
    mov     ecx, F_DIR
    jmp     4f
31: mov     r8, [rip+fd_stat+48]        # st_size
4:  push    rcx
    push    r8
    mov     rdi, r14
    call    str_len
    mov     edx, eax
    pop     r8
    pop     rcx
    mov     rsi, r14
    call    add_ent
.Lfl_next:
    movzx   eax, word ptr [r12+16]      # d_reclen
    add     r12, rax
    jmp     .Lfl_ent
.Lfl_close:
    mov     eax, SYS_CLOSE
    mov     rdi, rbx
    call    plat_sys
.Lfl_sort:
    xor     edi, edi                    # (the ".." stays first)
    cmp     qword ptr [rip+fd_dirlen], 1
    jbe     5f
    mov     edi, 1
5:  call    sort_ents
    call    fd_filter_apply
    cmp     qword ptr [rip+fd_restore_len], 0   # back up: the folder we came from
    je      9f
    xor     r15d, r15d
6:  cmp     r15, [rip+fd_vn]
    jae     8f
    mov     rdi, r15
    call    ent_addr
    mov     rdi, rax
    call    ent_name
    cmp     rdx, [rip+fd_restore_len]
    jne     7f
    lea     rdi, [rip+fd_restore]
    mov     rcx, rdx
    repe    cmpsb
    jne     7f
    mov     [rip+fd_sel], r15
    call    fd_show_sel
    jmp     8f
7:  inc     r15
    jmp     6b
8:  mov     qword ptr [rip+fd_restore_len], 0
9:  mov     dword ptr [rip+dirty], 1
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# fd_filter_apply - the entries whose name contains the filter
fd_filter_apply:
    push    rbx
    push    r12
    push    r13
    xor     r12d, r12d                  # shown
    xor     ebx, ebx                    # entry
    call    filter_is_path
    mov     r13d, eax                   # a path: everything shown
1:  cmp     rbx, [rip+fd_n]
    jae     8f
    cmp     qword ptr [rip+fd_flen], 0
    je      5f
    test    r13d, r13d
    jnz     5f
    mov     rdi, rbx
    shl     rdi, 4
    lea     rax, [rip+fd_ent]
    add     rdi, rax
    test    word ptr [rdi+6], F_PARENT  # (".." only while not filtering)
    jnz     6f
    call    ent_name
    call    contains
    test    eax, eax
    jz      6f
5:  lea     rax, [rip+fd_vis]
    mov     [rax+r12*4], ebx
    inc     r12
6:  inc     rbx
    jmp     1b
8:  mov     [rip+fd_vn], r12
    xor     eax, eax
    mov     [rip+fd_top], rax
    mov     [rip+fd_sel], rax
    cmp     r12, 1                      # start past the "..", on the first entry
    jbe     9f
    mov     eax, [rip+fd_vis]
    shl     rax, 4
    lea     rcx, [rip+fd_ent]
    test    word ptr [rcx+rax+6], F_PARENT
    jz      9f
    mov     qword ptr [rip+fd_sel], 1
9:  mov     dword ptr [rip+dirty], 1
    pop     r13
    pop     r12
    pop     rbx
    ret

# contains(rsi=name, rdx=length) -> eax = 1 when the filter is in it (any case)
contains:
    push    rbx
    push    r12
    mov     r8, [rip+fd_flen]
    lea     r9, [rip+fd_filter]
    xor     r10d, r10d                  # start
1:  lea     rax, [r10+r8]
    cmp     rax, rdx
    ja      8f
    xor     ecx, ecx
2:  cmp     rcx, r8
    jae     7f
    lea     rbx, [r10+rcx]
    mov     al, [rsi+rbx]
    call    lower
    mov     r12b, al
    mov     al, [r9+rcx]
    call    lower
    cmp     al, r12b
    jne     3f
    inc     rcx
    jmp     2b
3:  inc     r10
    jmp     1b
7:  mov     eax, 1
    jmp     9f
8:  xor     eax, eax
9:  pop     r12
    pop     rbx
    ret

fd_show_sel:                            # the selection within the rows shown
    mov     rax, [rip+fd_sel]
    cmp     rax, [rip+fd_top]
    jge     1f
    mov     [rip+fd_top], rax
1:  mov     rcx, [rip+fd_rows]
    test    rcx, rcx
    jz      2f
    mov     rdx, [rip+fd_top]
    add     rdx, rcx
    cmp     rax, rdx
    jl      2f
    sub     rax, rcx
    inc     rax
    mov     [rip+fd_top], rax
2:  mov     dword ptr [rip+dirty], 1
    ret

# ---- moving around ----------------------------------------------------------------
dir_add:                                # (rsi=name, rdx=length) fd_dir/name
    mov     rax, [rip+fd_dirlen]
    lea     rcx, [rax+rdx+2]
    cmp     rcx, FNAME_MAX
    jae     9f
    lea     rdi, [rip+fd_dir]
    add     rdi, rax
    cmp     rax, 1                      # (no second '/' after the root)
    jne     1f
    cmp     byte ptr [rip+fd_dir], '/'
    je      2f
1:  mov     byte ptr [rdi], '/'
    inc     rdi
    inc     qword ptr [rip+fd_dirlen]
2:  mov     rcx, rdx
    add     [rip+fd_dirlen], rdx
    rep     movsb
    mov     byte ptr [rdi], 0
9:  ret

fd_up:                                  # to the parent folder (selecting this one)
    mov     rcx, [rip+fd_dirlen]
    cmp     rcx, 1
    jbe     9f
    lea     rsi, [rip+fd_dir]
1:  dec     rcx
    cmp     byte ptr [rsi+rcx], '/'
    jne     1b
    lea     rdx, [rcx+1]                # the name we leave: to select it again
    mov     rax, [rip+fd_dirlen]
    sub     rax, rdx
    cmp     rax, 255
    ja      2f
    mov     [rip+fd_restore_len], rax
    push    rcx
    lea     rdi, [rip+fd_restore]
    lea     rsi, [rsi+rdx]
    mov     rcx, rax
    rep     movsb
    pop     rcx
2:  test    rcx, rcx                    # "/x" -> "/"
    jnz     3f
    inc     rcx
3:  mov     [rip+fd_dirlen], rcx
    lea     rax, [rip+fd_dir]
    mov     byte ptr [rax+rcx], 0
    mov     qword ptr [rip+fd_flen], 0
    jmp     fd_load
9:  ret

# fd_choose(rsi=name, rdx=length) - fd_dir/name is the file to open
fd_choose:
    push    rsi
    push    rdx
    lea     rsi, [rip+fd_dir]           # fname = fd_dir
    lea     rdi, [rip+fname]
    mov     rcx, [rip+fd_dirlen]
    mov     [rip+fname_len], rcx
    rep     movsb
    pop     rdx
    pop     rsi
    mov     rax, [rip+fname_len]
    lea     rcx, [rax+rdx+2]
    cmp     rcx, FNAME_MAX
    jae     9f
    cmp     rax, 1                      # '/' unless at the root
    jne     1f
    cmp     byte ptr [rip+fname], '/'
    je      2f
1:  mov     byte ptr [rdi], '/'
    inc     rdi
    inc     qword ptr [rip+fname_len]
2:  mov     rcx, rdx
    add     [rip+fname_len], rdx
    rep     movsb
    mov     byte ptr [rdi], 0
    mov     qword ptr [rip+fd_result], 1
9:  ret

# fd_activate - Enter / a double click on the selection
fd_activate:
    cmp     qword ptr [rip+fd_vn], 0
    je      9f
    mov     rdi, [rip+fd_sel]
    call    ent_addr
    mov     rdi, rax
    test    word ptr [rdi+6], F_PARENT
    jnz     fd_up
    test    word ptr [rdi+6], F_DIR
    jnz     1f
    call    ent_name
    jmp     fd_choose
1:  call    ent_name
    call    dir_add
    mov     qword ptr [rip+fd_flen], 0
    jmp     fd_load
9:  ret

# fd_typed_path - the filter is a path: a folder to go to, or a file (new or
#   not) to open
fd_typed_path:
    push    rbx
    lea     rdi, [rip+fd_tmp]           # build it: ~ -> $HOME, relative -> fd_dir/
    lea     rsi, [rip+fd_filter]
    mov     rcx, [rip+fd_flen]
    cmp     byte ptr [rsi], '/'
    je      3f
    cmp     byte ptr [rsi], '~'
    jne     2f
    push    rsi
    push    rcx
    push    rdi
    lea     rdi, [rip+s_home]
    call    getenv
    pop     rdi
    pop     rcx
    pop     rsi
    test    rax, rax
    jz      2f
1:  mov     dl, [rax]                   # $HOME
    test    dl, dl
    jz      11f
    mov     [rdi], dl
    inc     rdi
    inc     rax
    jmp     1b
11: inc     rsi                         # (past the '~')
    dec     rcx
    jmp     3f
2:  push    rsi                         # fd_dir/
    push    rcx
    lea     rsi, [rip+fd_dir]
    mov     rcx, [rip+fd_dirlen]
    rep     movsb
    mov     byte ptr [rdi], '/'
    inc     rdi
    pop     rcx
    pop     rsi
3:  rep     movsb
    mov     byte ptr [rdi], 0
    lea     rbx, [rip+fd_tmp]
    sub     rdi, rbx                    # (its length)
4:  cmp     rdi, 1                      # no trailing '/'
    jbe     5f
    cmp     byte ptr [rbx+rdi-1], '/'
    jne     5f
    dec     rdi
    mov     byte ptr [rbx+rdi], 0
    jmp     4b
5:  push    rdi
    mov     eax, SYS_STAT
    mov     rdi, rbx
    lea     rsi, [rip+fd_stat]
    call    plat_sys
    pop     rcx
    test    rax, rax
    jnz     7f
    mov     eax, [rip+fd_stat+24]
    and     eax, 0xF000
    cmp     eax, 0x4000
    jne     7f
    mov     [rip+fd_dirlen], rcx        # a folder: go there
    lea     rdi, [rip+fd_dir]
    mov     rsi, rbx
    inc     rcx
    rep     movsb
    mov     qword ptr [rip+fd_flen], 0
    call    fd_load
    jmp     9f
7:  lea     rdi, [rip+fname]            # a file (or a new one): open it
    mov     rsi, rbx
    mov     [rip+fname_len], rcx
    inc     rcx
    rep     movsb
    mov     qword ptr [rip+fd_result], 1
9:  pop     rbx
    ret

# fd_start - the folder of the current file (made absolute), or the working one
fd_start:
    mov     eax, SYS_GETCWD
    lea     rdi, [rip+fd_dir]
    mov     esi, FNAME_MAX-8
    call    plat_sys
    test    rax, rax
    jg      1f
    mov     word ptr [rip+fd_dir], '/'
    mov     eax, 2
1:  dec     rax
    mov     [rip+fd_dirlen], rax
    mov     rcx, [rip+fname_len]
    test    rcx, rcx
    jz      9f
    lea     rsi, [rip+fname]
2:  test    rcx, rcx                    # the file's folder part
    jz      9f
    cmp     byte ptr [rsi+rcx-1], '/'
    je      3f
    dec     rcx
    jmp     2b
3:  dec     rcx                         # (without its '/'; "/" stays)
    jnz     4f
    inc     rcx
4:  cmp     byte ptr [rsi], '/'
    je      5f
    mov     rdx, rcx                    # relative: below the working folder
    jmp     dir_add
5:  lea     rdi, [rip+fd_dir]           # absolute
    mov     [rip+fd_dirlen], rcx
    rep     movsb
    mov     byte ptr [rdi], 0
9:  ret

# filedlg_run -> eax = 1 when a file was chosen (its path is in fname)
filedlg_run:
    mov     qword ptr [rip+fd_open], 1
    mov     qword ptr [rip+fd_result], -1
    mov     qword ptr [rip+fd_flen], 0
    mov     qword ptr [rip+fd_restore_len], 0
    mov     qword ptr [rip+fd_rows], 0
    call    fd_start
    call    fd_load
    inc     qword ptr [rip+modal]
    call    set_cursor_default
1:  cmp     qword ptr [rip+fd_result], -1
    jne     2f
    cmp     dword ptr [rip+quit_flag], 0
    jne     2f
    call    pump
    jmp     1b
2:  mov     qword ptr [rip+fd_open], 0
    dec     qword ptr [rip+modal]
    mov     dword ptr [rip+dirty], 1
    xor     eax, eax
    cmp     qword ptr [rip+fd_result], 1
    sete    al
    ret

# ---- input ------------------------------------------------------------------------
# fd_key(edi=evdev, esi=symbol, edx=mods, ecx=layout code)
fd_key:
    push    rbx
    push    r12
    push    r13
    mov     ebx, edi
    mov     r12d, esi
    mov     r13d, edx
    mov     dword ptr [rip+dirty], 1
    cmp     ebx, KEY_ESC                # Esc: the filter goes, then the dialog
    jne     1f
    cmp     qword ptr [rip+fd_flen], 0
    je      12f
    mov     qword ptr [rip+fd_flen], 0
    call    fd_filter_apply
    jmp     .Lfk_ret
12: mov     qword ptr [rip+fd_result], 0
    jmp     .Lfk_ret
1:  cmp     ebx, EK_ENTER
    je      2f
    cmp     ebx, EK_KPENTER
    jne     3f
2:  call    filter_is_path
    test    eax, eax
    jz      21f
    call    fd_typed_path
    jmp     .Lfk_ret
21: call    fd_activate
    jmp     .Lfk_ret
3:  mov     rax, [rip+fd_sel]           # moving the selection
    mov     rcx, [rip+fd_rows]
    dec     rcx
    jg      31f
    mov     ecx, 1
31: cmp     ebx, EK_UP
    jne     32f
    dec     rax
    jmp     .Lfk_sel
32: cmp     ebx, EK_DOWN
    jne     33f
    inc     rax
    jmp     .Lfk_sel
33: cmp     ebx, KEY_PAGEUP
    jne     34f
    sub     rax, rcx
    jmp     .Lfk_sel
34: cmp     ebx, KEY_PAGEDOWN
    jne     35f
    add     rax, rcx
    jmp     .Lfk_sel
35: cmp     ebx, KEY_HOME
    jne     36f
    xor     eax, eax
    jmp     .Lfk_sel
36: cmp     ebx, EK_END
    jne     4f
    mov     rax, [rip+fd_vn]
    jmp     .Lfk_sel
4:  cmp     ebx, EK_BACKSPACE           # Backspace: a character, or up
    jne     5f
    mov     rax, [rip+fd_flen]
    test    rax, rax
    jz      42f
    lea     rcx, [rip+fd_filter]
41: dec     rax
    jz      411f
    movzx   edx, byte ptr [rcx+rax]
    and     edx, 0xC0
    cmp     edx, 0x80
    je      41b
411: mov    [rip+fd_flen], rax
    call    fd_filter_apply
    jmp     .Lfk_ret
42: call    fd_up
    jmp     .Lfk_ret
5:  cmp     qword ptr [rip+fd_flen], 0  # Left: up, Right: into a folder
    jne     6f
    cmp     ebx, EK_LEFT
    jne     51f
    call    fd_up
    jmp     .Lfk_ret
51: cmp     ebx, EK_RIGHT
    jne     6f
    cmp     qword ptr [rip+fd_vn], 0
    je      .Lfk_ret
    mov     rdi, [rip+fd_sel]
    call    ent_addr
    test    word ptr [rax+6], F_DIR
    jz      .Lfk_ret
    call    fd_activate
    jmp     .Lfk_ret
6:  test    r13d, MOD_CTRL              # Ctrl+H: hidden files
    jz      7f
    cmp     ecx, 35
    jne     .Lfk_ret
    xor     qword ptr [rip+fd_hidden], 1
    call    fd_load
    jmp     .Lfk_ret
7:  test    r13d, MOD_ALT
    jnz     .Lfk_ret
    mov     esi, r12d                   # a character: into the filter
    call    typed_char
    test    eax, eax
    jz      .Lfk_ret
    mov     rcx, [rip+fd_flen]
    cmp     rcx, FILTER_MAX-4
    jae     .Lfk_ret
    mov     edi, eax
    lea     rsi, [rip+fd_filter]
    add     rsi, rcx
    call    utf8_enc
    add     [rip+fd_flen], rax
    call    fd_filter_apply
    jmp     .Lfk_ret
.Lfk_sel:
    mov     rcx, [rip+fd_vn]
    dec     rcx
    cmp     rax, rcx
    jle     1f
    mov     rax, rcx
1:  test    rax, rax
    jns     2f
    xor     eax, eax
2:  mov     [rip+fd_sel], rax
    call    fd_show_sel
.Lfk_ret:
    pop     r13
    pop     r12
    pop     rbx
    ret

# fd_button(edi=button, esi=state, edx=time; rdi.. mx, my in r8, r9)
fd_button:
    cmp     edi, BTN_LEFT
    jne     9f
    test    esi, esi
    jz      9f
    push    rbx
    mov     ebx, edx                    # time
    mov     rax, r9                     # y
    cmp     rax, [rip+fd_by]            # the buttons
    jl      3f
    mov     rcx, [rip+fd_by]
    add     rcx, [rip+fd_bh]
    cmp     rax, rcx
    jge     8f
    mov     rcx, [rip+fd_bx]
    cmp     r8, rcx
    jl      2f
    add     rcx, [rip+fd_bw]
    cmp     r8, rcx
    jge     2f
    call    open_button
    jmp     8f
2:  mov     rcx, [rip+fd_bx+8]
    cmp     r8, rcx
    jl      8f
    add     rcx, [rip+fd_bw+8]
    cmp     r8, rcx
    jge     8f
    mov     qword ptr [rip+fd_result], 0
    jmp     8f
3:  sub     rax, [rip+fd_list_y]        # a row
    js      8f
    mov     rcx, [rip+fd_list_x]
    cmp     r8, rcx
    jl      8f
    add     rcx, [rip+fd_list_w]
    cmp     r8, rcx
    jge     8f
    xor     edx, edx
    mov     rcx, [rip+fd_rh]
    test    rcx, rcx
    jz      8f
    div     rcx
    cmp     rax, [rip+fd_rows]
    jae     8f
    add     rax, [rip+fd_top]
    cmp     rax, [rip+fd_vn]
    jae     8f
    mov     ecx, ebx                    # a second click on it soon: open
    sub     rcx, [rip+fd_click_t]
    cmp     rax, [rip+fd_click_i]
    jne     4f
    cmp     rcx, 400
    ja      4f
    mov     qword ptr [rip+fd_click_i], -1
    mov     [rip+fd_sel], rax
    call    fd_activate
    jmp     8f
4:  mov     [rip+fd_sel], rax
    mov     [rip+fd_click_i], rax
    mov     [rip+fd_click_t], rbx
    mov     dword ptr [rip+dirty], 1
8:  pop     rbx
9:  ret

open_button:                            # Open: the typed path, or the selection
    call    filter_is_path
    test    eax, eax
    jnz     fd_typed_path
    jmp     fd_activate

# fd_wheel(edi=axis, esi=value 24.8) - three rows a notch
fd_wheel:
    test    edi, edi
    jnz     9f
    movsxd  rax, esi
    imul    rax, rax, 3
    cqo
    mov     ecx, 2560
    idiv    rcx
    test    rax, rax
    jnz     1f
    mov     eax, 1                      # (a touchpad's little steps: one row)
    test    esi, esi
    jns     1f
    mov     rax, -1
1:  add     rax, [rip+fd_top]
    mov     rcx, [rip+fd_vn]
    sub     rcx, [rip+fd_rows]
    cmp     rax, rcx
    jle     2f
    mov     rax, rcx
2:  test    rax, rax
    jns     3f
    xor     eax, eax
3:  mov     [rip+fd_top], rax
    mov     dword ptr [rip+dirty], 1
9:  ret

# ---- drawing ------------------------------------------------------------------------
# fmt_size(rdi=bytes) -> fd_fmt / fd_fmt_len: "12 B", "3 KB", "4.5 MB", "1.2 GB"
fmt_size:
    push    rbx
    push    r12
    mov     qword ptr [rip+fd_fmt_len], 0
    cmp     rdi, 1024
    jae     1f
    call    utoa
    call    fmt_add
    LSTR    " B"
    call    fmt_add
    jmp     9f
1:  cmp     rdi, 1048576
    jae     2f
    add     rdi, 1023                   # KB, rounded up
    shr     rdi, 10
    call    utoa
    call    fmt_add
    LSTR    " KB"
    call    fmt_add
    jmp     9f
2:  mov     ebx, 20                     # MB, or GB, with one decimal
    LSTR    " MB"
    mov     r12, rsi
    cmp     rdi, 1073741824
    jb      3f
    mov     ebx, 30
    LSTR    " GB"
    mov     r12, rsi
3:  mov     rax, rdi
    imul    rax, rax, 10
    mov     ecx, ebx
    shr     rax, cl                     # tenths
    xor     edx, edx
    mov     ecx, 10
    div     rcx
    push    rdx
    mov     rdi, rax
    call    utoa
    call    fmt_add
    LSTR    "."
    call    fmt_add
    pop     rdi
    call    utoa
    call    fmt_add
    mov     rsi, r12
    mov     edx, 3
    call    fmt_add
9:  pop     r12
    pop     rbx
    ret
fmt_add:                                # (rsi, rdx)
    mov     rax, [rip+fd_fmt_len]
    lea     rdi, [rip+fd_fmt]
    add     rdi, rax
    mov     rcx, rdx
    add     [rip+fd_fmt_len], rdx
    rep     movsb
    ret

draw_filedlg:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 24
    # size and place: up to 760 x 560, inside the window
    SP      eax, 760
    mov     ecx, [rip+fb_w]
    SP      edx, 32
    sub     ecx, edx
    cmp     eax, ecx
    jle     1f
    mov     eax, ecx
1:  mov     [rip+fd_w], rax
    SP      eax, 560
    mov     ecx, [rip+fb_h]
    sub     ecx, edx
    cmp     eax, ecx
    jle     2f
    mov     eax, ecx
2:  mov     [rip+fd_h], rax
    mov     eax, [rip+fb_w]
    sub     rax, [rip+fd_w]
    sar     rax, 1
    mov     [rip+fd_x], rax
    mov     eax, [rip+fb_h]
    sub     rax, [rip+fd_h]
    sar     rax, 1
    mov     [rip+fd_y], rax
    mov     edi, [rip+fd_x]             # the frame
    mov     esi, [rip+fd_y]
    mov     edx, [rip+fd_w]
    mov     ecx, [rip+fd_h]
    COL     r8d, C_ACCENT
    call    fill_rect_px
    mov     edi, [rip+fd_x]
    inc     edi
    mov     esi, [rip+fd_y]
    inc     esi
    mov     edx, [rip+fd_w]
    sub     edx, 2
    mov     ecx, [rip+fd_h]
    sub     ecx, 2
    COL     r8d, C_BG_DARK
    call    fill_rect_px
    SP      r12d, 20                    # r12 = padding
    mov     r13d, [rip+fd_x]
    add     r13d, r12d                  # r13 = left
    mov     r14d, [rip+fd_x]
    add     r14d, [rip+fd_w]
    sub     r14d, r12d                  # r14 = right
    mov     r15d, [rip+ui_lh]           # r15 = a text line
    # the title and, after it, the folder (its end when it is long)
    mov     ebx, [rip+fd_y]
    add     ebx, r12d
    mov     eax, r15d
    shr     eax, 1
    add     ebx, eax                    # centre of the first line
    lea     rdi, [rip+s_title]
    mov     edx, r13d
    mov     ecx, ebx
    COL     r8d, C_FG
    call    text_z
    SP      ecx, 16
    add     eax, ecx
    mov     [rsp], rax                  # where the folder starts
    mov     ebp, r14d
    sub     ebp, eax                    # room for it
    lea     rdi, [rip+fd_dir]
    mov     rsi, [rip+fd_dirlen]
    call    ui_text_w
    xor     ecx, ecx                    # bytes to skip from the start
    cmp     eax, ebp
    jle     4f
    lea     rdi, [rip+s_ell]
    mov     esi, 3
    call    ui_text_w
    sub     ebp, eax
    xor     ecx, ecx
3:  inc     rcx                         # skip characters until the rest fits
    cmp     rcx, [rip+fd_dirlen]
    jae     31f
    lea     rax, [rip+fd_dir]
    movzx   eax, byte ptr [rax+rcx]
    and     eax, 0xC0
    cmp     eax, 0x80
    je      3b
    push    rcx
    lea     rdi, [rip+fd_dir]
    add     rdi, rcx
    mov     rsi, [rip+fd_dirlen]
    sub     rsi, rcx
    call    ui_text_w
    pop     rcx
    cmp     eax, ebp
    jg      3b
31: push    rcx
    lea     rdi, [rip+s_ell]
    mov     esi, 3
    mov     edx, [rsp+8]
    mov     ecx, ebx
    COL     r8d, C_FG_DIM
    call    ui_text
    mov     [rsp+8], rax
    pop     rcx
4:  lea     rdi, [rip+fd_dir]
    add     rdi, rcx
    mov     rsi, [rip+fd_dirlen]
    sub     rsi, rcx
    mov     edx, [rsp]
    mov     ecx, ebx
    COL     r8d, C_FG_DIM
    call    ui_text
    # the filter field
    mov     eax, r15d
    shr     eax, 1
    add     ebx, eax
    SP      eax, 14
    add     ebx, eax                    # its top
    SP      ebp, 12
    add     ebp, r15d                   # its height
    mov     edi, r13d
    mov     esi, ebx
    mov     edx, r14d
    sub     edx, r13d
    mov     ecx, ebp
    COL     r8d, C_ACCENT
    call    fill_rect_px
    lea     edi, [r13+1]
    lea     esi, [rbx+1]
    mov     edx, r14d
    sub     edx, r13d
    sub     edx, 2
    lea     ecx, [rbp-2]
    COL     r8d, C_BG
    call    fill_rect_px
    lea     eax, [rbx+rbp]              # the list starts below the field
    SP      ecx, 12
    add     eax, ecx
    mov     [rip+fd_list_y], rax
    mov     ecx, ebp
    shr     ecx, 1
    add     ecx, ebx                    # its centre
    mov     [rsp+8], rcx
    SP      edx, 10
    add     edx, r13d
    cmp     qword ptr [rip+fd_flen], 0
    jne     5f
    lea     rdi, [rip+s_place]          # (empty: a hint)
    COL     r8d, C_FG_DIM
    call    text_z
    mov     eax, r13d
    SP      ecx, 10
    add     eax, ecx
    jmp     51f
5:  lea     rdi, [rip+fd_filter]
    mov     rsi, [rip+fd_flen]
    COL     r8d, C_FG
    call    ui_text
51: mov     edi, eax                    # the caret
    inc     edi
    mov     esi, [rsp+8]
    mov     eax, r15d
    shr     eax, 1
    sub     esi, eax
    SP      edx, 2
    mov     ecx, r15d
    COL     r8d, C_ACCENT
    call    fill_rect_px
    # the buttons, at the bottom
    SP      eax, 14
    add     eax, r15d
    mov     [rip+fd_bh], rax
    mov     eax, [rip+fd_y]
    add     rax, [rip+fd_h]
    sub     rax, r12
    sub     rax, [rip+fd_bh]
    mov     [rip+fd_by], rax
    lea     rdi, [rip+s_cancel]         # Cancel on the right, Open before it
    call    width_z
    SP      ecx, 36
    add     eax, ecx
    mov     [rip+fd_bw+8], rax
    mov     ecx, r14d
    sub     ecx, eax
    mov     [rip+fd_bx+8], rcx
    lea     rdi, [rip+s_open]
    call    width_z
    SP      ecx, 36
    add     eax, ecx
    mov     [rip+fd_bw], rax
    mov     rcx, [rip+fd_bx+8]
    SP      edx, 8
    sub     rcx, rdx
    sub     rcx, rax
    mov     [rip+fd_bx], rcx
    mov     edi, [rip+fd_bx]
    mov     esi, [rip+fd_by]
    mov     edx, [rip+fd_bw]
    mov     ecx, [rip+fd_bh]
    COL     r8d, C_ACCENT
    call    fill_rect_px
    mov     edi, [rip+fd_bx+8]
    mov     esi, [rip+fd_by]
    mov     edx, [rip+fd_bw+8]
    mov     ecx, [rip+fd_bh]
    COL     r8d, C_BG_LIGHT
    call    fill_rect_px
    mov     rbp, [rip+fd_bh]
    shr     rbp, 1
    add     rbp, [rip+fd_by]            # their centre line
    SP      edx, 18
    add     edx, [rip+fd_bx]
    lea     rdi, [rip+s_open]
    mov     ecx, ebp
    COL     r8d, C_BG
    call    text_z
    SP      edx, 18
    add     edx, [rip+fd_bx+8]
    lea     rdi, [rip+s_cancel]
    mov     ecx, ebp
    COL     r8d, C_FG
    call    text_z
    lea     rdi, [rip+s_hint]           # (a hint on the left)
    mov     edx, r13d
    mov     ecx, ebp
    COL     r8d, C_FG_DIM
    call    text_z
    # the list: between the field and the buttons
    mov     [rip+fd_list_x], r13
    mov     eax, r14d
    sub     eax, r13d
    mov     [rip+fd_list_w], rax
    SP      eax, 10
    add     eax, r15d
    mov     [rip+fd_rh], rax
    mov     rax, [rip+fd_by]
    SP      ecx, 12
    sub     rax, rcx
    sub     rax, [rip+fd_list_y]        # its height
    jg      6f
    mov     eax, 1
6:  xor     edx, edx
    div     qword ptr [rip+fd_rh]
    mov     [rip+fd_rows], rax
    call    fd_show_sel                 # (rows known: keep the selection shown)
    mov     edi, r13d                   # clip to the list
    mov     esi, [rip+fd_list_y]
    mov     edx, r14d
    mov     rcx, [rip+fd_rows]
    imul    rcx, [rip+fd_rh]
    add     rcx, [rip+fd_list_y]
    call    set_clip_px
    cmp     qword ptr [rip+fd_vn], 0
    jne     7f
    lea     rdi, [rip+s_nomatch]        # empty: why
    COL     r8d, C_FG_DIM
    cmp     qword ptr [rip+fd_err], 0
    je      61f
    lea     rdi, [rip+s_cannot]
    COL     r8d, C_RED
61: SP      edx, 10
    add     edx, r13d
    mov     ecx, [rip+fd_rh]
    shr     ecx, 1
    add     ecx, [rip+fd_list_y]
    call    text_z
    jmp     .Ldf_done
7:  xor     ebx, ebx                    # row
.Ldf_row:
    cmp     rbx, [rip+fd_rows]
    jae     .Ldf_done
    mov     rdi, rbx
    add     rdi, [rip+fd_top]
    cmp     rdi, [rip+fd_vn]
    jae     .Ldf_done
    mov     [rsp+16], rdi               # (its index)
    call    ent_addr
    mov     rbp, rax                    # rbp = the entry
    mov     eax, ebx                    # the row's top and centre
    imul    eax, [rip+fd_rh]
    add     eax, [rip+fd_list_y]
    mov     [rsp], rax
    mov     ecx, [rip+fd_rh]
    shr     ecx, 1
    add     eax, ecx
    mov     [rsp+8], rax
    mov     rax, [rsp+16]
    cmp     rax, [rip+fd_sel]
    jne     71f
    mov     edi, r13d
    mov     esi, [rsp]
    mov     edx, r14d
    sub     edx, r13d
    mov     ecx, [rip+fd_rh]
    COL     r8d, C_SEL
    call    fill_rect_px
71: mov     rdi, rbp                    # the name (a folder's in the accent colour, with '/')
    call    ent_name
    mov     rdi, rsi
    mov     rsi, rdx
    SP      edx, 10
    add     edx, r13d
    mov     ecx, [rsp+8]
    COL     r8d, C_FG
    test    word ptr [rbp+6], F_DIR
    jz      72f
    COL     r8d, C_ACCENT
72: call    ui_text
    test    word ptr [rbp+6], F_DIR
    jz      73f
    test    word ptr [rbp+6], F_PARENT
    jnz     74f
    mov     edx, eax
    LSTR    "/"
    mov     rdi, rsi
    mov     rsi, rdx
    mov     edx, eax
    mov     ecx, [rsp+8]
    COL     r8d, C_ACCENT
    call    ui_text
    jmp     74f
73: mov     rdi, [rbp+8]                # a file's size, on the right
    call    fmt_size
    lea     rdi, [rip+fd_fmt]
    mov     rsi, [rip+fd_fmt_len]
    call    ui_text_w
    mov     edx, r14d
    sub     edx, eax
    SP      eax, 10
    sub     edx, eax
    lea     rdi, [rip+fd_fmt]
    mov     rsi, [rip+fd_fmt_len]
    mov     ecx, [rsp+8]
    COL     r8d, C_FG_DIM
    call    ui_text
74: inc     rbx
    jmp     .Ldf_row
.Ldf_done:
    call    reset_clip
    mov     rax, [rip+fd_vn]            # a scroll mark when the list is longer
    cmp     rax, [rip+fd_rows]
    jbe     9f
    mov     rax, [rip+fd_rows]
    imul    rax, [rip+fd_rh]
    mov     r12, rax                    # list height
    imul    rax, [rip+fd_rows]
    xor     edx, edx
    div     qword ptr [rip+fd_vn]
    SP      ecx, 16
    cmp     rax, rcx
    jge     8f
    mov     rax, rcx
8:  mov     rbp, rax                    # mark height
    mov     rax, r12
    sub     rax, rbp
    imul    rax, [rip+fd_top]
    mov     rcx, [rip+fd_vn]
    sub     rcx, [rip+fd_rows]
    xor     edx, edx
    div     rcx
    add     rax, [rip+fd_list_y]
    mov     esi, eax
    SP      edx, 3
    mov     edi, r14d
    sub     edi, edx
    mov     ecx, ebp
    COL     r8d, C_MUTED
    call    fill_rect_px
9:  add     rsp, 24
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

.section .note.GNU-stack,"",@progbits
