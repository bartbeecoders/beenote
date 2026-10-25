# =============================================================================
#  BeeNote - the platform layer, Windows version (build/beenote.exe). It
#  takes the place of main.s, wayland.s, keyboard.s, clipboard.s and
#  plat_linux.s; every other module is the same object as in the Linux build.
#
#  - the start: argv and envp in UTF-8 from the UTF-16 command line and
#    environment (HOME from USERPROFILE when it is not set), then the same
#    start-up as main.s
#  - plat_sys: the Linux system calls the shared modules make (open, read,
#    write, close, stat, fstat, mmap, munmap, getdents64, getcwd, mkdir,
#    rename, timerfd), answered with kernel32. Paths: the shared code's
#    absolute paths start with '/', so a drive is a folder of the root:
#    C:\Users\bart is /C:/Users/bart, and / lists the drives
#  - the window (user32, gdi32): the frame is drawn into memory as on
#    Wayland and shown with StretchDIBits; per-monitor DPI is the UI scale
#  - input: Windows scan codes are evdev codes (set 1) for most keys; the
#    text a key types comes from its WM_CHAR, so Windows does the layouts,
#    the dead keys and the key repeat
#  - the clipboard (CF_UNICODETEXT), dropped files (shell32)
#
#  Calls into Windows: rcx, rdx, r8, r9, then the stack above 32 bytes of
#  shadow space, rsp 16-byte aligned; rax, rcx, rdx, r8-r11 and xmm0-xmm5
#  are lost. Linked at a fixed image base below 2 GiB with no relocations
#  (scripts/build.sh), so the imports at the end are written out by hand
#  as RVAs: no import library, no C runtime.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "beenote.inc"
.include "version.inc"

.globl win_start
.globl plat_sys
.globl plat_path_in
.globl getenv
.globl str_eq
.globl envp
.globl dirty
.globl quit_flag
.globl pump
.globl render
.globl set_cursor
.globl set_title
.globl clip_copy
.globl clip_paste
.globl clip_own
.globl clip_serial
.globl kb_text
.globl kb_canon_mods
.globl kb_layout_code
.globl kb_compose
.globl kb_repeat_start
.globl kb_repeat_stop
.globl rep_code

.equ IMAGE_BASE,        0x400000        # (scripts/build.sh links there)
.equ CP_UTF8,           65001
.equ WPATH_N,           4096            # UTF-16 units in a path
.equ FD_N,              16              # files, folders and timers open at once
.equ SLOT_SZ,           8832
.equ S_KIND,            0               # 0 free, 1 a file, 2 a folder, 3 a timer
.equ S_H,               8               # its handle (a folder: FindFirstFileW's)
.equ S_ST,              16              # a folder: 1 an entry waiting, 2 done, 4 the root
.equ S_DRV,             24              # (the root: the next drive)
.equ S_FIND,            32              # WIN32_FIND_DATAW (592 bytes)
.equ S_PATH,            624             # the folder's pattern, UTF-16 ("C:\x\*")
.equ K_FILE,            1
.equ K_DIR,             2
.equ K_TIMER,           3
.equ CLIP_CAP,          4194304
.equ ERRNO_EIO,         5

# Windows messages
.equ WM_DESTROY,        0x0002
.equ WM_SIZE,           0x0005
.equ WM_PAINT,          0x000F
.equ WM_CLOSE,          0x0010
.equ WM_QUIT,           0x0012
.equ WM_ERASEBKGND,     0x0014
.equ WM_SETCURSOR,      0x0020
.equ WM_GETMINMAXINFO,  0x0024
.equ WM_KEYDOWN,        0x0100
.equ WM_KEYUP,          0x0101
.equ WM_CHAR,           0x0102
.equ WM_DEADCHAR,       0x0103
.equ WM_SYSKEYDOWN,     0x0104
.equ WM_SYSKEYUP,       0x0105
.equ WM_SYSCHAR,        0x0106
.equ WM_SYSDEADCHAR,    0x0107
.equ WM_TIMER,          0x0113
.equ WM_MOUSEMOVE,      0x0200
.equ WM_LBUTTONDOWN,    0x0201
.equ WM_LBUTTONUP,      0x0202
.equ WM_RBUTTONDOWN,    0x0204
.equ WM_RBUTTONUP,      0x0205
.equ WM_MBUTTONDOWN,    0x0207
.equ WM_MBUTTONUP,      0x0208
.equ WM_MOUSEWHEEL,     0x020A
.equ WM_MOUSEHWHEEL,    0x020E
.equ WM_DROPFILES,      0x0233
.equ WM_MOUSELEAVE,     0x02A3
.equ WM_DPICHANGED,     0x02E0
.equ WS_OVERLAPPEDWINDOW, 0x00CF0000
.equ WS_EX_ACCEPTFILES, 0x10
.equ CW_USEDEFAULT,     0x80000000
.equ VK_SHIFT,          0x10
.equ VK_CONTROL,        0x11
.equ VK_MENU,           0x12
.equ VK_F4,             0x73
.equ VK_RMENU,          0xA5

.section .data
.align 8
w_dpi:          .long 96
rep_code:       .long 0
clip_serial:    .long 0

.section .bss
.align 8
envp:           .skip 8
w_hwnd:         .skip 8
w_inst:         .skip 8
w_cur:          .skip 8*3               # arrow, I-beam, hand
w_buf:          .skip 8                 # the frame's pixels
w_buf_cap:      .skip 8
w_clipseq:      .skip 8                 # the clipboard's number when we set it
dirty:          .skip 4
quit_flag:      .skip 4
w_fbw:          .skip 4                 # the last frame's size
w_fbh:          .skip 4
w_ready:        .skip 4                 # the window is up
w_track:        .skip 4                 # TrackMouseEvent asked for the leave
w_char:         .skip 4                 # the key's text, its modifiers, its
w_mods:         .skip 4                 #   letter's QWERTY code (kb_*)
w_layout:       .skip 4
w_hisur:        .skip 4                 # a high surrogate waiting for its low one
clip_own:       .skip 4
clip_len:       .skip 4
.align 16
w_bmi:          .skip 48                # BITMAPINFOHEADER (+ no palette)
w_msg:          .skip 48                # MSG
w_ps:           .skip 80                # PAINTSTRUCT
w_rect:         .skip 16
w_wc:           .skip 80                # WNDCLASSEXW
w_tme:          .skip 24                # TRACKMOUSEEVENT
w_attr:         .skip 40                # WIN32_FILE_ATTRIBUTE_DATA
w_li:           .skip 8
w_got:          .skip 8
fds:            .skip FD_N*SLOT_SZ
wp1:            .skip WPATH_N*2         # paths for the calls, UTF-16
wp2:            .skip WPATH_N*2
w_title:        .skip 1024
w_u8:           .skip 4096              # a name or path in UTF-8
w_home:         .skip 4096              # "HOME=..." when Windows has no HOME
clip_buf:       .skip CLIP_CAP+8        # our own copy (pasted back as it was)
clip_crlf:      .skip 2*CLIP_CAP+8      # the text with CRLF line ends

.section .rodata
s_opt_version:  .asciz "--version"
s_opt_help:     .asciz "--help"
s_help:         .ascii "Usage: beenote [file]\r\n"
                .ascii "A notepad in pure x86-64 assembly. F1 in the window lists the keys.\r\n"
                .ascii "BEENOTE_FONT=C:\\path\\to\\font.ttf picks another font.\r\n"
s_help_end:
s_name:         .ascii "BeeNote "
s_name_end:
s_crlf:         .ascii "\r\n"
s_home_eq:      .asciz "HOME="
s_userprofile:  .asciz "USERPROFILE="
w_class:        .short 'B','e','e','N','o','t','e',0
w_cap:          .short 'B','e','e','N','o','t','e',0
# extended (E0) scan codes -> evdev
ext_keys:       .byte 0x1C, 96, 0x1D, 97, 0x35, 98, 0x37, 99, 0x38, 100
                .byte 0x47, 102, 0x48, 103, 0x49, 104, 0x4B, 105, 0x4D, 106
                .byte 0x4F, 107, 0x50, 108, 0x51, 109, 0x52, 110, 0x53, 111
                .byte 0x5B, 125, 0x5C, 126, 0x5D, 127, 0

# WCALL frame: SysV routines here that call Windows. rbx, r12-r15 are free
# to use; [rsp+32...] holds `locals` bytes for arguments and results.
.macro WFRAME locals=0
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    and     rsp, -16
    sub     rsp, 32+\locals
.endm
.macro WRET
    lea     rsp, [rbp-40]
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    pop     rbp
    ret
.endm

.text

# =============================================================================
#  The start
# =============================================================================
# Windows enters here (the PE entry point) with nothing on the stack: argv
# and envp are built from the UTF-16 command line and environment as UTF-8,
# as the Linux kernel would hand them over. (From BeeModel's plat_win.s.)
win_start:
    and     rsp, -16
    sub     rsp, 32
    call    [rip+__imp_GetCommandLineW]
    mov     rdi, rax
    mov     esi, -1
    call    w2u_dup                     # rax = the line in UTF-8, edx its size
    mov     r13, rax
    mov     r14d, edx
    mov     edi, edx                    # the words: never longer than the line
    call    win_alloc
    mov     r15, rax
    mov     edi, r14d                   # argv: at most a pointer per 2 bytes
    shr     edi, 1
    add     edi, 2
    shl     edi, 3
    call    win_alloc
    mov     r12, rax
    mov     rsi, r13
    mov     rdi, r15
    call    split_args                  # ebx = argc
    call    [rip+__imp_GetEnvironmentStringsW]
    xor     esi, esi                    # its length: up to the empty entry
1:  cmp     word ptr [rax+rsi*2], 0
    jne     2f
    test    esi, esi
    jz      3f
    cmp     word ptr [rax+rsi*2-2], 0
    je      3f
2:  inc     esi
    jmp     1b
3:  inc     esi
    mov     rdi, rax
    call    w2u_dup
    mov     r13, rax                    # NAME=value\0 ... \0
    mov     edi, edx                    # envp: at most a pointer per 2 bytes
    shr     edi, 1
    add     edi, 4
    shl     edi, 3
    call    win_alloc
    mov     [rip+envp], rax
    mov     rdi, rax
4:  cmp     byte ptr [r13], 0
    je      6f
    mov     [rdi], r13
    add     rdi, 8
5:  inc     r13
    cmp     byte ptr [r13-1], 0
    jne     5b
    jmp     4b
6:  mov     qword ptr [rdi], 0
    call    home_env
    mov     rcx, -4                     # DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2
    call    [rip+__imp_SetProcessDpiAwarenessContext]
    cmp     ebx, 2
    jb      .Lnoarg
    mov     r13, [r12+8]                # argv[1]
    mov     rdi, r13
    lea     rsi, [rip+s_opt_version]
    call    str_eq
    test    eax, eax
    jz      1f
    call    w_console
    mov     edi, 1
    lea     rsi, [rip+s_name]
    mov     edx, s_name_end - s_name
    call    write_all
    lea     rdi, [rip+s_version]
    call    str_len
    mov     rdx, rax
    mov     edi, 1
    lea     rsi, [rip+s_version]
    call    write_all
    mov     edi, 1
    lea     rsi, [rip+s_crlf]
    mov     edx, 2
    call    write_all
    jmp     .Lexit
