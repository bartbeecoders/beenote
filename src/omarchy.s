# =============================================================================
#  BeeNote - Omarchy integration: the colours of the current Omarchy theme
#  (~/.local/state/omarchy/current/theme/colors.toml) and BeeNote's own
#  configuration (~/.config/beenote/beenote.conf: the font and its size,
#  which scripts/deploy-omarchy.sh and its font-set hook keep in step with
#  `omarchy font`). Both files are checked once a second, so a theme or
#  font switch shows at once.
#
#  colors.toml lines look like:   accent = "#81a1c1"
#  beenote.conf lines look like:  font = /usr/share/fonts/TTF/X.ttf
#                                 size = 12          (points, as Omarchy's)
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "beenote.inc"

.globl th_col
.globl theme_init
.globl theme_check
.globl th_fd
.globl cfg_font
.globl cfg_size
.globl home_path

.equ SYS_STAT,              4
.equ SYS_TIMERFD_CREATE,    283
.equ SYS_TIMERFD_SETTIME,   286
.equ FILE_MAX,              16384

.section .data
.align 4
th_fd:          .long -1
# Tokyo Night (Omarchy's default theme) until the file says otherwise
th_default:     .long 0x1a1b26, 0xa9b1d6, 0x7aa2f7, 0x283457, 0x565f89
                .long 0x16161e, 0x292e42, 0x565f89, 0xc0caf5, 0xf7768e
                .long 0xe0af68, 0x9ece6a, 0x1f2335

.section .bss
.align 8
th_col:         .skip C_N*4
cfg_size:       .skip 4                 # points (0: not set)
.align 8
col_sig:        .skip 32                # the files as last read (stat)
cfg_sig:        .skip 32
statbuf:        .skip 144
itimer:         .skip 32
tick:           .skip 8
col_path:       .skip 512
cfg_path:       .skip 512
cfg_font:       .skip 1024
fbuf:           .skip FILE_MAX

.section .rodata
s_home:         .asciz "HOME="
s_col_rel:      .asciz "/.local/state/omarchy/current/theme/colors.toml"
s_cfg_rel:      .asciz "/.config/beenote/beenote.conf"
k_background:   .asciz "background"
k_foreground:   .asciz "foreground"
k_accent:       .asciz "accent"
k_selection:    .asciz "selection"
k_muted:        .asciz "muted"
k_dark_bg:      .asciz "dark_background"
k_light_bg:     .asciz "lighter_background"
k_dark_fg:      .asciz "dark_foreground"
k_light_fg:     .asciz "light_foreground"
k_red:          .asciz "red"
k_yellow:       .asciz "yellow"
k_green:        .asciz "green"
k_font:         .asciz "font"
k_size:         .asciz "size"
.align 8
col_keys:       .quad k_background, C_BG, k_foreground, C_FG, k_accent, C_ACCENT
                .quad k_selection, C_SEL, k_muted, C_MUTED, k_dark_bg, C_BG_DARK
                .quad k_light_bg, C_BG_LIGHT, k_dark_fg, C_FG_DIM, k_light_fg, C_FG_LIGHT
                .quad k_red, C_RED, k_yellow, C_YELLOW, k_green, C_GREEN, 0

.text

# home_path(rdi=dest, rsi=suffix) - $HOME followed by the suffix
home_path:
    push    rbx
    push    r12
    mov     rbx, rdi
    mov     r12, rsi
    lea     rdi, [rip+s_home]
    call    getenv
    test    rax, rax
    jz      2f
    mov     rsi, rax
1:  mov     al, [rsi]                   # (paths stay well inside 512 bytes)
    test    al, al
    jz      2f
    mov     [rbx], al
    inc     rbx
    inc     rsi
    jmp     1b
2:  mov     al, [r12]
    mov     [rbx], al
    inc     rbx
    inc     r12
    test    al, al
    jnz     2b
    pop     r12
    pop     rbx
    ret