1:  mov     rdi, r13
    lea     rsi, [rip+s_opt_help]
    call    str_eq
    test    eax, eax
    jz      2f
    call    w_console
    mov     edi, 1
    lea     rsi, [rip+s_help]
    mov     edx, s_help_end - s_help
    call    write_all
    jmp     .Lexit
2:  mov     rsi, r13                    # beenote file: open (or start) it
    lea     rdi, [rip+fname]
    mov     edx, FNAME_MAX-2
    call    path_in_copy
    mov     [rip+fname_len], rax
.Lnoarg:
    call    theme_init                  # Omarchy's colours (if any), our configuration
    call    ui_init                     # the font
    call    doc_reset
    call    recent_init
    cmp     qword ptr [rip+fname_len], 0
    je      7f
    call    doc_load
7:  call    w_create
    mov     dword ptr [rip+dirty], 1
.Lloop:
    call    pump
    cmp     dword ptr [rip+quit_flag], 0
    je      .Lloop
.Lexit:
    xor     ecx, ecx
    call    [rip+__imp_ExitProcess]

# w_console - --version / --help from a console: our output goes there
#   (a GUI program has none of its own unless the output is redirected)
w_console:
    WFRAME
    mov     ecx, -11                    # STD_OUTPUT_HANDLE
    call    [rip+__imp_GetStdHandle]
    test    rax, rax
    jz      1f
    cmp     rax, -1
    jne     9f
1:  mov     ecx, -1                     # ATTACH_PARENT_PROCESS
    call    [rip+__imp_AttachConsole]
9:  WRET

# home_env - HOME=<USERPROFILE as a BeeNote path> when Windows has no HOME,
#   so ~ and the configuration (~/.config/beenote) work as on Linux
home_env:
    push    rbx
    lea     rdi, [rip+s_home_eq]
    call    getenv
    test    rax, rax
    jnz     9f
    lea     rdi, [rip+s_userprofile]
    call    getenv
    test    rax, rax
    jz      9f
    mov     rsi, rax
    lea     rdi, [rip+w_home]
    mov     dword ptr [rdi], 'H' | 'O' << 8 | 'M' << 16 | 'E' << 24
    mov     byte ptr [rdi+4], '='
    add     rdi, 5
    mov     edx, 4096-8
    call    path_in_copy
    mov     rax, [rip+envp]             # added at the end
1:  cmp     qword ptr [rax], 0
    je      2f
    add     rax, 8
    jmp     1b
2:  lea     rcx, [rip+w_home]
    mov     [rax], rcx
    mov     qword ptr [rax+8], 0
9:  pop     rbx
    ret

# path_in_copy(rdi=dest, rsi=a Windows path, edx=room) -> rax = the length:
#   backslashes become '/', a drive gets the leading '/' (C:\x -> /C:/x)
path_in_copy:
    mov     r8, rdi
    cmp     byte ptr [rsi], 0
    je      2f
    cmp     byte ptr [rsi+1], ':'
    jne     2f
    mov     byte ptr [rdi], '/'
    inc     rdi
2:  lea     r9, [r8+rdx]
3:  cmp     rdi, r9
    jae     4f
    mov     al, [rsi]
    test    al, al
    jz      4f
    cmp     al, '\\'
    jne     31f
    mov     al, '/'
31: mov     [rdi], al
    inc     rdi
    inc     rsi
    jmp     3b
4:  mov     byte ptr [rdi], 0
    mov     rax, rdi
    sub     rax, r8
    ret

# plat_path_in(rdi=path, rsi=its length (qword), edx=room) - a typed
#   Windows path in place: C:\x -> /C:/x
plat_path_in:
    mov     rcx, [rsi]
    xor     eax, eax
1:  cmp     rax, rcx                    # backslashes
    jae     2f
    cmp     byte ptr [rdi+rax], '\\'
    jne     11f
    mov     byte ptr [rdi+rax], '/'
11: inc     rax
    jmp     1b
2:  cmp     rcx, 2                      # a drive: room for the '/'
    jb      9f
    cmp     byte ptr [rdi+1], ':'
    jne     9f
    lea     rax, [rcx+2]
    cmp     rax, rdx
    ja      9f
    push    rsi
    push    rdi
    push    rcx
    lea     rsi, [rdi]
    inc     rdi
    lea     rdx, [rcx+1]
    call    memmove                     # (overlapping: backwards)
    pop     rcx
    pop     rdi
    pop     rsi
    mov     byte ptr [rdi], '/'
    inc     rcx
    mov     [rsi], rcx
    mov     byte ptr [rdi+rcx], 0
9:  ret

# split_args(rsi=the command line, rdi=room for the words, r12=room for
# argv) -> ebx = argc. The rules of the Microsoft C runtime: blanks part
# words, "..." quotes, 2n backslashes and a quote are n backslashes and a
# quote that counts, 2n+1 are n and a plain quote, "" inside quotes is a
# quote; the program's name (argv[0]) knows only quotes. Ends argv with 0.
split_args:
    xor     ebx, ebx
    mov     [r12], rdi                  # argv[0]
    inc     ebx
    xor     ecx, ecx                    # ecx = inside quotes
1:  mov     al, [rsi]
    test    al, al
    jz      3f
    inc     rsi
    cmp     al, '"'
    jne     2f
    xor     ecx, 1
    jmp     1b
2:  test    ecx, ecx
    jnz     21f
    cmp     al, ' '
    je      3f
    cmp     al, 9
    je      3f
21: mov     [rdi], al
    inc     rdi
    jmp     1b
3:  mov     byte ptr [rdi], 0
    inc     rdi
.Lsa_word:
    mov     al, [rsi]                   # the blanks between words
    cmp     al, ' '
    je      4f
    cmp     al, 9
    jne     5f
4:  inc     rsi
    jmp     .Lsa_word
5:  test    al, al
    jz      .Lsa_done
    mov     [r12+rbx*8], rdi
    inc     ebx
    xor     ecx, ecx
.Lsa_char:
    mov     al, [rsi]
    test    al, al
    jz      .Lsa_end
    test    ecx, ecx
    jnz     6f
    cmp     al, ' '
    je      .Lsa_end
    cmp     al, 9
    je      .Lsa_end
6:  cmp     al, '\\'
    je      .Lsa_bs
    cmp     al, '"'
    je      .Lsa_quote
    mov     [rdi], al
    inc     rdi
    inc     rsi
    jmp     .Lsa_char
.Lsa_quote:
    inc     rsi
    test    ecx, ecx
    jz      7f
    cmp     byte ptr [rsi], '"'         # "" inside quotes: a quote
    jne     7f
    mov     byte ptr [rdi], '"'
    inc     rdi
    inc     rsi
    jmp     .Lsa_char
7:  xor     ecx, 1
    jmp     .Lsa_char
.Lsa_bs:
    xor     edx, edx                    # edx = how many backslashes
8:  cmp     byte ptr [rsi+rdx], '\\'
    jne     9f
    inc     edx
    jmp     8b
9:  cmp     byte ptr [rsi+rdx], '"'
    je      10f
    add     rsi, rdx                    # no quote after them: as they are
11: mov     byte ptr [rdi], '\\'
    inc     rdi
    dec     edx
    jnz     11b
    jmp     .Lsa_char
10: add     rsi, rdx                    # (rsi at the quote)
    mov     eax, edx
    shr     edx, 1
    jz      13f
12: mov     byte ptr [rdi], '\\'
    inc     rdi
    dec     edx
    jnz     12b
13: test    eax, 1
    jz      .Lsa_char                   # even: the quote counts
    mov     byte ptr [rdi], '"'         # odd: a plain quote
    inc     rdi
    inc     rsi
    jmp     .Lsa_char
.Lsa_end:
    mov     byte ptr [rdi], 0
    inc     rdi
    jmp     .Lsa_word
.Lsa_done:
    mov     qword ptr [r12+rbx*8], 0
    ret

# win_alloc(edi=bytes) -> rax = fresh zeroed memory (the start's own: it
#   ends the program when there is none)
win_alloc:
    WFRAME
    xor     ecx, ecx
    mov     edx, edi
    mov     r8d, 0x3000                 # MEM_COMMIT | MEM_RESERVE
    mov     r9d, 4                      # PAGE_READWRITE
    call    [rip+__imp_VirtualAlloc]
    test    rax, rax
    jz      win_fail
    WRET

# w2u_dup(rdi=UTF-16 text, esi=its length in units, -1: to its 0) -> rax =
#   it in UTF-8 in fresh memory, edx = the bytes (with the 0 when counted)
w2u_dup:
    push    rbx
    push    r12
    push    r13
    mov     r12, rdi
    mov     r13d, esi
    xor     r8d, r8d
    xor     r9d, r9d
    call    w2u                         # how big
    test    eax, eax
    jz      win_fail
    mov     ebx, eax
    lea     edi, [rax+1]
    call    win_alloc
    mov     rdi, r12
    mov     esi, r13d
    mov     r8, rax
    mov     r9d, ebx
    mov     r12, rax
    call    w2u
    mov     rax, r12
    mov     edx, ebx
    pop     r13
    pop     r12
    pop     rbx
    ret

# w2u(rdi=UTF-16 text, esi=units or -1, r8=out, r9d=its room, 0: only
#   count) -> eax = the bytes written (or needed); 0 on an error
w2u:
    WFRAME 32
    mov     [rsp+32], r8                # lpMultiByteStr
    mov     [rsp+40], r9                # cbMultiByte
    xor     eax, eax
    mov     [rsp+48], rax               # lpDefaultChar
    mov     [rsp+56], rax               # lpUsedDefaultChar
    mov     ecx, CP_UTF8
    xor     edx, edx
    mov     r8, rdi
    mov     r9d, esi
    call    [rip+__imp_WideCharToMultiByte]
    WRET

# u2w(rdi=UTF-8 text, esi=bytes or -1, r8=out, r9d=its room in units) ->
#   eax = the units written; 0 on an error
u2w:
    WFRAME 16
    mov     [rsp+32], r8
    mov     [rsp+40], r9
    mov     ecx, CP_UTF8
    xor     edx, edx
    mov     r8, rdi
    mov     r9d, esi
    call    [rip+__imp_MultiByteToWideChar]
    WRET

# Out of memory before anything runs: end with 1
win_fail:
    and     rsp, -16
    sub     rsp, 32
    mov     ecx, 1
    call    [rip+__imp_ExitProcess]

# getenv(rdi="NAME=") -> rax = value pointer or 0
getenv:
    mov     r8, [rip+envp]
1:  mov     rsi, [r8]
    test    rsi, rsi
    jz      4f
    xor     ecx, ecx
2:  mov     al, [rdi+rcx]
    test    al, al
    jz      3f                          # whole prefix matched
    cmp     al, [rsi+rcx]
    jne     5f
    inc     ecx
    jmp     2b
3:  lea     rax, [rsi+rcx]
    ret
5:  add     r8, 8
    jmp     1b
4:  xor     eax, eax
    ret

# str_eq(rdi, rsi) -> eax = 1 if equal
str_eq:
    xor     ecx, ecx
1:  mov     al, [rdi+rcx]
    cmp     al, [rsi+rcx]
    jne     2f
    test    al, al
    jz      3f
    inc     ecx
    jmp     1b
2:  xor     eax, eax
    ret
3:  mov     eax, 1
    ret

# =============================================================================
#  plat_sys: the Linux calls, answered by Windows. The contract of the
#  syscall instruction: every register but rax, rcx and r11 is kept (the
#  xmm registers too). The handlers find the arguments where the caller put
#  them (rdi, rsi, rdx, r10, r8, r9); [rsp+32...] holds 80 bytes for the
#  calls' stack arguments.
# =============================================================================
plat_sys:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    rsi
    push    rdi
    push    rdx
    push    r8
    push    r9
    push    r10
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 96
    movdqu  [rbp-104], xmm0
    movdqu  [rbp-120], xmm1
    movdqu  [rbp-136], xmm2
    movdqu  [rbp-152], xmm3
    movdqu  [rbp-168], xmm4
    movdqu  [rbp-184], xmm5
    and     rsp, -16
    sub     rsp, 112
    cmp     eax, 0
    je      sys_read
    cmp     eax, 1
    je      sys_write
    cmp     eax, 2
    je      sys_open
    cmp     eax, 3
    je      sys_close
    cmp     eax, 4
    je      sys_stat
    cmp     eax, 5
    je      sys_fstat
    cmp     eax, 9
    je      sys_mmap
    cmp     eax, 11
    je      sys_munmap
    cmp     eax, 79
    je      sys_getcwd
    cmp     eax, 82
    je      sys_rename
    cmp     eax, 83
    je      sys_mkdir
    cmp     eax, 217
    je      sys_getdents64
    cmp     eax, 283
    je      sys_timerfd_create
    cmp     eax, 286
    je      .Lps_zero                   # timerfd_settime: WM_TIMER does the ticks
    cmp     eax, 60
    je      sys_exit
    cmp     eax, 231
    je      sys_exit
    mov     rax, -38                    # ENOSYS
    jmp     .Lps_ret
.Lps_zero:
    xor     eax, eax
.Lps_ret:
    movdqu  xmm0, [rbp-104]
    movdqu  xmm1, [rbp-120]
    movdqu  xmm2, [rbp-136]
    movdqu  xmm3, [rbp-152]
    movdqu  xmm4, [rbp-168]
    movdqu  xmm5, [rbp-184]
    lea     rsp, [rbp-88]
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     r10
    pop     r9
    pop     r8
    pop     rdx
    pop     rdi
    pop     rsi
    pop     rbx
    pop     rbp
    ret
.Lps_ebadf:
    mov     rax, -9
    jmp     .Lps_ret
.Lps_err:                               # GetLastError -> -errno
    call    w_errno
    jmp     .Lps_ret

# w_errno -> rax = -errno for GetLastError
w_errno:
    sub     rsp, 40
    call    [rip+__imp_GetLastError]
    add     rsp, 40
    mov     ecx, eax
    mov     rax, -2                     # ENOENT: no file, no path, a bad name
    cmp     ecx, 2
    je      9f
    cmp     ecx, 3
    je      9f
    cmp     ecx, 123
    je      9f
    mov     rax, -13                    # EACCES: denied, in use
    cmp     ecx, 5
    je      9f
    cmp     ecx, 32
    je      9f
    cmp     ecx, 33
    je      9f
    mov     rax, -17                    # EEXIST
    cmp     ecx, 80
    je      9f
    cmp     ecx, 183
    je      9f
    mov     rax, -20                    # ENOTDIR
    cmp     ecx, 267
    je      9f
    mov     rax, -36                    # ENAMETOOLONG
    cmp     ecx, 206
    je      9f
    mov     rax, -28                    # ENOSPC
    cmp     ecx, 112
    je      9f
    mov     rax, -ERRNO_EIO
9:  ret

# w_slot(edi=fd) -> rbx = its slot, or 0
w_slot:
    xor     ebx, ebx
    sub     edi, 3
    jb      9f
    cmp     edi, FD_N
    jae     9f
    imul    ebx, edi, SLOT_SZ
    lea     rax, [rip+fds]
    add     rbx, rax
    cmp     qword ptr [rbx+S_KIND], 0
    jne     9f
    xor     ebx, ebx
9:  ret

# w_new_slot -> rbx = a free slot (zeroed kind, handle, state), r12d = its fd; rbx = 0 if none
w_new_slot:
    lea     rbx, [rip+fds]
    xor     r12d, r12d
1:  cmp     qword ptr [rbx+S_KIND], 0
    je      2f
    add     rbx, SLOT_SZ
    inc     r12d
    cmp     r12d, FD_N
    jb      1b
    xor     ebx, ebx
    ret
2:  xor     eax, eax
    mov     [rbx+S_H], rax
    mov     [rbx+S_ST], rax
    mov     [rbx+S_DRV], rax
    add     r12d, 3
    ret

# w_path(rdi=UTF-8 path, rsi=UTF-16 out, WPATH_N units) -> eax = 1, 2 for
#   the root "/", 0 when it does not convert. /C:/x -> C:\x, C: -> C:\.
w_path:
    push    rbx
    push    r12
    sub     rsp, 56
    mov     rbx, rdi
    mov     r12, rsi
    cmp     byte ptr [rbx], '/'
    jne     1f
    cmp     byte ptr [rbx+1], 0
    je      8f
    cmp     byte ptr [rbx+1], '/'       # (//server/share stays)
    je      1f
    cmp     byte ptr [rbx+2], ':'
    jne     1f
    inc     rbx                         # a drive: its letter first
1:  mov     [rsp+32], r12
    mov     dword ptr [rsp+40], WPATH_N
    mov     ecx, CP_UTF8
    xor     edx, edx
    mov     r8, rbx
    mov     r9d, -1
    call    [rip+__imp_MultiByteToWideChar]
    test    eax, eax
    jz      9f
    mov     ecx, eax
    xor     edx, edx
2:  cmp     word ptr [r12+rdx*2], '/'
    jne     3f
    mov     word ptr [r12+rdx*2], '\\'
3:  inc     edx
    cmp     edx, ecx
    jb      2b
    cmp     ecx, 3                      # "C:" alone: the drive's root
    jne     4f
    cmp     word ptr [r12+2], ':'
    jne     4f
    mov     word ptr [r12+4], '\\'
    mov     word ptr [r12+6], 0
4:  mov     eax, 1
    jmp     9f
8:  mov     eax, 2
9:  add     rsp, 56
    pop     r12
    pop     rbx
    ret

# w_upath(rdi=UTF-16 path, rsi=out, edx=room) -> rax = its length as a
#   BeeNote path (C:\x -> /C:/x, no trailing '/'), -1 when it does not fit
w_upath:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 64
    mov     rbx, rsi
    lea     r12d, [rdx-2]
    mov     [rsp+32], rbx
    mov     [rsp+40], r12
    xor     eax, eax
    mov     [rsp+48], rax
    mov     [rsp+56], rax
    mov     r8, rdi
    mov     r9d, -1
    mov     ecx, CP_UTF8
    xor     edx, edx
    call    [rip+__imp_WideCharToMultiByte]
    test    eax, eax
    jz      8f
    lea     r13d, [rax-1]               # the length
    xor     ecx, ecx
1:  cmp     ecx, r13d
    jae     2f
    cmp     byte ptr [rbx+rcx], '\\'
    jne     11f
    mov     byte ptr [rbx+rcx], '/'
11: inc     ecx
    jmp     1b
2:  cmp     r13d, 2
    jb      4f
    cmp     byte ptr [rbx+1], ':'
    jne     4f
    mov     ecx, r13d                   # a drive: '/' first
3:  mov     al, [rbx+rcx]
    mov     [rbx+rcx+1], al
    dec     ecx
    jns     3b
    mov     byte ptr [rbx], '/'
    inc     r13d
4:  cmp     r13d, 1                     # no trailing '/'
    jbe     5f
    cmp     byte ptr [rbx+r13-1], '/'
    jne     5f
    dec     r13d
    mov     byte ptr [rbx+r13], 0
    jmp     4b
5:  mov     eax, r13d
    jmp     9f
8:  mov     rax, -1
9:  add     rsp, 64
    pop     r13
    pop     r12
    pop     rbx
    ret

# open(rdi=path, esi=flags): files (read; write, create, truncate) and
#   folders (O_DIRECTORY: getdents64 lists them)
sys_open:
    mov     r13, rdi
    mov     r14d, esi
    call    w_new_slot
    test    rbx, rbx
    jnz     1f
    mov     rax, -24                    # EMFILE
    jmp     .Lps_ret
1:  mov     rdi, r13
    lea     rsi, [rbx+S_PATH]
    call    w_path
    test    eax, eax
    jnz     2f
    mov     rax, -2
    jmp     .Lps_ret
2:  test    r14d, 0x10000               # O_DIRECTORY
    jz      .Lop_file
    cmp     eax, 2
    jne     3f
    mov     qword ptr [rbx+S_ST], 4     # the root: the drives
    jmp     .Lop_dir
3:  lea     rcx, [rbx+S_PATH]
    call    [rip+__imp_GetFileAttributesW]
    cmp     eax, -1
    je      .Lps_err
    test    eax, 0x10
    jnz     4f
    mov     rax, -20                    # ENOTDIR
    jmp     .Lps_ret
4:  lea     rcx, [rbx+S_PATH]           # its pattern: path\*
    xor     eax, eax
5:  cmp     word ptr [rcx+rax*2], 0
    je      6f
    inc     eax
    jmp     5b
6:  cmp     eax, WPATH_N-3
    jae     .Lop_long
    test    eax, eax
    jz      7f
    cmp     word ptr [rcx+rax*2-2], '\\'
    je      7f
    mov     word ptr [rcx+rax*2], '\\'
    inc     eax
7:  mov     word ptr [rcx+rax*2], '*'
    mov     word ptr [rcx+rax*2+2], 0
.Lop_dir:
    mov     qword ptr [rbx+S_KIND], K_DIR
    mov     eax, r12d
    jmp     .Lps_ret
.Lop_long:
    mov     rax, -36
    jmp     .Lps_ret
.Lop_file:
    cmp     eax, 2
    jne     1f
    mov     rax, -21                    # EISDIR: the root
    jmp     .Lps_ret
1:  mov     edx, 0x80000000             # GENERIC_READ
    mov     eax, 3                      # OPEN_EXISTING
    test    r14d, 3
    jz      2f
    mov     edx, 0x40000000             # GENERIC_WRITE
    test    r14d, 0x40                  # O_CREAT
    jz      11f
    mov     eax, 4                      # OPEN_ALWAYS
    test    r14d, 0x200                 # O_TRUNC
    jz      2f
    mov     eax, 2                      # CREATE_ALWAYS
    jmp     2f