# read_file(rdi=path) -> rax = bytes read into fbuf (0-ended), -1 if none
read_file:
    push    rbx
    mov     eax, 2                      # open
    mov     esi, 0x80000                # O_RDONLY | O_CLOEXEC
    xor     edx, edx
    call    plat_sys
    test    rax, rax
    js      8f
    mov     rbx, rax
    xor     eax, eax                    # read (one call: these files are small)
    mov     rdi, rbx
    lea     rsi, [rip+fbuf]
    mov     edx, FILE_MAX-1
    call    plat_sys
    push    rax
    mov     eax, SYS_CLOSE
    mov     rdi, rbx
    call    plat_sys
    pop     rax
    test    rax, rax
    js      8f
    lea     rcx, [rip+fbuf]
    mov     byte ptr [rcx+rax], 0
    pop     rbx
    ret
8:  mov     rax, -1
    pop     rbx
    ret

# next_kv(rsi=cursor) -> rdi = key, rdx = value (both 0-ended in place, the
#   value without quotes), rsi = the next line; rdi = 0 at the end.
#   Comments, [sections] and lines without '=' are skipped.
next_kv:
1:  movzx   eax, byte ptr [rsi]         # blank space and empty lines
    test    eax, eax
    jz      8f
    cmp     eax, ' '
    ja      2f
    inc     rsi
    jmp     1b
2:  cmp     eax, '#'
    je      7f
    cmp     eax, '['
    je      7f
    mov     rdi, rsi                    # the key
3:  movzx   eax, byte ptr [rsi]
    test    eax, eax
    jz      8f
    cmp     eax, 10
    je      1b
    cmp     eax, '='
    je      4f
    cmp     eax, ' '
    je      4f
    cmp     eax, 9
    je      4f
    inc     rsi
    jmp     3b
4:  mov     r8, rsi                     # (its end)
41: movzx   eax, byte ptr [rsi]         # then '='
    cmp     eax, ' '
    je      42f
    cmp     eax, 9
    je      42f
    cmp     eax, '='
    jne     7f
    mov     byte ptr [r8], 0
    inc     rsi
    jmp     5f
42: inc     rsi
    jmp     41b
5:  movzx   eax, byte ptr [rsi]         # spaces and an opening quote
    cmp     eax, ' '
    je      51f
    cmp     eax, 9
    je      51f
    cmp     eax, '"'
    je      51f
    cmp     eax, 39
    jne     52f
51: inc     rsi
    jmp     5b
52: mov     rdx, rsi                    # the value: to the line's end
6:  movzx   eax, byte ptr [rsi]
    test    eax, eax
    jz      61f
    cmp     eax, 10
    je      61f
    inc     rsi
    jmp     6b
61: mov     rcx, rsi                    # trim blanks, a closing quote, '\r'
62: cmp     rcx, rdx
    jbe     64f
    movzx   eax, byte ptr [rcx-1]
    cmp     eax, ' '
    je      63f
    cmp     eax, 9
    je      63f
    cmp     eax, 13
    je      63f
    cmp     eax, '"'
    je      63f
    cmp     eax, 39
    jne     64f
63: dec     rcx
    jmp     62b
64: cmp     byte ptr [rsi], 0           # the next line (before the 0 goes in)
    je      65f
    inc     rsi
65: mov     byte ptr [rcx], 0
    ret
7:  movzx   eax, byte ptr [rsi]         # skip to the next line
    test    eax, eax
    jz      8f
    inc     rsi
    cmp     eax, 10
    jne     7b
    jmp     1b
8:  xor     edi, edi
    ret

# hex_colour(rdi=text) -> eax = 0xRRGGBB, or -1 when it is not "#rrggbb"
hex_colour:
    cmp     byte ptr [rdi], '#'
    jne     8f
    xor     eax, eax
    mov     ecx, 1