11: test    r14d, 0x200
    jz      2f
    mov     eax, 5                      # TRUNCATE_EXISTING
2:  lea     rcx, [rbx+S_PATH]
    mov     r8d, 7                      # FILE_SHARE_READ | WRITE | DELETE
    xor     r9d, r9d
    mov     [rsp+32], rax
    mov     qword ptr [rsp+40], 0x80    # FILE_ATTRIBUTE_NORMAL
    mov     qword ptr [rsp+48], 0
    call    [rip+__imp_CreateFileW]
    cmp     rax, -1
    je      .Lps_err
    mov     [rbx+S_H], rax
    mov     qword ptr [rbx+S_KIND], K_FILE
    mov     eax, r12d
    jmp     .Lps_ret

# read(edi=fd, rsi=buffer, rdx=bytes)
sys_read:
    mov     r13, rsi
    mov     r14, rdx
    call    w_slot
    test    rbx, rbx
    jz      .Lps_ebadf
    cmp     qword ptr [rbx+S_KIND], K_TIMER
    jne     1f
    mov     eax, 8                      # a timer's tick (WM_TIMER said so)
    jmp     .Lps_ret
1:  cmp     qword ptr [rbx+S_KIND], K_FILE
    jne     .Lps_ebadf
    mov     rcx, [rbx+S_H]
    mov     rdx, r13
    mov     r8, r14
    mov     eax, 0x7fff0000
    cmp     r8, rax
    jbe     2f
    mov     r8, rax
2:  lea     r9, [rip+w_got]
    mov     dword ptr [r9], 0
    mov     qword ptr [rsp+32], 0
    call    [rip+__imp_ReadFile]
    test    eax, eax
    jz      3f
    mov     eax, [rip+w_got]
    jmp     .Lps_ret
3:  call    w_errno
    cmp     rax, -ERRNO_EIO             # (the end of a pipe: the end)
    jne     .Lps_ret
    xor     eax, eax
    jmp     .Lps_ret

# write(edi=fd, rsi=buffer, rdx=bytes): files, and the console (1, 2)
sys_write:
    mov     r13, rsi
    mov     r14, rdx
    cmp     edi, 2
    ja      2f
    mov     ecx, -10                    # STD_INPUT_HANDLE - fd
    sub     ecx, edi
    call    [rip+__imp_GetStdHandle]
    test    rax, rax                    # (no console: as if written)
    jz      1f
    cmp     rax, -1
    jne     3f
1:  mov     rax, r14
    jmp     .Lps_ret
2:  call    w_slot
    test    rbx, rbx
    jz      .Lps_ebadf
    cmp     qword ptr [rbx+S_KIND], K_FILE
    jne     .Lps_ebadf
    mov     rax, [rbx+S_H]
3:  mov     rcx, rax
    mov     rdx, r13
    mov     r8, r14
    lea     r9, [rip+w_got]
    mov     dword ptr [r9], 0
    mov     qword ptr [rsp+32], 0
    call    [rip+__imp_WriteFile]
    test    eax, eax
    jz      .Lps_err
    mov     eax, [rip+w_got]
    jmp     .Lps_ret

# close(edi=fd)
sys_close:
    cmp     edi, 3
    jb      .Lps_zero
    call    w_slot
    test    rbx, rbx
    jz      .Lps_ebadf
    mov     rcx, [rbx+S_H]
    mov     rax, [rbx+S_KIND]
    mov     qword ptr [rbx+S_KIND], 0
    cmp     rax, K_FILE
    jne     1f
    call    [rip+__imp_CloseHandle]
    jmp     .Lps_zero
1:  cmp     rax, K_DIR
    jne     .Lps_zero
    test    rcx, rcx                    # (listed: FindFirstFileW's handle)
    jz      .Lps_zero
    cmp     rcx, -1
    je      .Lps_zero
    call    [rip+__imp_FindClose]
    jmp     .Lps_zero

# fstat(edi=fd, rsi=struct stat): a file's size and kind
sys_fstat:
    mov     r13, rsi
    call    w_stat_zero
    call    w_slot
    test    rbx, rbx
    jz      .Lps_ebadf
    cmp     qword ptr [rbx+S_KIND], K_FILE
    je      1f
    mov     dword ptr [r13+24], 0x41ed  # S_IFDIR | 0755
    jmp     .Lps_zero
1:  mov     rcx, [rbx+S_H]
    lea     rdx, [rip+w_li]
    call    [rip+__imp_GetFileSizeEx]
    test    eax, eax
    jz      .Lps_err
    mov     rax, [rip+w_li]
    mov     [r13+48], rax
    mov     dword ptr [r13+24], 0x81a4  # S_IFREG | 0644
    jmp     .Lps_zero

w_stat_zero:                            # r13 = struct stat: zeroed
    xor     eax, eax
    mov     ecx, 18
1:  mov     [r13+rcx*8-8], rax
    loop    1b
    ret

# stat(rdi=path, rsi=struct stat): st_mode, st_size, st_mtime
sys_stat:
    mov     r13, rsi
    call    w_stat_zero
    lea     rsi, [rip+wp1]
    call    w_path
    test    eax, eax
    jnz     1f
    mov     rax, -2
    jmp     .Lps_ret
1:  cmp     eax, 2
    jne     2f
    mov     dword ptr [r13+24], 0x41ed  # the root: a folder
    jmp     .Lps_zero
2:  lea     rcx, [rip+wp1]
    xor     edx, edx                    # GetFileExInfoStandard
    lea     r8, [rip+w_attr]
    call    [rip+__imp_GetFileAttributesExW]
    test    eax, eax
    jz      .Lps_err
    lea     rdx, [rip+w_attr]
    mov     eax, 0x81a4
    test    dword ptr [rdx], 0x10
    jz      3f
    mov     eax, 0x41ed
3:  mov     [r13+24], eax
    mov     eax, [rdx+28]               # nFileSizeHigh, nFileSizeLow
    shl     rax, 32
    mov     ecx, [rdx+32]
    or      rax, rcx
    mov     [r13+48], rax
    mov     rax, [rdx+20]               # ftLastWriteTime: 100 ns since 1601
    xor     edx, edx
    mov     ecx, 10000000
    div     rcx
    imul    rdx, rdx, 100
    mov     [r13+96], rdx               # st_mtime_nsec
    mov     rcx, 11644473600
    sub     rax, rcx
    mov     [r13+88], rax               # st_mtime
    jmp     .Lps_zero

# mmap(rdi=0, rsi=bytes, edx=prot, r10d=flags, r8d=fd, r9=offset): fresh
#   memory, or a file's bytes read into it (BeeNote maps fonts to read them)
sys_mmap:
    mov     r13, rsi
    mov     r14d, r10d
    mov     r15d, r8d
    mov     [rsp+64], r9
    xor     ecx, ecx
    mov     rdx, r13
    mov     r8d, 0x3000                 # MEM_COMMIT | MEM_RESERVE
    mov     r9d, 4                      # PAGE_READWRITE
    call    [rip+__imp_VirtualAlloc]
    test    rax, rax
    jnz     1f
    mov     rax, -12                    # ENOMEM
    jmp     .Lps_ret
1:  mov     [rsp+72], rax
    test    r14d, 0x20                  # MAP_ANONYMOUS
    jnz     8f
    mov     edi, r15d
    call    w_slot
    test    rbx, rbx
    jz      7f
    cmp     qword ptr [rbx+S_KIND], K_FILE
    jne     7f
    mov     rcx, [rbx+S_H]              # from the offset
    mov     rdx, [rsp+64]
    xor     r8d, r8d
    xor     r9d, r9d                    # FILE_BEGIN
    call    [rip+__imp_SetFilePointerEx]
    mov     r12, [rsp+72]               # read it all
2:  test    r13, r13
    jz      8f
    mov     rcx, [rbx+S_H]
    mov     rdx, r12
    mov     r8, r13
    mov     eax, 0x7fff0000
    cmp     r8, rax
    jbe     3f
    mov     r8, rax
3:  lea     r9, [rip+w_got]
    mov     dword ptr [r9], 0
    mov     qword ptr [rsp+32], 0
    call    [rip+__imp_ReadFile]
    test    eax, eax
    jz      8f
    mov     eax, [rip+w_got]
    test    eax, eax
    jz      8f
    add     r12, rax
    sub     r13, rax
    jmp     2b
7:  mov     rcx, [rsp+72]               # no such file: give it back
    xor     edx, edx
    mov     r8d, 0x8000                 # MEM_RELEASE
    call    [rip+__imp_VirtualFree]
    jmp     .Lps_ebadf
8:  mov     rax, [rsp+72]
    jmp     .Lps_ret

# munmap(rdi=address)
sys_munmap:
    mov     rcx, rdi
    xor     edx, edx
    mov     r8d, 0x8000                 # MEM_RELEASE
    call    [rip+__imp_VirtualFree]
    jmp     .Lps_zero

# getcwd(rdi=buffer, rsi=room) -> its length with the 0
sys_getcwd:
    mov     r13, rdi
    mov     r14, rsi
    mov     ecx, WPATH_N
    lea     rdx, [rip+wp1]
    call    [rip+__imp_GetCurrentDirectoryW]
    test    eax, eax
    jz      .Lps_err
    cmp     eax, WPATH_N
    jae     1f
    lea     rdi, [rip+wp1]
    mov     rsi, r13
    mov     rdx, r14
    call    w_upath
    test    rax, rax
    js      1f
    inc     rax
    jmp     .Lps_ret
1:  mov     rax, -34                    # ERANGE
    jmp     .Lps_ret

# mkdir(rdi=path)
sys_mkdir:
    lea     rsi, [rip+wp1]
    call    w_path
    cmp     eax, 1
    je      1f
    mov     rax, -17
    jmp     .Lps_ret
1:  lea     rcx, [rip+wp1]
    xor     edx, edx
    call    [rip+__imp_CreateDirectoryW]
    test    eax, eax
    jz      .Lps_err
    jmp     .Lps_zero

# rename(rdi=old, rsi=new): replaces new
sys_rename:
    mov     r13, rsi
    lea     rsi, [rip+wp1]
    call    w_path
    cmp     eax, 1
    jne     1f
    mov     rdi, r13
    lea     rsi, [rip+wp2]
    call    w_path
    cmp     eax, 1
    jne     1f
    lea     rcx, [rip+wp1]
    lea     rdx, [rip+wp2]
    mov     r8d, 1                      # MOVEFILE_REPLACE_EXISTING
    call    [rip+__imp_MoveFileExW]
    test    eax, eax
    jz      .Lps_err
    jmp     .Lps_zero
1:  mov     rax, -2
    jmp     .Lps_ret

# timerfd_create: a timer the window's WM_TIMER stands in for
sys_timerfd_create:
    call    w_new_slot
    test    rbx, rbx
    jnz     1f
    mov     rax, -24
    jmp     .Lps_ret
1:  mov     qword ptr [rbx+S_KIND], K_TIMER
    mov     eax, r12d
    jmp     .Lps_ret

sys_exit:
    mov     ecx, edi
    call    [rip+__imp_ExitProcess]

# getdents64(edi=fd, rsi=buffer, edx=bytes): linux_dirent64 records (d_ino,
#   d_off, d_reclen, d_type 4 a folder / 8 a file, the name). Hidden and
#   system files are left out; the root lists the drives.
sys_getdents64:
    mov     r13, rsi
    mov     r14d, edx
    call    w_slot
    test    rbx, rbx
    jz      .Lps_ebadf
    cmp     qword ptr [rbx+S_KIND], K_DIR
    je      1f
    mov     rax, -20
    jmp     .Lps_ret
1:  xor     r15d, r15d                  # bytes written
    test    qword ptr [rbx+S_ST], 4
    jnz     .Lgd_root
    test    qword ptr [rbx+S_ST], 2
    jnz     .Lgd_done
    cmp     qword ptr [rbx+S_H], 0
    jne     .Lgd_loop
    lea     rcx, [rbx+S_PATH]           # the first: FindFirstFileW
    lea     rdx, [rbx+S_FIND]
    call    [rip+__imp_FindFirstFileW]
    cmp     rax, -1
    jne     2f
    or      qword ptr [rbx+S_ST], 2
    call    w_errno
    cmp     rax, -2                     # (an empty folder)
    je      .Lgd_done
    jmp     .Lps_ret
2:  mov     [rbx+S_H], rax
    or      qword ptr [rbx+S_ST], 1
.Lgd_loop:
    test    qword ptr [rbx+S_ST], 1     # an entry waiting?
    jnz     3f
    mov     rcx, [rbx+S_H]
    lea     rdx, [rbx+S_FIND]
    call    [rip+__imp_FindNextFileW]
    test    eax, eax
    jnz     21f
    or      qword ptr [rbx+S_ST], 2     # no more
    jmp     .Lgd_done
21: or      qword ptr [rbx+S_ST], 1
3:  test    dword ptr [rbx+S_FIND], 6   # FILE_ATTRIBUTE_HIDDEN | SYSTEM
    jnz     5f
    lea     rcx, [rbx+S_FIND+44]        # cFileName
    xor     eax, eax
    mov     [rsp+48], rax
    mov     [rsp+56], rax
    lea     rax, [rip+w_u8]
    mov     [rsp+32], rax
    mov     qword ptr [rsp+40], 1024
    mov     r8, rcx
    mov     r9d, -1
    mov     ecx, CP_UTF8
    xor     edx, edx
    call    [rip+__imp_WideCharToMultiByte]
    test    eax, eax
    jz      5f
    mov     r12d, eax                   # the name's bytes with its 0
    lea     ecx, [rax+19+7]
    and     ecx, -8                     # the record's length
    lea     edx, [r15+rcx]
    cmp     edx, r14d
    jbe     4f
    test    r15d, r15d                  # no room: the next call
    jnz     .Lgd_done
    mov     rax, -22                    # EINVAL: not even one
    jmp     .Lps_ret
4:  lea     rdi, [r13+r15]
    mov     qword ptr [rdi], 1          # d_ino
    mov     qword ptr [rdi+8], 0        # d_off
    mov     [rdi+16], cx                # d_reclen
    mov     al, 8                       # d_type
    test    dword ptr [rbx+S_FIND], 0x10
    jz      41f
    mov     al, 4
41: mov     [rdi+18], al
    add     r15d, ecx
    add     rdi, 19
    lea     rsi, [rip+w_u8]
    mov     ecx, r12d
    rep     movsb
5:  and     qword ptr [rbx+S_ST], -2    # taken
    jmp     .Lgd_loop
.Lgd_root:                              # "/": the drives, as folders "C:"
    call    [rip+__imp_GetLogicalDrives]
    mov     r12d, eax
1:  mov     rcx, [rbx+S_DRV]
    cmp     ecx, 26
    jae     .Lgd_done
    bt      r12d, ecx
    jnc     2f
    lea     edx, [r15+24]
    cmp     edx, r14d
    ja      .Lgd_done
    lea     rdi, [r13+r15]
    mov     qword ptr [rdi], 1
    mov     qword ptr [rdi+8], 0
    mov     word ptr [rdi+16], 24
    mov     byte ptr [rdi+18], 4
    lea     eax, [rcx+'A']
    mov     [rdi+19], al
    mov     word ptr [rdi+20], ':'
    add     r15d, 24
2:  inc     qword ptr [rbx+S_DRV]
    jmp     1b
.Lgd_done:
    mov     eax, r15d
    jmp     .Lps_ret

# =============================================================================
#  The window
# =============================================================================
# w_create - the window class, the window (DEF_W x DEF_H at the monitor's
#   scale), the cursors and the configuration timer
w_create:
    WFRAME 64
    xor     ecx, ecx
    call    [rip+__imp_GetModuleHandleW]
    mov     [rip+w_inst], rax
    lea     rbx, [rip+w_cur]
    mov     r12d, 32512                 # IDC_ARROW
    call    w_load_cursor
    mov     r12d, 32513                 # IDC_IBEAM
    call    w_load_cursor
    mov     r12d, 32649                 # IDC_HAND
    call    w_load_cursor
    lea     rcx, [rip+w_wc]
    mov     dword ptr [rcx], 80         # cbSize
    lea     rax, [rip+wnd_proc]
    mov     [rcx+8], rax
    mov     rax, [rip+w_inst]
    mov     [rcx+24], rax
    lea     rax, [rip+w_class]
    mov     [rcx+64], rax
    mov     rdx, [rip+w_inst]           # the icon (the resource), if any
    mov     [rsp+40], rcx
    mov     rcx, rdx
    mov     edx, 1
    call    [rip+__imp_LoadIconW]
    lea     rcx, [rip+w_wc]
    mov     [rcx+32], rax
    mov     [rcx+72], rax
    call    [rip+__imp_RegisterClassExW]
    call    [rip+__imp_GetDpiForSystem]
    test    eax, eax
    jz      1f
    mov     [rip+w_dpi], eax
1:  call    w_apply_dpi
    mov     eax, [rip+w_dpi]            # the size at this scale, with the frame
    imul    eax, eax, DEF_W
    mov     ecx, 96
    xor     edx, edx
    div     ecx
    lea     rcx, [rip+w_rect]
    mov     dword ptr [rcx], 0
    mov     dword ptr [rcx+4], 0
    mov     [rcx+8], eax
    mov     eax, [rip+w_dpi]
    imul    eax, eax, DEF_H
    mov     r8d, 96
    xor     edx, edx
    div     r8d
    mov     [rcx+12], eax
    mov     edx, WS_OVERLAPPEDWINDOW
    xor     r8d, r8d
    mov     r9d, WS_EX_ACCEPTFILES
    mov     eax, [rip+w_dpi]
    mov     [rsp+32], rax
    call    [rip+__imp_AdjustWindowRectExForDpi]
    lea     rax, [rip+w_rect]
    mov     ecx, [rax+8]
    sub     ecx, [rax]
    mov     edx, [rax+12]
    sub     edx, [rax+4]
    mov     dword ptr [rsp+32], CW_USEDEFAULT   # x, y
    mov     dword ptr [rsp+36], 0
    mov     dword ptr [rsp+40], CW_USEDEFAULT
    mov     dword ptr [rsp+44], 0
    mov     [rsp+48], rcx               # width, height
    mov     [rsp+56], rdx
    mov     qword ptr [rsp+64], 0       # parent
    mov     qword ptr [rsp+72], 0       # menu
    mov     rax, [rip+w_inst]
    mov     [rsp+80], rax
    mov     qword ptr [rsp+88], 0
    mov     ecx, WS_EX_ACCEPTFILES
    lea     rdx, [rip+w_class]
    lea     r8, [rip+w_cap]
    mov     r9d, WS_OVERLAPPEDWINDOW
    call    [rip+__imp_CreateWindowExW]
    test    rax, rax
    jz      win_fail
    mov     [rip+w_hwnd], rax
    mov     rcx, rax                    # its monitor's DPI
    call    [rip+__imp_GetDpiForWindow]
    test    eax, eax
    jz      2f
    cmp     eax, [rip+w_dpi]
    je      2f
    mov     [rip+w_dpi], eax
    call    w_apply_dpi
2:  mov     rcx, [rip+w_hwnd]
    mov     edx, 1                      # SW_SHOWNORMAL (not the hidden start's)
    call    [rip+__imp_ShowWindow]
    mov     rcx, [rip+w_hwnd]
    call    [rip+__imp_SetForegroundWindow]
    mov     rcx, [rip+w_hwnd]           # the configuration's check, each second
    mov     edx, 1
    mov     r8d, 1000
    xor     r9d, r9d
    call    [rip+__imp_SetTimer]
    mov     dword ptr [rip+w_ready], 1
    lea     rdi, [rip+last_title]       # (a title set before the window)
    cmp     byte ptr [rdi], 0
    je      3f
    call    set_title
3:  WRET

w_load_cursor:                          # r12d = id -> [rbx], rbx += 8
    sub     rsp, 40
    xor     ecx, ecx
    mov     edx, r12d
    call    [rip+__imp_LoadCursorW]
    add     rsp, 40
    mov     [rbx], rax
    add     rbx, 8
    ret

# w_apply_dpi - w_dpi as the UI scale (96 dpi = 1.0); fonts at the new size
w_apply_dpi:
    sub     rsp, 8
    mov     eax, [rip+w_dpi]
    imul    eax, eax, 120
    mov     ecx, 96
    xor     edx, edx
    div     ecx
    mov     edi, eax
    call    set_ui_scale
    test    eax, eax
    jz      1f
    call    fonts_resize
    mov     dword ptr [rip+dirty], 1
1:  add     rsp, 8
    ret

# pump - one turn of the event loop, as main.s's: queued input, a frame
#   when one is due, then wait for Windows' messages and hand them out.
#   Dialogs and the prompt bar call it in their own loops.
pump:
    WFRAME
    call    process_events
    cmp     dword ptr [rip+quit_flag], 0
    jne     9f
    cmp     dword ptr [rip+dirty], 0
    je      1f
    call    render
1:  lea     rcx, [rip+w_msg]            # nothing waiting: sleep until there is
    xor     edx, edx
    xor     r8d, r8d
    xor     r9d, r9d
    mov     qword ptr [rsp+32], 0       # PM_NOREMOVE
    call    [rip+__imp_PeekMessageW]
    test    eax, eax
    jnz     2f
    xor     ecx, ecx
    xor     edx, edx
    xor     r8d, r8d
    mov     r9d, -1                     # INFINITE, or a frame's time when one is due
    cmp     dword ptr [rip+dirty], 0
    je      11f
    mov     r9d, 16
11: mov     qword ptr [rsp+32], 0x4FF   # QS_ALLINPUT
    call    [rip+__imp_MsgWaitForMultipleObjects]
2:  lea     rcx, [rip+w_msg]
    xor     edx, edx
    xor     r8d, r8d
    xor     r9d, r9d
    mov     qword ptr [rsp+32], 1       # PM_REMOVE
    call    [rip+__imp_PeekMessageW]
    test    eax, eax
    jz      3f
    cmp     dword ptr [rip+w_msg+8], WM_QUIT
    jne     21f
    mov     dword ptr [rip+quit_flag], 1
    jmp     3f