1:  movzx   edx, byte ptr [rdi+rcx]
    sub     edx, '0'
    cmp     edx, 9
    jbe     2f
    or      edx, 0x20
    sub     edx, 'a' - '0'
    cmp     edx, 5
    ja      8f
    add     edx, 10
2:  shl     eax, 4
    or      eax, edx
    inc     ecx
    cmp     ecx, 7
    jb      1b
    ret
8:  mov     eax, -1
    ret

# blend(edi=a, esi=b, edx=weight of b /16) -> eax
blend:
    push    rbx
    xor     eax, eax
    mov     r10d, 16
    sub     r10d, edx
    xor     ecx, ecx                    # bit offset
1:  mov     r8d, edi
    shr     r8d, cl
    and     r8d, 255
    imul    r8d, r10d
    mov     r9d, esi
    shr     r9d, cl
    and     r9d, 255
    imul    r9d, edx
    add     r8d, r9d
    shr     r8d, 4
    shl     r8d, cl
    or      eax, r8d
    add     ecx, 8
    cmp     ecx, 24
    jb      1b
    pop     rbx
    ret

load_colours:
    push    rbx
    push    r12
    lea     rsi, [rip+th_default]       # start from the defaults
    lea     rdi, [rip+th_col]
    mov     ecx, C_N*4
    rep     movsb
    lea     rdi, [rip+col_path]
    call    read_file
    test    rax, rax
    js      8f
    lea     rsi, [rip+fbuf]
1:  call    next_kv
    test    rdi, rdi
    jz      8f
    mov     rbx, rdi                    # key
    mov     r12, rdx                    # value
    push    rsi
    lea     r8, [rip+col_keys]
2:  mov     rsi, [r8]
    test    rsi, rsi
    jz      4f
    push    r8
    mov     rdi, rbx
    call    str_eq
    pop     r8
    test    eax, eax
    jnz     3f
    add     r8, 16
    jmp     2b
3:  mov     rdi, r12
    push    r8
    call    hex_colour
    pop     r8
    cmp     eax, -1
    je      4f
    mov     rcx, [r8+8]
    lea     rdx, [rip+th_col]
    mov     [rdx+rcx], eax
4:  pop     rsi
    jmp     1b
8:  lea     rbx, [rip+th_col]           # the cursor's line: a shade lighter
    mov     edi, [rbx+C_BG]
    mov     esi, [rbx+C_BG_LIGHT]
    mov     edx, 6
    call    blend
    mov     [rbx+C_CURLINE], eax
    mov     dword ptr [rip+dirty], 1
    pop     r12
    pop     rbx
    ret

load_config:
    push    rbx
    push    r12
    mov     byte ptr [rip+cfg_font], 0
    mov     dword ptr [rip+cfg_size], 0
    lea     rdi, [rip+cfg_path]
    call    read_file
    test    rax, rax
    js      8f
    lea     rsi, [rip+fbuf]
1:  call    next_kv
    test    rdi, rdi
    jz      8f
    mov     rbx, rdi
    mov     r12, rdx
    push    rsi
    mov     rdi, rbx
    lea     rsi, [rip+k_font]
    call    str_eq
    test    eax, eax
    jz      3f
    lea     rdi, [rip+cfg_font]         # font = path
    xor     ecx, ecx
2:  mov     al, [r12+rcx]
    mov     [rdi+rcx], al
    inc     ecx
    test    al, al
    jz      5f
    cmp     ecx, 1023
    jb      2b
    mov     byte ptr [rdi+rcx], 0
    jmp     5f
3:  mov     rdi, rbx                    # size = points
    lea     rsi, [rip+k_size]
    call    str_eq
    test    eax, eax
    jz      5f
    xor     eax, eax
    xor     ecx, ecx
4:  movzx   edx, byte ptr [r12+rcx]
    sub     edx, '0'
    cmp     edx, 9
    ja      41f
    imul    eax, eax, 10
    add     eax, edx
    inc     ecx
    cmp     ecx, 4
    jb      4b