21: lea     rcx, [rip+w_msg]            # (TranslateMessage first: a key's
    call    [rip+__imp_TranslateMessage] #  WM_CHAR is then waiting for it)
    lea     rcx, [rip+w_msg]
    call    [rip+__imp_DispatchMessageW]
    jmp     2b
3:  call    process_events
9:  WRET

# render - draw the UI into memory at the client area's size and show it
render:
    WFRAME 112
    mov     rcx, [rip+w_hwnd]
    test    rcx, rcx
    jz      9f
    lea     rdx, [rip+w_rect]
    call    [rip+__imp_GetClientRect]
    mov     r12d, [rip+w_rect+8]        # width
    mov     r13d, [rip+w_rect+12]       # height
    test    r12d, r12d
    jle     8f
    test    r13d, r13d
    jle     8f
    mov     eax, r12d
    imul    eax, r13d
    shl     rax, 2
    mov     r14, rax                    # the bytes
    cmp     rax, [rip+w_buf_cap]
    jbe     2f
    mov     rcx, [rip+w_buf]            # grow (to a whole MiB)
    test    rcx, rcx
    jz      1f
    xor     edx, edx
    mov     r8d, 0x8000
    call    [rip+__imp_VirtualFree]
1:  add     r14, 0xFFFFF
    and     r14, -0x100000
    xor     ecx, ecx
    mov     rdx, r14
    mov     r8d, 0x3000
    mov     r9d, 4
    call    [rip+__imp_VirtualAlloc]
    test    rax, rax
    jz      win_fail
    mov     [rip+w_buf], rax
    mov     [rip+w_buf_cap], r14
2:  mov     rax, [rip+w_buf]
    mov     [rip+fb_ptr], rax
    mov     [rip+fb_w], r12d
    mov     [rip+fb_h], r13d
    mov     [rip+w_fbw], r12d
    mov     [rip+w_fbh], r13d
    call    ui_draw
    mov     rcx, [rip+w_hwnd]
    call    [rip+__imp_GetDC]
    mov     rbx, rax
    mov     rdi, rax
    call    w_blit
    mov     rcx, [rip+w_hwnd]
    mov     rdx, rbx
    call    [rip+__imp_ReleaseDC]
8:  mov     dword ptr [rip+dirty], 0
9:  WRET

# w_blit(rdi=hdc) - the last frame onto the window
w_blit:
    WFRAME 112
    lea     rax, [rip+w_bmi]            # BITMAPINFOHEADER: top-down, 32 bpp
    mov     dword ptr [rax], 40
    mov     ecx, [rip+w_fbw]
    mov     [rax+4], ecx
    mov     ecx, [rip+w_fbh]
    neg     ecx
    mov     [rax+8], ecx
    mov     word ptr [rax+12], 1
    mov     word ptr [rax+14], 32
    mov     dword ptr [rax+16], 0       # BI_RGB
    mov     rcx, rdi
    xor     edx, edx                    # to 0, 0, w, h
    xor     r8d, r8d
    mov     r9d, [rip+w_fbw]
    mov     eax, [rip+w_fbh]
    mov     [rsp+32], rax
    mov     qword ptr [rsp+40], 0       # from 0, 0, w, h
    mov     qword ptr [rsp+48], 0
    mov     eax, [rip+w_fbw]
    mov     [rsp+56], rax
    mov     eax, [rip+w_fbh]
    mov     [rsp+64], rax
    mov     rax, [rip+w_buf]
    mov     [rsp+72], rax
    lea     rax, [rip+w_bmi]
    mov     [rsp+80], rax
    mov     qword ptr [rsp+88], 0       # DIB_RGB_COLORS
    mov     qword ptr [rsp+96], 0xCC0020    # SRCCOPY
    call    [rip+__imp_StretchDIBits]
    WRET

# set_title(rdi=asciz) - the window's title
set_title:
    WFRAME
    cmp     qword ptr [rip+w_hwnd], 0
    je      9f
    mov     esi, -1
    lea     r8, [rip+w_title]
    mov     r9d, 511
    call    u2w
    test    eax, eax
    jz      9f
    mov     rcx, [rip+w_hwnd]
    lea     rdx, [rip+w_title]
    call    [rip+__imp_SetWindowTextW]
9:  WRET

# set_cursor(edi = cursor-shape-v1 shape) - the arrow, I-beam or hand
set_cursor:
    cmp     edi, [rip+cur_shape]
    je      9f
    mov     [rip+cur_shape], edi
    WFRAME
    call    w_cursor_now
    WRET
9:  ret

w_cursor_now:                           # SetCursor(cur_shape's)
    sub     rsp, 40
    mov     eax, [rip+cur_shape]
    mov     rcx, [rip+w_cur+8]          # SHAPE_TEXT: the I-beam
    cmp     eax, SHAPE_TEXT
    je      1f
    mov     rcx, [rip+w_cur+16]         # SHAPE_POINTER: the hand
    cmp     eax, SHAPE_POINTER
    je      1f
    mov     rcx, [rip+w_cur]
1:  call    [rip+__imp_SetCursor]
    add     rsp, 40
    ret

# =============================================================================
#  Messages
# =============================================================================
# wnd_proc(rcx=hwnd, edx=message, r8=wParam, r9=lParam) - called by Windows:
#   rbx, rbp, rsi, rdi, r12-r15 and xmm6-xmm15 are kept for it, as the
#   shared code (System V) may change them
wnd_proc:
    push    rbp
    mov     rbp, rsp
    push    rbx
    push    rsi
    push    rdi
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 168
    movdqu  [rbp-72], xmm6
    movdqu  [rbp-88], xmm7
    movdqu  [rbp-104], xmm8
    movdqu  [rbp-120], xmm9
    movdqu  [rbp-136], xmm10
    movdqu  [rbp-152], xmm11
    movdqu  [rbp-168], xmm12
    movdqu  [rbp-184], xmm13
    movdqu  [rbp-200], xmm14
    movdqu  [rbp-216], xmm15
    and     rsp, -16
    sub     rsp, 64
    mov     r12, rcx
    mov     r13d, edx
    mov     r14, r8
    mov     r15, r9
    cmp     r13d, WM_MOUSEMOVE
    je      .Lwp_move
    cmp     r13d, WM_LBUTTONDOWN
    je      .Lwp_ldown
    cmp     r13d, WM_LBUTTONUP
    je      .Lwp_lup
    cmp     r13d, WM_RBUTTONDOWN
    je      .Lwp_rdown
    cmp     r13d, WM_RBUTTONUP
    je      .Lwp_rup
    cmp     r13d, WM_MBUTTONDOWN
    je      .Lwp_mdown
    cmp     r13d, WM_MBUTTONUP
    je      .Lwp_mup
    cmp     r13d, WM_MOUSEWHEEL
    je      .Lwp_wheel
    cmp     r13d, WM_MOUSEHWHEEL
    je      .Lwp_hwheel
    cmp     r13d, WM_KEYDOWN
    je      .Lwp_keydown
    cmp     r13d, WM_SYSKEYDOWN
    je      .Lwp_keydown
    cmp     r13d, WM_KEYUP
    je      .Lwp_keyup
    cmp     r13d, WM_SYSKEYUP
    je      .Lwp_keyup
    cmp     r13d, WM_CHAR
    je      .Lwp_char
    cmp     r13d, WM_SYSCHAR
    je      .Lwp_zero                   # (Alt+letter: no beep; the key did it)
    cmp     r13d, WM_SETCURSOR
    je      .Lwp_setcursor
    cmp     r13d, WM_MOUSELEAVE
    je      .Lwp_leave
    cmp     r13d, WM_SIZE
    je      .Lwp_size
    cmp     r13d, WM_PAINT
    je      .Lwp_paint
    cmp     r13d, WM_ERASEBKGND
    je      .Lwp_one
    cmp     r13d, WM_TIMER
    je      .Lwp_timer
    cmp     r13d, WM_CLOSE
    je      .Lwp_close
    cmp     r13d, WM_DROPFILES
    je      .Lwp_drop
    cmp     r13d, WM_DPICHANGED
    je      .Lwp_dpi
    cmp     r13d, WM_GETMINMAXINFO
    je      .Lwp_minmax
.Lwp_def:
    mov     rcx, r12
    mov     edx, r13d
    mov     r8, r14
    mov     r9, r15
    call    [rip+__imp_DefWindowProcW]
    jmp     .Lwp_ret
.Lwp_one:
    mov     eax, 1
    jmp     .Lwp_ret
.Lwp_zero:
    xor     eax, eax
.Lwp_ret:
    movdqu  xmm6, [rbp-72]
    movdqu  xmm7, [rbp-88]
    movdqu  xmm8, [rbp-104]
    movdqu  xmm9, [rbp-120]
    movdqu  xmm10, [rbp-136]
    movdqu  xmm11, [rbp-152]
    movdqu  xmm12, [rbp-168]
    movdqu  xmm13, [rbp-184]
    movdqu  xmm14, [rbp-200]
    movdqu  xmm15, [rbp-216]
    lea     rsp, [rbp-56]
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rdi
    pop     rsi
    pop     rbx
    pop     rbp
    ret

# ---- the mouse ----------------------------------------------------------------
.Lwp_move:
    call    w_motion
    cmp     dword ptr [rip+w_track], 0  # (ask for WM_MOUSELEAVE)
    jne     .Lwp_zero
    lea     rcx, [rip+w_tme]
    mov     dword ptr [rcx], 24
    mov     dword ptr [rcx+4], 2        # TME_LEAVE
    mov     [rcx+8], r12
    mov     dword ptr [rcx+16], 0
    call    [rip+__imp_TrackMouseEvent]
    mov     dword ptr [rip+w_track], 1
    jmp     .Lwp_zero
.Lwp_leave:
    mov     dword ptr [rip+w_track], 0
    call    ui_leave
    jmp     .Lwp_zero
.Lwp_ldown:
    mov     ebx, BTN_LEFT
    jmp     .Lwp_down
.Lwp_rdown:
    mov     ebx, BTN_RIGHT
    jmp     .Lwp_down
.Lwp_mdown:
    mov     ebx, BTN_MIDDLE
.Lwp_down:
    mov     rcx, r12                    # the drag goes on outside the window
    call    [rip+__imp_SetCapture]
    call    w_motion
    call    [rip+__imp_GetMessageTime]
    mov     ecx, eax
    mov     edi, ebx
    mov     esi, 1
    xor     edx, edx
    call    ui_button
    jmp     .Lwp_zero
.Lwp_lup:
    mov     ebx, BTN_LEFT
    jmp     .Lwp_up
.Lwp_rup:
    mov     ebx, BTN_RIGHT
    jmp     .Lwp_up
.Lwp_mup:
    mov     ebx, BTN_MIDDLE
.Lwp_up:
    call    [rip+__imp_ReleaseCapture]
    call    w_motion
    call    [rip+__imp_GetMessageTime]
    mov     ecx, eax
    mov     edi, ebx
    xor     esi, esi
    xor     edx, edx
    call    ui_button
    jmp     .Lwp_zero
.Lwp_wheel:                             # 120 a notch, up: 10.0 (24.8) a notch, down
    mov     rax, r14
    shr     rax, 16
    movsx   eax, ax
    neg     eax
    xor     ebx, ebx
    jmp     1f
.Lwp_hwheel:
    mov     rax, r14
    shr     rax, 16
    movsx   eax, ax
    mov     ebx, 1
1:  imul    eax, eax, 2560
    cdq
    mov     ecx, 120
    idiv    ecx
    mov     r14d, eax
    call    w_mods_now
    mov     edi, ebx
    mov     esi, r14d
    call    ui_axis
    jmp     .Lwp_zero
.Lwp_setcursor:
    cmp     r15w, 1                     # HTCLIENT: ours
    jne     .Lwp_def
    call    w_cursor_now
    jmp     .Lwp_one

# w_motion - the pointer at r15 (lParam: client x, y), in logical px
w_motion:
    sub     rsp, 8
    call    w_mods_now
    movsx   edi, r15w
    call    to_lg
    push    rax
    sub     rsp, 8
    mov     eax, r15d
    shr     eax, 16
    movsx   edi, ax
    call    to_lg
    add     rsp, 8
    mov     esi, eax
    pop     rdi
    call    ui_motion
    add     rsp, 8
    ret

# w_mods_now - Shift, Ctrl, Alt as they are -> w_mods
w_mods_now:
    push    rbx
    sub     rsp, 32
    xor     ebx, ebx
    mov     ecx, VK_SHIFT
    call    [rip+__imp_GetKeyState]
    test    ax, ax
    jns     1f
    or      ebx, MOD_SHIFT
1:  mov     ecx, VK_CONTROL
    call    [rip+__imp_GetKeyState]
    test    ax, ax
    jns     2f
    or      ebx, MOD_CTRL
2:  mov     ecx, VK_MENU
    call    [rip+__imp_GetKeyState]
    test    ax, ax
    jns     3f
    or      ebx, MOD_ALT
3:  mov     [rip+w_mods], ebx
    add     rsp, 32
    pop     rbx
    ret

# ---- the keyboard -------------------------------------------------------------
.Lwp_keydown:
    cmp     r13d, WM_SYSKEYDOWN         # Alt+F4: Windows closes (WM_CLOSE)
    jne     1f
    cmp     r14d, VK_F4
    je      .Lwp_def
1:  call    w_evdev
    mov     ebx, eax
    call    w_mods_now
    mov     dword ptr [rip+w_char], 0   # what it types: its WM_CHAR, if any
    lea     rcx, [rip+w_msg]
    mov     rdx, r12
    mov     r8d, WM_CHAR
    mov     r9d, WM_DEADCHAR
    mov     qword ptr [rsp+32], 1       # PM_REMOVE
    call    [rip+__imp_PeekMessageW]
    test    eax, eax
    jnz     2f
    lea     rcx, [rip+w_msg]
    mov     rdx, r12
    mov     r8d, WM_SYSCHAR
    mov     r9d, WM_SYSDEADCHAR
    mov     qword ptr [rsp+32], 1
    call    [rip+__imp_PeekMessageW]
    test    eax, eax
    jz      4f
2:  mov     eax, [rip+w_msg+8]
    cmp     eax, WM_DEADCHAR            # a dead key: Windows composes it with the next
    je      4f
    cmp     eax, WM_SYSDEADCHAR
    je      4f
    movzx   eax, word ptr [rip+w_msg+16]
    mov     ecx, eax                    # a surrogate pair: the second WM_CHAR
    and     ecx, 0xFC00
    cmp     ecx, 0xD800
    jne     3f
    mov     [rip+w_hisur], eax
    lea     rcx, [rip+w_msg]
    mov     rdx, r12
    mov     r8d, WM_CHAR
    mov     r9d, WM_CHAR
    mov     qword ptr [rsp+32], 1
    call    [rip+__imp_PeekMessageW]
    test    eax, eax
    jz      4f
    movzx   eax, word ptr [rip+w_msg+16]
    call    w_surrogate
3:  cmp     eax, 0x20                   # control characters: the key says it
    jb      4f
    cmp     eax, 0x7f
    je      4f
    mov     [rip+w_char], eax
    mov     ecx, [rip+w_mods]           # AltGr (Ctrl + Alt) typed it: not a shortcut
    and     ecx, MOD_CTRL | MOD_ALT
    cmp     ecx, MOD_CTRL | MOD_ALT
    jne     4f
    and     dword ptr [rip+w_mods], ~(MOD_CTRL | MOD_ALT)
4:  mov     ecx, r14d                   # its letter in this layout (Ctrl+Z on AZERTY)
    mov     edx, 2                      # MAPVK_VK_TO_CHAR
    call    [rip+__imp_MapVirtualKeyW]
    mov     [rip+w_layout], ebx
    and     eax, 0xFFFF
    sub     eax, 'A'
    cmp     eax, 25
    ja      6f
    add     eax, 'A'
    lea     rdx, [rip+key_chars]
    xor     ecx, ecx
5:  cmp     [rdx+rcx], al
    je      51f
    inc     ecx
    cmp     ecx, 58
    jb      5b
    jmp     6f
51: mov     [rip+w_layout], ecx
6:  test    ebx, ebx
    jz      .Lwp_zero
    mov     edi, ebx
    mov     esi, 1
    call    ui_key
    jmp     .Lwp_zero                   # (WM_SYSKEYDOWN too: no system menu on Alt, F10)
.Lwp_keyup:
    call    w_evdev
    test    eax, eax
    jz      .Lwp_zero
    mov     edi, eax
    xor     esi, esi
    call    ui_key
    jmp     .Lwp_zero
.Lwp_char:                              # text without its key: an IME, the emoji panel
    movzx   eax, r14w
    mov     ecx, eax
    and     ecx, 0xFC00
    cmp     ecx, 0xD800
    jne     1f
    mov     [rip+w_hisur], eax
    jmp     .Lwp_zero
1:  cmp     ecx, 0xDC00
    jne     2f
    call    w_surrogate
2:  cmp     eax, 0x20
    jb      .Lwp_zero
    cmp     eax, 0x7f
    je      .Lwp_zero
    mov     [rip+w_char], eax
    mov     dword ptr [rip+w_mods], 0
    mov     dword ptr [rip+w_layout], 0
    xor     edi, edi
    mov     esi, 1
    call    ui_key
    jmp     .Lwp_zero

# w_surrogate(eax=low surrogate) -> eax = the code point with w_hisur
w_surrogate:
    mov     ecx, [rip+w_hisur]
    sub     ecx, 0xD800
    shl     ecx, 10
    sub     eax, 0xDC00
    add     eax, ecx
    add     eax, 0x10000
    ret

# w_evdev -> eax = the evdev code of the key in r14 (wParam: the virtual
#   key) and r15 (lParam: the scan code, bit 24 extended); 0 if none
w_evdev:
    push    rbx
    sub     rsp, 32
    mov     eax, r15d
    shr     eax, 16
    movzx   ebx, al                     # the scan code
    bt      r15d, 24
    setc    cl
    movzx   ecx, cl
    test    ebx, ebx                    # (made up without one: from the key)
    jnz     1f
    mov     ecx, r14d
    mov     edx, 4                      # MAPVK_VK_TO_VSC_EX
    call    [rip+__imp_MapVirtualKeyW]
    movzx   ebx, al
    xor     ecx, ecx
    cmp     ah, 0xE0
    sete    cl
1:  mov     eax, ebx
    test    ecx, ecx
    jz      9f
    lea     rdx, [rip+ext_keys]
2:  movzx   eax, byte ptr [rdx]
    test    eax, eax
    jz      9f
    cmp     eax, ebx
    je      3f
    add     rdx, 2
    jmp     2b
3:  movzx   eax, byte ptr [rdx+1]
9:  add     rsp, 32
    pop     rbx
    ret

# ---- the window -----------------------------------------------------------------
.Lwp_size:
    cmp     r14d, 1                     # SIZE_MINIMIZED
    je      .Lwp_zero
    cmp     dword ptr [rip+w_ready], 0
    je      .Lwp_zero
    mov     dword ptr [rip+dirty], 1
    call    render                      # (also while a border is dragged)
    jmp     .Lwp_zero
.Lwp_paint:
    mov     rcx, r12
    lea     rdx, [rip+w_ps]
    call    [rip+__imp_BeginPaint]
    mov     rbx, rax
    cmp     qword ptr [rip+w_buf], 0
    je      1f
    mov     rcx, r12
    lea     rdx, [rip+w_rect]
    call    [rip+__imp_GetClientRect]
    mov     eax, [rip+w_rect+8]
    cmp     eax, [rip+w_fbw]
    jne     1f
    mov     eax, [rip+w_rect+12]
    cmp     eax, [rip+w_fbh]
    jne     1f
    mov     rdi, rbx
    call    w_blit
    jmp     2f
1:  mov     dword ptr [rip+dirty], 1
2:  mov     rcx, r12
    lea     rdx, [rip+w_ps]
    call    [rip+__imp_EndPaint]
    jmp     .Lwp_zero
.Lwp_timer:                             # the configuration and theme, each second
    call    theme_check
    test    eax, 2
    jz      1f
    call    ui_config_changed
1:  test    eax, eax
    jz      .Lwp_zero
    mov     dword ptr [rip+dirty], 1
    jmp     .Lwp_zero
.Lwp_close:
    call    request_quit                # (queued: unsaved changes ask first)
    jmp     .Lwp_zero
.Lwp_drop:                              # files dropped on the window: the first opens
    mov     rcx, r14
    xor     edx, edx
    lea     r8, [rip+wp1]
    mov     r9d, WPATH_N
    call    [rip+__imp_DragQueryFileW]
    mov     ebx, eax
    mov     rcx, r14
    call    [rip+__imp_DragFinish]
    test    ebx, ebx
    jz      .Lwp_zero
    cmp     ebx, WPATH_N
    jae     .Lwp_zero
    lea     rdi, [rip+wp1]
    lea     rsi, [rip+w_u8]
    mov     edx, 1024
    call    w_upath
    test    rax, rax
    js      .Lwp_zero
    lea     rdi, [rip+w_u8]
    call    ui_drop_file
    mov     rcx, r12
    call    [rip+__imp_SetForegroundWindow]
    jmp     .Lwp_zero
.Lwp_dpi:                               # another monitor: its scale, its size
    movzx   eax, r14w
    mov     [rip+w_dpi], eax
    call    w_apply_dpi
    mov     rax, r15                    # the suggested rectangle
    mov     rcx, r12
    xor     edx, edx
    mov     r8d, [rax]
    mov     r9d, [rax+4]
    mov     r10d, [rax+8]
    sub     r10d, r8d
    mov     [rsp+32], r10
    mov     r10d, [rax+12]
    sub     r10d, r9d
    mov     [rsp+40], r10
    mov     qword ptr [rsp+48], 0x14    # SWP_NOZORDER | SWP_NOACTIVATE
    call    [rip+__imp_SetWindowPos]
    mov     dword ptr [rip+dirty], 1
    jmp     .Lwp_zero