41: cmp     eax, 4
    jb      5f
    cmp     eax, 72
    ja      5f
    mov     [rip+cfg_size], eax
5:  pop     rsi
    jmp     1b
8:  pop     r12
    pop     rbx
    ret

# file_sig(rdi=path, rsi=signature) -> eax = 1 when the file changed since
#   the signature was taken (inode, size and time; missing counts as zeros)
file_sig:
    push    rbx
    mov     rbx, rsi
    mov     eax, SYS_STAT
    lea     rsi, [rip+statbuf]
    call    plat_sys
    lea     rdx, [rip+statbuf]
    test    rax, rax
    jz      1f
    xor     eax, eax                    # gone: zeros
    mov     [rdx+8], rax
    mov     [rdx+48], rax
    mov     [rdx+88], rax
    mov     [rdx+96], rax
1:  xor     eax, eax
    mov     rcx, [rdx+8]                # st_ino
    cmp     rcx, [rbx]
    je      2f
    mov     eax, 1
2:  mov     [rbx], rcx
    mov     rcx, [rdx+48]               # st_size
    cmp     rcx, [rbx+8]
    je      3f
    mov     eax, 1
3:  mov     [rbx+8], rcx
    mov     rcx, [rdx+88]               # st_mtime
    cmp     rcx, [rbx+16]
    je      4f
    mov     eax, 1
4:  mov     [rbx+16], rcx
    mov     rcx, [rdx+96]               # st_mtime_nsec
    cmp     rcx, [rbx+24]
    je      5f
    mov     eax, 1
5:  mov     [rbx+24], rcx
    pop     rbx
    ret

# theme_init - paths, the colours, the configuration, and the 1 s timer
theme_init:
    lea     rdi, [rip+col_path]
    lea     rsi, [rip+s_col_rel]
    call    home_path
    lea     rdi, [rip+cfg_path]
    lea     rsi, [rip+s_cfg_rel]
    call    home_path
    lea     rdi, [rip+col_path]
    lea     rsi, [rip+col_sig]
    call    file_sig
    call    load_colours
    lea     rdi, [rip+cfg_path]
    lea     rsi, [rip+cfg_sig]
    call    file_sig
    call    load_config
    mov     edi, 1                      # CLOCK_MONOTONIC
    mov     esi, 0x80800                # TFD_CLOEXEC | TFD_NONBLOCK
    mov     eax, SYS_TIMERFD_CREATE
    call    plat_sys
    mov     [rip+th_fd], eax
    test    eax, eax
    js      9f
    lea     rdx, [rip+itimer]
    mov     qword ptr [rdx], 1          # every second
    mov     qword ptr [rdx+8], 0
    mov     qword ptr [rdx+16], 1
    mov     qword ptr [rdx+24], 0
    mov     edi, eax
    xor     esi, esi
    xor     r10d, r10d
    mov     eax, SYS_TIMERFD_SETTIME
    call    plat_sys
9:  ret

# theme_check - the timer fired: reload what changed
#   -> eax = bit 0 colours reloaded, bit 1 configuration reloaded
theme_check:
    push    rbx
    mov     edi, [rip+th_fd]            # (consume the tick)
    lea     rsi, [rip+tick]
    mov     edx, 8
    xor     eax, eax
    call    plat_sys
    xor     ebx, ebx
    lea     rdi, [rip+col_path]
    lea     rsi, [rip+col_sig]
    call    file_sig
    test    eax, eax
    jz      1f
    call    load_colours
    or      ebx, 1
1:  lea     rdi, [rip+cfg_path]
    lea     rsi, [rip+cfg_sig]
    call    file_sig
    test    eax, eax
    jz      2f
    call    load_config
    or      ebx, 2
2:  mov     eax, ebx
    pop     rbx
    ret

.section .note.GNU-stack,"",@progbits