.Lwp_minmax:                            # MIN_W x MIN_H at this scale (and the frame)
    mov     eax, [rip+w_dpi]
    imul    eax, eax, MIN_W + 16
    xor     edx, edx
    mov     ecx, 96
    div     ecx
    mov     [r15+24], eax               # ptMinTrackSize
    mov     eax, [rip+w_dpi]
    imul    eax, eax, MIN_H + 40
    xor     edx, edx
    div     ecx
    mov     [r15+28], eax
    jmp     .Lwp_zero

# =============================================================================
#  The keyboard, as keyboard.s gives it to input.s
# =============================================================================
kb_text:                                # (edi=evdev) -> eax = the text it types
    mov     eax, [rip+w_char]
    ret
kb_canon_mods:                          # -> eax = MOD_SHIFT | MOD_CTRL | MOD_ALT
    mov     eax, [rip+w_mods]
    ret
kb_layout_code:                         # (edi=evdev) -> eax = the QWERTY code of its letter
    mov     eax, [rip+w_layout]
    ret
kb_compose:                             # (Windows composes dead keys itself)
    xor     eax, eax
    ret
kb_repeat_start:                        # (Windows repeats keys itself)
    mov     [rip+rep_code], edi
    ret
kb_repeat_stop:
    mov     dword ptr [rip+rep_code], 0
    ret

# =============================================================================
#  The clipboard
# =============================================================================
# clip_copy(rdi=text, esi=bytes) - it becomes the clipboard (CF_UNICODETEXT,
#   CRLF line ends); our copy is pasted back as it was
clip_copy:
    WFRAME 16
    cmp     esi, CLIP_CAP-1
    jbe     1f
    mov     esi, CLIP_CAP-1
1:  mov     [rip+clip_len], esi
    mov     ecx, esi
    mov     rsi, rdi
    lea     rdi, [rip+clip_buf]
    rep     movsb
    mov     byte ptr [rdi], 0
    mov     dword ptr [rip+clip_own], 1
    lea     rsi, [rip+clip_buf]         # LF -> CRLF
    lea     rdi, [rip+clip_crlf]
    mov     ecx, [rip+clip_len]
2:  test    ecx, ecx
    jz      3f
    lodsb
    cmp     al, 10
    jne     21f
    cmp     rsi, offset clip_buf+1      # (not after a CR already)
    je      20f
    cmp     byte ptr [rsi-2], 13
    je      21f
20: mov     byte ptr [rdi], 13
    inc     rdi
21: stosb
    dec     ecx
    jmp     2b
3:  lea     rax, [rip+clip_crlf]
    sub     rdi, rax
    mov     r12d, edi                   # the bytes
    lea     rdi, [rip+clip_crlf]        # the UTF-16 units
    mov     esi, r12d
    xor     r8d, r8d
    xor     r9d, r9d
    xor     eax, eax
    test    esi, esi
    jz      4f
    call    u2w
4:  mov     r13d, eax
    mov     ecx, 2                      # GMEM_MOVEABLE
    lea     edx, [r13*2+2]
    call    [rip+__imp_GlobalAlloc]
    test    rax, rax
    jz      9f
    mov     rbx, rax
    mov     rcx, rax
    call    [rip+__imp_GlobalLock]
    test    rax, rax
    jz      8f
    mov     r14, rax
    mov     word ptr [r14+r13*2], 0
    test    r13d, r13d
    jz      5f
    lea     rdi, [rip+clip_crlf]
    mov     esi, r12d
    mov     r8, r14
    mov     r9d, r13d
    call    u2w
5:  mov     rcx, rbx
    call    [rip+__imp_GlobalUnlock]
    call    w_open_clip
    test    eax, eax
    jz      8f
    call    [rip+__imp_EmptyClipboard]
    mov     ecx, 13                     # CF_UNICODETEXT (the clipboard owns it now)
    mov     rdx, rbx
    call    [rip+__imp_SetClipboardData]
    mov     r15, rax
    call    [rip+__imp_CloseClipboard]
    test    r15, r15
    jz      8f
    call    [rip+__imp_GetClipboardSequenceNumber]
    mov     [rip+w_clipseq], rax
    jmp     9f
8:  mov     rcx, rbx
    call    [rip+__imp_GlobalFree]
9:  WRET

# clip_paste(rdi=dest, esi=capacity) -> eax = bytes (0-ended; 0 if none):
#   our own copy while the clipboard is still ours, else the clipboard's
clip_paste:
    WFRAME 32
    mov     rbx, rdi
    lea     r12d, [rsi-1]
    xor     r13d, r13d                  # bytes
    call    [rip+__imp_GetClipboardSequenceNumber]
    cmp     dword ptr [rip+clip_own], 0
    je      2f
    cmp     rax, [rip+w_clipseq]
    jne     2f
    mov     ecx, [rip+clip_len]
    cmp     ecx, r12d
    cmova   ecx, r12d
    mov     r13d, ecx
    lea     rsi, [rip+clip_buf]
    mov     rdi, rbx
    rep     movsb
    jmp     8f
2:  mov     dword ptr [rip+clip_own], 0
    call    w_open_clip
    test    eax, eax
    jz      8f
    mov     ecx, 13
    call    [rip+__imp_GetClipboardData]
    test    rax, rax
    jz      7f
    mov     r14, rax
    mov     rcx, rax
    call    [rip+__imp_GlobalLock]
    test    rax, rax
    jz      7f
    mov     rdi, rax
    mov     esi, -1
    mov     r8, rbx
    mov     r9d, r12d
    call    w2u
    test    eax, eax
    jz      6f
    lea     r13d, [rax-1]
6:  mov     rcx, r14
    call    [rip+__imp_GlobalUnlock]
7:  call    [rip+__imp_CloseClipboard]
8:  mov     byte ptr [rbx+r13], 0
    mov     eax, r13d
    WRET

# w_open_clip -> eax = 1 when the clipboard is open (another program may
#   hold it a moment)
w_open_clip:
    push    rbx
    sub     rsp, 32
    mov     ebx, 20
1:  mov     rcx, [rip+w_hwnd]
    call    [rip+__imp_OpenClipboard]
    test    eax, eax
    jnz     9f
    mov     ecx, 5
    call    [rip+__imp_Sleep]
    dec     ebx
    jnz     1b
    xor     eax, eax
9:  add     rsp, 32
    pop     rbx
    ret

# ---- the imports ----------------------------------------------------------------
# ld puts the .idata$N sections in order and points the PE header at them:
# $2 one entry per DLL (and an empty one to end), $4 the lookup table, $5
# the address table the loader fills (__imp_X: call [rip+__imp_X]), $6 the
# names, $7 the DLL names. Subsection n of $4/$5 is DLL n's run, ended by 0;
# src/plat_win.ld ends the $2 list. (From BeeModel's plat_win.s.)
.macro DLL n, name
    .section .idata$2,"a"
    .long   dll_ilt_\n - IMAGE_BASE, 0, 0, dll_name_\n - IMAGE_BASE, dll_iat_\n - IMAGE_BASE
    .section .idata$4,"a"
    .subsection \n
dll_ilt_\n:
    .section .idata$5,"aw"
    .subsection \n
dll_iat_\n:
    .section .idata$7,"a"
dll_name_\n: .asciz "\name"
.endm
.macro IMPORT n, func
    .section .idata$6,"a"
    .balign 2
imp_name_\func: .short 0
    .asciz "\func"
    .section .idata$4,"a"
    .subsection \n
    .quad   imp_name_\func - IMAGE_BASE
    .section .idata$5,"aw"
    .subsection \n
__imp_\func: .quad imp_name_\func - IMAGE_BASE
.endm
.macro DLL_END n
    .section .idata$4,"a"
    .subsection \n
    .quad   0
    .section .idata$5,"aw"
    .subsection \n
    .quad   0
.endm

DLL 1, KERNEL32.dll
IMPORT 1, AttachConsole
IMPORT 1, CloseHandle
IMPORT 1, CreateDirectoryW
IMPORT 1, CreateFileW
IMPORT 1, ExitProcess
IMPORT 1, FindClose
IMPORT 1, FindFirstFileW
IMPORT 1, FindNextFileW
IMPORT 1, GetCommandLineW
IMPORT 1, GetCurrentDirectoryW
IMPORT 1, GetEnvironmentStringsW
IMPORT 1, GetFileAttributesExW
IMPORT 1, GetFileAttributesW
IMPORT 1, GetFileSizeEx
IMPORT 1, GetLastError
IMPORT 1, GetLogicalDrives
IMPORT 1, GetModuleHandleW
IMPORT 1, GetStdHandle
IMPORT 1, GlobalAlloc
IMPORT 1, GlobalFree
IMPORT 1, GlobalLock
IMPORT 1, GlobalUnlock
IMPORT 1, MoveFileExW
IMPORT 1, MultiByteToWideChar
IMPORT 1, ReadFile
IMPORT 1, SetFilePointerEx
IMPORT 1, Sleep
IMPORT 1, VirtualAlloc
IMPORT 1, VirtualFree
IMPORT 1, WideCharToMultiByte
IMPORT 1, WriteFile
DLL_END 1

DLL 2, USER32.dll
IMPORT 2, AdjustWindowRectExForDpi
IMPORT 2, BeginPaint
IMPORT 2, CloseClipboard
IMPORT 2, CreateWindowExW
IMPORT 2, DefWindowProcW
IMPORT 2, DispatchMessageW
IMPORT 2, EmptyClipboard
IMPORT 2, EndPaint
IMPORT 2, GetClientRect
IMPORT 2, GetClipboardData
IMPORT 2, GetClipboardSequenceNumber
IMPORT 2, GetDC
IMPORT 2, GetDpiForSystem
IMPORT 2, GetDpiForWindow
IMPORT 2, GetKeyState
IMPORT 2, GetMessageTime
IMPORT 2, LoadCursorW
IMPORT 2, LoadIconW
IMPORT 2, MapVirtualKeyW
IMPORT 2, MsgWaitForMultipleObjects
IMPORT 2, OpenClipboard
IMPORT 2, PeekMessageW
IMPORT 2, RegisterClassExW
IMPORT 2, ReleaseCapture
IMPORT 2, ReleaseDC
IMPORT 2, SetCapture
IMPORT 2, SetClipboardData
IMPORT 2, SetCursor
IMPORT 2, SetForegroundWindow
IMPORT 2, SetProcessDpiAwarenessContext
IMPORT 2, SetTimer
IMPORT 2, SetWindowPos
IMPORT 2, SetWindowTextW
IMPORT 2, ShowWindow
IMPORT 2, TrackMouseEvent
IMPORT 2, TranslateMessage
DLL_END 2

DLL 3, GDI32.dll
IMPORT 3, StretchDIBits
DLL_END 3

DLL 4, SHELL32.dll
IMPORT 4, DragFinish
IMPORT 4, DragQueryFileW
DLL_END 4
