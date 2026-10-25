# =============================================================================
#  BeeNote - a terminal notepad written in x86-64 assembly
#  Linux only, no libc: talks to the kernel directly through syscalls.
#
#  Build:  as beenote.s -o beenote.o && ld beenote.o -o beenote
#  Run:    ./beenote [file]
#
#  Calling convention used internally: args in rdi, rsi, rdx, rcx, r8, r9;
#  result in rax (+rdx/rsi when noted). rbx, rbp, r12-r15 are preserved,
#  everything else may be clobbered.
# =============================================================================
    .intel_syntax noprefix

# ---- syscalls ---------------------------------------------------------------
    .equ SYS_READ, 0
    .equ SYS_WRITE, 1
    .equ SYS_OPEN, 2
    .equ SYS_CLOSE, 3
    .equ SYS_RT_SIGACTION, 13
    .equ SYS_RT_SIGRETURN, 15
    .equ SYS_IOCTL, 16
    .equ SYS_EXIT, 60

    .equ TCGETS, 0x5401
    .equ TCSETSF, 0x5404
    .equ TIOCGWINSZ, 0x5413
    .equ SA_RESTORER, 0x04000000

    .equ O_RDONLY, 0
    .equ O_WRCREAT, 0x241           # O_WRONLY | O_CREAT | O_TRUNC
    .equ ENOENT, 2
    .equ EINTR, 4
    .equ EAGAIN, 11

# ---- limits -----------------------------------------------------------------
    .equ TEXT_MAX, 16777216         # 16 MB document
    .equ CLIP_MAX, 4194304
    .equ UNDO_MAX, 16777216
    .equ OUT_MAX, 1048576
    .equ IO_MAX, 65536
    .equ PROMPT_MAX, 512
    .equ MSG_MAX, 1024
    .equ SB_MAX, 1024
    .equ FNAME_MAX, 4096
    .equ TABW, 4                    # tab stop (power of two)

# ---- keys -------------------------------------------------------------------
    .equ K_CTRL_A, 1
    .equ K_CTRL_C, 3
    .equ K_CTRL_F, 6
    .equ K_CTRL_G, 7
    .equ K_CTRL_H, 8
    .equ K_TAB, 9
    .equ K_CTRL_J, 10
    .equ K_CTRL_K, 11
    .equ K_ENTER, 13
    .equ K_CTRL_N, 14
    .equ K_CTRL_O, 15
    .equ K_CTRL_Q, 17
    .equ K_CTRL_S, 19
    .equ K_CTRL_U, 21
    .equ K_CTRL_V, 22
    .equ K_CTRL_W, 23
    .equ K_CTRL_X, 24
    .equ K_CTRL_Y, 25
    .equ K_CTRL_Z, 26
    .equ K_ESC, 27
    .equ K_BS, 127

    .equ K_LEFT, 1000               # 1000..1011 are cursor movement keys
    .equ K_RIGHT, 1001
    .equ K_UP, 1002
    .equ K_DOWN, 1003
    .equ K_HOME, 1004
    .equ K_END, 1005
    .equ K_PGUP, 1006
    .equ K_PGDN, 1007
    .equ K_WLEFT, 1008
    .equ K_WRIGHT, 1009
    .equ K_DOCHOME, 1010
    .equ K_DOCEND, 1011
    .equ K_DEL, 1012
    .equ K_NONE, 1013
    .equ K_PASTE_S, 1014
    .equ K_PASTE_E, 1015
    .equ K_F1, 1016
    .equ K_F10, 1017
    .equ K_NEW, 1018
    .equ K_ABOUT, 1019
    .equ K_SHIFT, 0x10000
    .equ K_ALT, 0x20000             # | lower-case letter

    .equ NMENUS, 4
    .equ MW, 24                     # menu item width

    .equ U_INS, 1                   # undo record types
    .equ U_DEL, 2

# ---- string helpers ---------------------------------------------------------
# LSTR "text"  ->  rsi = address, rdx = length (string placed in .rodata)
.macro LSTR s:vararg
    .pushsection .rodata
9997: .ascii \s
9998:
    .popsection
    lea rsi, [9997b]
    mov edx, 9998b - 9997b
.endm
.macro OBS s:vararg                 # append literal to output buffer
    LSTR \s
    call ob_write
.endm
.macro SETMSG s:vararg              # replace status message
    LSTR \s
    call set_msg
.endm
.macro MSGADD s:vararg              # append literal to status message
    LSTR \s
    call msg_add
.endm
.macro SBADD s:vararg               # append literal to status-bar builder
    LSTR \s
    call sb_add
.endm
.macro PROMPT s:vararg              # prompt the user; rax = 1 on Enter
    LSTR \s
    mov rdi, rsi
    mov rsi, rdx
    call prompt
.endm

# =============================================================================
    .section .rodata
    .align 16
nl16:       .fill 16, 1, 10
help_txt:   .ascii " ^S Save  ^Q Quit  ^F Find  ^N Next  ^X Cut  ^C Copy  ^V Paste  ^Z Undo  ^Y Redo  ^A All  ^G Line  ^O Open  ^W Save as"
help_end:
notty_txt:  .ascii "beenote: standard input is not a terminal\n"
notty_end:
menu_hint:  .ascii "F1 Help  F10 Menu "
menu_hint_end:
help_screen:
    .ascii "\r\n  \033[1mBeeNote \342\200\224 keyboard reference\033[0m\r\n\r\n"
    .ascii "  \033[1mMenus\033[0m     F10 or Alt+F / E / S / H, arrows to move, Enter to choose,\r\n"
    .ascii "            the underlined letter to pick an item, Esc to close\r\n\r\n"
    .ascii "  \033[1mFile\033[0m      Ctrl+O Open    Ctrl+S Save    Ctrl+W Save as    Ctrl+Q Quit\r\n"
    .ascii "  \033[1mEdit\033[0m      Ctrl+Z Undo    Ctrl+Y Redo    Ctrl+A Select all\r\n"
    .ascii "            Ctrl+X Cut     Ctrl+C Copy    Ctrl+V Paste\r\n"
    .ascii "            (with nothing selected, cut and copy take the whole line)\r\n"
    .ascii "  \033[1mSearch\033[0m    Ctrl+F Find    Ctrl+N Find next    Ctrl+G Go to line\r\n"
    .ascii "  \033[1mMove\033[0m      Arrows, Home/End, PgUp/PgDn, Ctrl+Left/Right by word,\r\n"
    .ascii "            Ctrl+Home/End to the start/end of the document\r\n"
    .ascii "  \033[1mSelect\033[0m    Hold Shift with any movement key\r\n\r\n"
    .ascii "  \033[2mPress any key to return to your document.\033[0m"
help_screen_end:
# Menus: [title ptr][title len][items ptr][item count]
# Items: [key][mnemonic index][24-column text]; key 0 = separator
    .align 8
menu_tab:
    .quad mt_file, 4, mi_file, (mi_file_end - mi_file) / 40
    .quad mt_edit, 4, mi_edit, (mi_edit_end - mi_edit) / 40
    .quad mt_search, 6, mi_search, (mi_search_end - mi_search) / 40
    .quad mt_help, 4, mi_help, (mi_help_end - mi_help) / 40
mt_file: .ascii "File"
    .align 8
mi_file:
    .quad K_NEW, 1
    .ascii " New                    "
    .quad K_CTRL_O, 1
    .ascii " Open...         Ctrl+O "
    .quad K_CTRL_S, 1
    .ascii " Save            Ctrl+S "
    .quad K_CTRL_W, 2
    .ascii " Save as...      Ctrl+W "
    .quad 0, 0
    .ascii "                        "
    .quad K_CTRL_Q, 1
    .ascii " Quit            Ctrl+Q "
mi_file_end:
mt_edit: .ascii "Edit"
    .align 8
mi_edit:
    .quad K_CTRL_Z, 1
    .ascii " Undo            Ctrl+Z "
    .quad K_CTRL_Y, 1
    .ascii " Redo            Ctrl+Y "
    .quad 0, 0
    .ascii "                        "
    .quad K_CTRL_X, 3
    .ascii " Cut             Ctrl+X "
    .quad K_CTRL_C, 1
    .ascii " Copy            Ctrl+C "
    .quad K_CTRL_V, 1
    .ascii " Paste           Ctrl+V "
    .quad 0, 0
    .ascii "                        "
    .quad K_CTRL_A, 8
    .ascii " Select all      Ctrl+A "
mi_edit_end:
mt_search: .ascii "Search"
    .align 8
mi_search:
    .quad K_CTRL_F, 1
    .ascii " Find...         Ctrl+F "
    .quad K_CTRL_N, 3
    .ascii " Find next       Ctrl+N "
    .quad K_CTRL_G, 1
    .ascii " Go to line...   Ctrl+G "
mi_search_end:
mt_help: .ascii "Help"
    .align 8
mi_help:
    .quad K_F1, 1
    .ascii " Keyboard help       F1 "
    .quad K_ABOUT, 1
    .ascii " About BeeNote          "
mi_help_end:

# =============================================================================
    .section .bss
    .align 16
tlen:           .zero 8         # document length in bytes
cur:            .zero 8         # cursor byte offset
rowoff:         .zero 8         # first visible line
coloff:         .zero 8         # first visible column
want_col:       .zero 8         # sticky column for up/down
rows:           .zero 8
cols:           .zero 8
text_rows:      .zero 8
text_cols:      .zero 8
gutter:         .zero 8
total_lines:    .zero 8
cy:             .zero 8         # cursor line
rx:             .zero 8         # cursor rendered column
dirty:          .zero 8
fname_len:      .zero 8
msg_len:        .zero 8
plen:           .zero 8
slen:           .zero 8
sb_len:         .zero 8
clip_len:       .zero 8
clip_lines:     .zero 8         # 1 = clipboard holds whole lines
undo_top:       .zero 8
redo_top:       .zero 8
undo_suspend:   .zero 8
edit_kind:      .zero 8         # 1 typing, 2 backspace, 3 delete (undo merging)
prev_edit_kind: .zero 8
menu_open:      .zero 8         # -1 = menu closed, else menu index
menu_sel:       .zero 8
oblen:          .zero 8
last_key:       .zero 8
prompt_active:  .zero 8
crlf:           .zero 8
paste_mode:     .zero 8
sel_anchor:     .zero 8         # -1 = no selection
hl_start:       .zero 8
hl_end:         .zero 8
found_pos:      .zero 8         # -1 = no search hit to highlight
ws:             .zero 8
kb:             .zero 8
chbuf:          .zero 8
sa:             .zero 32
orig_tio:       .zero 64
raw_tio:        .zero 64
numbuf:         .zero 32
fname:          .zero FNAME_MAX
msg:            .zero MSG_MAX
pbuf:           .zero PROMPT_MAX
sbuf:           .zero PROMPT_MAX
sb:             .zero SB_MAX
tmpbuf:         .zero 1024
iobuf:          .zero IO_MAX
outbuf:         .zero OUT_MAX
clip:           .zero CLIP_MAX
undo:           .zero UNDO_MAX
redo:           .zero UNDO_MAX
text:           .zero TEXT_MAX

# =============================================================================
    .section .text
    .globl _start
_start:
    mov r12, [rsp]                  # argc
    lea r13, [rsp + 8]              # argv
    mov qword ptr [sel_anchor], -1
    mov qword ptr [found_pos], -1
    mov qword ptr [menu_open], -1

    mov eax, SYS_IOCTL              # must run in a terminal
    xor edi, edi
    mov esi, TCGETS
    lea rdx, [orig_tio]
    syscall
    test rax, rax
    jns 1f
    mov eax, SYS_WRITE
    mov edi, 2
    lea rsi, [notty_txt]
    mov edx, notty_end - notty_txt
    syscall
    mov eax, SYS_EXIT
    mov edi, 1
    syscall
1:
    cmp r12, 2
    jb 2f
    mov rsi, [r13 + 8]              # argv[1] -> fname
    lea rdi, [fname]
    xor ecx, ecx
3:  mov al, [rsi + rcx]
    test al, al
    jz 4f
    cmp rcx, FNAME_MAX - 1
    jae 4f
    mov [rdi + rcx], al
    inc rcx
    jmp 3b
4:  mov byte ptr [rdi + rcx], 0
    mov [fname_len], rcx
    call load_file
2:
    call enable_raw
    call install_signals
    OBS "\033[?1049h\033[?2004h"    # alternate screen, bracketed paste
    call ob_flush
.Lmain:
    call refresh
    call read_key
    mov qword ptr [msg_len], 0
    mov qword ptr [found_pos], -1
    mov rdi, rax
    call menu_key                   # F10 / Alt+letter open the menus
    mov rdi, rax
    call process_key
    jmp .Lmain

# =============================================================================
#  Terminal
# =============================================================================
enable_raw:
    lea rsi, [orig_tio]
    lea rdi, [raw_tio]
    mov ecx, 64
    rep movsb
    and dword ptr [raw_tio], ~(0x2 | 0x100 | 0x10 | 0x20 | 0x400)  # BRKINT ICRNL INPCK ISTRIP IXON
    and dword ptr [raw_tio + 4], ~1                                # OPOST
    or dword ptr [raw_tio + 8], 0x30                               # CS8
    and dword ptr [raw_tio + 12], ~(0x8 | 0x2 | 0x8000 | 0x1)      # ECHO ICANON IEXTEN ISIG
    mov byte ptr [raw_tio + 22], 1  # VTIME = 0.1 s
    mov byte ptr [raw_tio + 23], 0  # VMIN = 0
    mov eax, SYS_IOCTL
    xor edi, edi
    mov esi, TCSETSF
    lea rdx, [raw_tio]
    syscall
    ret

restore_terminal:
    mov qword ptr [oblen], 0
    OBS "\033[?2004l\033[0m\033[2J\033[?1049l\033[?25h"
    call ob_flush
    mov eax, SYS_IOCTL
    xor edi, edi
    mov esi, TCSETSF
    lea rdx, [orig_tio]
    syscall
    ret

quit:
    call restore_terminal
    mov eax, SYS_EXIT
    xor edi, edi
    syscall

install_signals:
    lea rax, [sig_handler]
    mov [sa], rax
    mov qword ptr [sa + 8], SA_RESTORER
    lea rax, [sig_restorer]
    mov [sa + 16], rax
    mov qword ptr [sa + 24], 0
    mov eax, SYS_RT_SIGACTION
    mov edi, 15                     # SIGTERM
    lea rsi, [sa]
    xor edx, edx
    mov r10d, 8
    syscall
    mov eax, SYS_RT_SIGACTION
    mov edi, 1                      # SIGHUP
    lea rsi, [sa]
    xor edx, edx
    mov r10d, 8
    syscall
    ret

sig_handler:
    call restore_terminal
    mov eax, SYS_EXIT
    mov edi, 1
    syscall
sig_restorer:
    mov eax, SYS_RT_SIGRETURN
    syscall

# get_winsize: updates rows/cols, rax = 1 if they changed
get_winsize:
    mov eax, SYS_IOCTL
    mov edi, 1
    mov esi, TIOCGWINSZ
    lea rdx, [ws]
    syscall
    test rax, rax
    js 1f
    movzx eax, word ptr [ws]
    movzx ecx, word ptr [ws + 2]
    test eax, eax
    jz 1f
    test ecx, ecx
    jnz 2f
1:  mov eax, 24
    mov ecx, 80
2:  xor edx, edx
    cmp rax, [rows]
    je 3f
    mov edx, 1
3:  cmp rcx, [cols]
    je 4f
    mov edx, 1
4:  mov [rows], rax
    mov [cols], rcx
    mov eax, edx
    ret

# =============================================================================
#  Keyboard
# =============================================================================
read_byte:                          # rax = read() result, byte in [kb]
    mov eax, SYS_READ
    xor edi, edi
    lea rsi, [kb]
    mov edx, 1
    syscall
    ret

# read_key: rax = key code (byte, or K_* constant, possibly | K_SHIFT)
read_key:
    push rbx
    push r12
    push r13
    push r14
.Lrk_wait:
    call read_byte
    cmp rax, 1
    je .Lrk_got
    test rax, rax
    jnz .Lrk_err
    call get_winsize                # idle: redraw on terminal resize
    test eax, eax
    jz .Lrk_wait
    call refresh
    jmp .Lrk_wait
.Lrk_err:
    cmp rax, -EINTR
    je .Lrk_wait
    cmp rax, -EAGAIN
    je .Lrk_wait
    call quit                       # terminal is gone
.Lrk_got:
    movzx eax, byte ptr [kb]
    cmp eax, K_ESC
    jne .Lrk_ret
    call read_byte
    cmp rax, 1
    jne .Lrk_esc
    movzx ebx, byte ptr [kb]
    cmp ebx, '['
    je .Lrk_csi
    cmp ebx, 'O'
    je .Lrk_ss3
    mov eax, K_NONE
    cmp ebx, 0x20
    jb .Lrk_ret
    cmp ebx, 0x7e
    ja .Lrk_ret
    mov eax, ebx                    # Alt+key
    or eax, 0x20
    or eax, K_ALT
    jmp .Lrk_ret
.Lrk_esc:
    mov eax, K_ESC
    jmp .Lrk_ret
.Lrk_ss3:
    call read_byte
    cmp rax, 1
    jne .Lrk_esc
    movzx ebx, byte ptr [kb]
    xor r13d, r13d
    jmp .Lrk_letter
.Lrk_csi:
    xor r12d, r12d                  # first parameter
    xor r13d, r13d                  # second parameter (modifiers)
    xor r14d, r14d                  # parameter index
.Lrk_csi_loop:
    call read_byte
    cmp rax, 1
    jne .Lrk_esc
    movzx ebx, byte ptr [kb]
    cmp ebx, '0'
    jb .Lrk_csi_nd
    cmp ebx, '9'
    ja .Lrk_csi_nd
    sub ebx, '0'
    test r14, r14
    jnz 1f
    imul r12, r12, 10
    add r12, rbx
    jmp .Lrk_csi_loop
1:  imul r13, r13, 10
    add r13, rbx
    jmp .Lrk_csi_loop
.Lrk_csi_nd:
    cmp ebx, ';'
    jne 2f
    inc r14
    jmp .Lrk_csi_loop
2:  cmp ebx, 0x40                   # not a final byte yet
    jb .Lrk_csi_loop
    cmp ebx, '~'
    jne .Lrk_letter
    mov eax, K_HOME
    cmp r12, 1
    je .Lrk_mod
    cmp r12, 7
    je .Lrk_mod
    mov eax, K_END
    cmp r12, 4
    je .Lrk_mod
    cmp r12, 8
    je .Lrk_mod
    mov eax, K_DEL
    cmp r12, 3
    je .Lrk_mod
    mov eax, K_PGUP
    cmp r12, 5
    je .Lrk_mod
    mov eax, K_PGDN
    cmp r12, 6
    je .Lrk_mod
    mov eax, K_F1
    cmp r12, 11
    je .Lrk_ret
    mov eax, K_F10
    cmp r12, 21
    je .Lrk_ret
    mov eax, K_PASTE_S
    cmp r12, 200
    je .Lrk_ret
    mov eax, K_PASTE_E
    cmp r12, 201
    je .Lrk_ret
    mov eax, K_NONE
    jmp .Lrk_ret
.Lrk_letter:
    mov eax, K_UP
    cmp ebx, 'A'
    je .Lrk_mod
    mov eax, K_DOWN
    cmp ebx, 'B'
    je .Lrk_mod
    mov eax, K_RIGHT
    cmp ebx, 'C'
    je .Lrk_mod
    mov eax, K_LEFT
    cmp ebx, 'D'
    je .Lrk_mod
    mov eax, K_HOME
    cmp ebx, 'H'
    je .Lrk_mod
    mov eax, K_END
    cmp ebx, 'F'
    je .Lrk_mod
    mov eax, K_F1
    cmp ebx, 'P'
    je .Lrk_ret
    mov eax, K_NONE
    jmp .Lrk_ret
.Lrk_mod:                           # r13 = 1 + (1 shift | 2 alt | 4 ctrl)
    test r13, r13
    jz .Lrk_ret
    dec r13
    test r13, 4
    jz 3f
    cmp eax, K_LEFT
    jne 4f
    mov eax, K_WLEFT
    jmp 3f
4:  cmp eax, K_RIGHT
    jne 5f
    mov eax, K_WRIGHT
    jmp 3f
5:  cmp eax, K_HOME
    jne 6f
    mov eax, K_DOCHOME
    jmp 3f
6:  cmp eax, K_END
    jne 3f
    mov eax, K_DOCEND
3:  test r13, 1
    jz .Lrk_ret
    cmp eax, K_DEL
    je .Lrk_ret
    or eax, K_SHIFT
.Lrk_ret:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# =============================================================================
#  Key dispatch
# =============================================================================
process_key:                        # rdi = key
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov qword ptr [edit_kind], 0
    xor r12d, r12d                  # r12 = 1 keeps the selection alive
    test rbx, K_SHIFT
    jz .Lpk_dispatch
    and rbx, ~K_SHIFT
    mov r12d, 1
    cmp qword ptr [sel_anchor], -1
    jne .Lpk_dispatch
    mov rax, [cur]
    mov [sel_anchor], rax
.Lpk_dispatch:
    cmp rbx, K_LEFT
    je .Lk_left
    cmp rbx, K_RIGHT
    je .Lk_right
    cmp rbx, K_UP
    je .Lk_up
    cmp rbx, K_DOWN
    je .Lk_down
    cmp rbx, K_PGUP
    je .Lk_pgup
    cmp rbx, K_PGDN
    je .Lk_pgdn
    cmp rbx, K_HOME
    je .Lk_home
    cmp rbx, K_END
    je .Lk_end
    cmp rbx, K_WLEFT
    je .Lk_wleft
    cmp rbx, K_WRIGHT
    je .Lk_wright
    cmp rbx, K_DOCHOME
    je .Lk_dochome
    cmp rbx, K_DOCEND
    je .Lk_docend
    cmp rbx, K_DEL
    je .Lk_del
    cmp rbx, K_PASTE_S
    je .Lk_paste_s
    cmp rbx, K_PASTE_E
    je .Lk_paste_e
    cmp rbx, K_NONE
    je .Lk_keep
    cmp rbx, K_NEW
    je .Lk_new
    cmp rbx, K_F1
    je .Lk_help
    cmp rbx, K_ABOUT
    je .Lk_about
    cmp rbx, K_BS
    je .Lk_bs
    cmp rbx, K_CTRL_H
    je .Lk_bs
    cmp rbx, K_ENTER
    je .Lk_enter
    cmp rbx, K_CTRL_J
    je .Lk_enter
    cmp rbx, K_TAB
    je .Lk_char
    cmp rbx, K_CTRL_Q
    je .Lk_quit
    cmp rbx, K_CTRL_S
    je .Lk_save
    cmp rbx, K_CTRL_W
    je .Lk_saveas
    cmp rbx, K_CTRL_O
    je .Lk_open
    cmp rbx, K_CTRL_F
    je .Lk_find
    cmp rbx, K_CTRL_N
    je .Lk_next
    cmp rbx, K_CTRL_G
    je .Lk_goto
    cmp rbx, K_CTRL_A
    je .Lk_selall
    cmp rbx, K_CTRL_X
    je .Lk_cut
    cmp rbx, K_CTRL_K
    je .Lk_cut
    cmp rbx, K_CTRL_C
    je .Lk_copy
    cmp rbx, K_CTRL_V
    je .Lk_paste
    cmp rbx, K_CTRL_U
    je .Lk_paste
    cmp rbx, K_CTRL_Z
    je .Lk_undo
    cmp rbx, K_CTRL_Y
    je .Lk_redo
    cmp rbx, 32
    jb .Lpk_done                    # other control keys: ignored
    cmp rbx, 256
    jb .Lk_char
    jmp .Lpk_done

.Lk_left:
    mov rdi, [cur]
    call prev_char
    mov [cur], rax
    jmp .Lpk_done
.Lk_right:
    mov rdi, [cur]
    call next_char
    mov [cur], rax
    jmp .Lpk_done
.Lk_up:
    call move_up
    jmp .Lpk_done
.Lk_down:
    call move_down
    jmp .Lpk_done
.Lk_pgup:
    mov r13, [text_rows]
1:  call move_up
    dec r13
    jg 1b
    jmp .Lpk_done
.Lk_pgdn:
    mov r13, [text_rows]
1:  call move_down
    dec r13
    jg 1b
    jmp .Lpk_done
.Lk_home:                           # smart home: indentation first, then column 0
    mov rdi, [cur]
    call line_start
    mov rcx, rax
1:  cmp rcx, [tlen]
    jae 2f
    movzx edx, byte ptr [text + rcx]
    cmp edx, ' '
    je 3f
    cmp edx, 9
    jne 2f
3:  inc rcx
    jmp 1b
2:  cmp rcx, [cur]
    jne 4f
    mov rcx, rax
4:  mov [cur], rcx
    jmp .Lpk_done
.Lk_end:
    mov rdi, [cur]
    call line_end
    mov [cur], rax
    jmp .Lpk_done
.Lk_wleft:
    call word_left
    jmp .Lpk_done
.Lk_wright:
    call word_right
    jmp .Lpk_done
.Lk_dochome:
    mov qword ptr [cur], 0
    jmp .Lpk_done
.Lk_docend:
    mov rax, [tlen]
    mov [cur], rax
    jmp .Lpk_done

.Lk_del:
    call delete_selection
    test rax, rax
    jnz .Lpk_done
    mov rdi, [cur]
    cmp rdi, [tlen]
    jae .Lpk_done
    call next_char
    mov rsi, rax
    mov rdi, [cur]
    sub rsi, rdi
    mov qword ptr [edit_kind], 3
    call do_delete
    jmp .Lpk_done
.Lk_bs:
    call delete_selection
    test rax, rax
    jnz .Lpk_done
    mov rdi, [cur]
    test rdi, rdi
    jz .Lpk_done
    call prev_char
    mov rdi, rax
    mov rsi, [cur]
    sub rsi, rax
    mov qword ptr [edit_kind], 2
    call do_delete
    jmp .Lpk_done
.Lk_enter:                          # newline + auto-indent
    call delete_selection
    mov rdi, [cur]
    call line_start
    mov byte ptr [tmpbuf], 10
    mov ecx, 1
    cmp qword ptr [paste_mode], 0
    jne 2f
1:  cmp rax, [cur]
    jae 2f
    cmp ecx, 256
    jae 2f
    movzx edx, byte ptr [text + rax]
    cmp edx, ' '
    je 3f
    cmp edx, 9
    jne 2f
3:  mov [tmpbuf + rcx], dl
    inc ecx
    inc rax
    jmp 1b
2:  mov rax, [paste_mode]           # a paste is undone as one step
    mov [edit_kind], rax
    mov rdi, [cur]
    lea rsi, [tmpbuf]
    mov edx, ecx
    call do_insert
    jmp .Lpk_done
.Lk_char:
    call delete_selection
    mov [chbuf], bl
    mov qword ptr [edit_kind], 1
    mov rdi, [cur]
    lea rsi, [chbuf]
    mov edx, 1
    call do_insert
    jmp .Lpk_done

.Lk_quit:
    mov r12d, 1
    call ask_save
    test rax, rax
    jz .Lpk_done
    call quit
.Lk_new:
    call new_cmd
    jmp .Lpk_done
.Lk_help:
    mov r12d, 1
    call show_help
    jmp .Lpk_done
.Lk_about:
    mov r12d, 1
    SETMSG "\033[1mBeeNote\033[0m \342\200\224 a notepad written in pure x86-64 assembly. No libc, one tiny static binary."
    jmp .Lpk_done
.Lk_save:
    mov r12d, 1
    xor edi, edi
    call save_cmd
    jmp .Lpk_done
.Lk_saveas:
    mov r12d, 1
    mov edi, 1
    call save_cmd
    jmp .Lpk_done
.Lk_open:
    call open_cmd
    jmp .Lpk_done
.Lk_find:
    call find_cmd
    jmp .Lpk_done
.Lk_next:
    call find_next_cmd
    jmp .Lpk_done
.Lk_goto:
    call goto_cmd
    jmp .Lpk_done
.Lk_selall:
    mov r12d, 1
    mov qword ptr [sel_anchor], 0
    mov rax, [tlen]
    mov [cur], rax
    jmp .Lpk_done
.Lk_cut:
    call cut_cmd
    jmp .Lpk_done
.Lk_copy:
    mov r12d, 1
    call copy_cmd
    jmp .Lpk_done
.Lk_paste:
    call paste_cmd
    jmp .Lpk_done
.Lk_undo:
    call undo_cmd
    jmp .Lpk_done
.Lk_redo:
    call redo_cmd
    jmp .Lpk_done
.Lk_paste_s:
    mov qword ptr [paste_mode], 1
    jmp .Lk_keep
.Lk_paste_e:
    mov qword ptr [paste_mode], 0
.Lk_keep:
    mov r12d, 1

.Lpk_done:
    test r12, r12
    jnz 1f
    mov qword ptr [sel_anchor], -1
1:  cmp rbx, K_UP
    je 2f
    cmp rbx, K_DOWN
    je 2f
    cmp rbx, K_PGUP
    je 2f
    cmp rbx, K_PGDN
    je 2f
    call update_want_col
2:  mov [last_key], rbx
    mov rax, [edit_kind]
    mov [prev_edit_kind], rax
    pop r13
    pop r12
    pop rbx
    ret

# =============================================================================
#  Text navigation helpers (positions are byte offsets into text)
# =============================================================================
line_start:                         # rdi = pos -> rax = start of its line
    mov rax, rdi
1:  test rax, rax
    jz 2f
    cmp byte ptr [rax + text - 1], 10
    je 2f
    dec rax
    jmp 1b
2:  ret

line_end:                           # rdi = pos -> rax = position of '\n' / EOF
    mov rax, rdi
    mov rcx, [tlen]
1:  cmp rax, rcx
    jae 2f
    cmp byte ptr [rax + text], 10
    je 2f
    inc rax
    jmp 1b
2:  ret

next_char:                          # rdi = pos -> rax = next UTF-8 char start
    mov rax, rdi
    mov rcx, [tlen]
    cmp rax, rcx
    jae 2f
    inc rax
1:  cmp rax, rcx
    jae 2f
    movzx edx, byte ptr [rax + text]
    and edx, 0xC0
    cmp edx, 0x80
    jne 2f
    inc rax
    jmp 1b
2:  ret

prev_char:                          # rdi = pos -> rax = previous char start
    mov rax, rdi
    test rax, rax
    jz 2f
    dec rax
1:  test rax, rax
    jz 2f
    movzx edx, byte ptr [rax + text]
    and edx, 0xC0
    cmp edx, 0x80
    jne 2f
    dec rax
    jmp 1b
2:  ret

col_of:                             # rdi = line start, rsi = pos -> rax = screen column
    xor eax, eax
    mov rcx, rdi
1:  cmp rcx, rsi
    jae 9f
    movzx edx, byte ptr [rcx + text]
    inc rcx
    cmp edx, 9
    je 3f
    and edx, 0xC0
    cmp edx, 0x80
    je 1b
    inc rax
    jmp 1b
3:  or rax, TABW - 1
    inc rax
    jmp 1b
9:  ret

pos_at_col:                         # rdi = line start, rsi = column -> rax = pos
    mov rcx, rdi
    xor eax, eax
    mov r9, [tlen]
1:  cmp rcx, r9
    jae 9f
    movzx edx, byte ptr [rcx + text]
    cmp edx, 10
    je 9f
    cmp edx, 9
    jne 2f
    mov r8, rax
    or r8, TABW - 1
    inc r8
    jmp 3f
2:  lea r8, [rax + 1]
3:  cmp r8, rsi
    ja 9f
    mov rax, r8
    inc rcx
4:  cmp rcx, r9
    jae 1b
    movzx edx, byte ptr [rcx + text]
    and edx, 0xC0
    cmp edx, 0x80
    jne 1b
    inc rcx
    jmp 4b
9:  mov rax, rcx
    ret

count_nl:                           # rdi = start, rsi = length -> rax = '\n' count
    xor eax, eax
    lea rdi, [rdi + text]
    movdqu xmm1, [nl16]
1:  cmp rsi, 16
    jb 2f
    movdqu xmm0, [rdi]
    pcmpeqb xmm0, xmm1
    pmovmskb ecx, xmm0
    popcnt ecx, ecx
    add rax, rcx
    add rdi, 16
    sub rsi, 16
    jmp 1b
2:  test rsi, rsi
    jz 3f
    cmp byte ptr [rdi], 10
    jne 4f
    inc rax
4:  inc rdi
    dec rsi
    jmp 2b
3:  ret

move_up:
    mov rdi, [cur]
    call line_start
    test rax, rax
    jz 1f
    lea rdi, [rax - 1]
    call line_start
    mov rdi, rax
    mov rsi, [want_col]
    call pos_at_col
    mov [cur], rax
1:  ret

move_down:
    mov rdi, [cur]
    call line_end
    cmp rax, [tlen]
    jae 1f
    lea rdi, [rax + 1]
    mov rsi, [want_col]
    call pos_at_col
    mov [cur], rax
1:  ret

update_want_col:
    mov rdi, [cur]
    call line_start
    mov rdi, rax
    mov rsi, [cur]
    call col_of
    mov [want_col], rax
    ret

is_word:                            # edx = byte -> eax = 1 if word character
    mov eax, 1
    cmp edx, 0x80
    jae 1f
    cmp edx, '_'
    je 1f
    cmp edx, '0'
    jb 0f
    cmp edx, '9'
    jbe 1f
    mov ecx, edx
    or ecx, 0x20
    cmp ecx, 'a'
    jb 0f
    cmp ecx, 'z'
    jbe 1f
0:  xor eax, eax
1:  ret

word_left:
    push rbx
    mov rbx, [cur]
1:  test rbx, rbx
    jz 3f
    movzx edx, byte ptr [rbx + text - 1]
    call is_word
    test eax, eax
    jnz 2f
    dec rbx
    jmp 1b
2:  test rbx, rbx
    jz 3f
    movzx edx, byte ptr [rbx + text - 1]
    call is_word
    test eax, eax
    jz 3f
    dec rbx
    jmp 2b
3:  mov [cur], rbx
    pop rbx
    ret

word_right:
    push rbx
    mov rbx, [cur]
1:  cmp rbx, [tlen]
    jae 3f
    movzx edx, byte ptr [rbx + text]
    call is_word
    test eax, eax
    jnz 2f
    inc rbx
    jmp 1b
2:  cmp rbx, [tlen]
    jae 3f
    movzx edx, byte ptr [rbx + text]
    call is_word
    test eax, eax
    jz 3f
    inc rbx
    jmp 2b
3:  mov [cur], rbx
    pop rbx
    ret

# get_sel: rax = selection start, rdx = end; rax = -1 if no selection
get_sel:
    mov rax, [sel_anchor]
    cmp rax, -1
    je 2f
    mov rdx, [cur]
    cmp rax, rdx
    je 1f
    jb 2f
    xchg rax, rdx
    ret
1:  mov rax, -1
2:  ret

delete_selection:                   # rax = 1 if a selection was removed
    call get_sel
    mov qword ptr [sel_anchor], -1
    cmp rax, -1
    je 1f
    mov rdi, rax
    mov rsi, rdx
    sub rsi, rax
    call do_delete
    mov eax, 1
    ret
1:  xor eax, eax
    ret

# =============================================================================
#  Editing primitives (with undo recording)
# =============================================================================
memmove:                            # rdi = dst, rsi = src, rdx = n
    mov rcx, rdx
    cmp rdi, rsi
    jbe 1f
    lea rax, [rsi + rcx]
    cmp rdi, rax
    jae 1f
    lea rsi, [rsi + rcx - 1]
    lea rdi, [rdi + rcx - 1]
    std
    rep movsb
    cld
    ret
1:  rep movsb
    ret

do_insert:                          # rdi = pos, rsi = src, rdx = n; cur = pos + n
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    test r13, r13
    jz 9f
    mov rax, [tlen]
    add rax, r13
    cmp rax, TEXT_MAX
    ja 8f
    cmp qword ptr [undo_suspend], 0
    jne 1f
    mov edi, U_INS
    mov rsi, rbx
    mov rdx, r12
    mov rcx, r13
    call undo_push
1:  lea rdi, [rbx + r13 + text]
    lea rsi, [rbx + text]
    mov rdx, [tlen]
    sub rdx, rbx
    call memmove
    lea rdi, [rbx + text]
    mov rsi, r12
    mov rdx, r13
    call memmove
    add [tlen], r13
    lea rax, [rbx + r13]
    mov [cur], rax
    mov qword ptr [dirty], 1
    jmp 9f
8:  SETMSG "Document is full (16 MB limit)"
9:  pop r13
    pop r12
    pop rbx
    ret

do_delete:                          # rdi = pos, rsi = n; cur = pos
    push rbx
    push r12
    mov rbx, rdi
    mov r12, rsi
    test r12, r12
    jz 9f
    cmp qword ptr [undo_suspend], 0
    jne 1f
    mov edi, U_DEL
    mov rsi, rbx
    lea rdx, [rbx + text]
    mov rcx, r12
    call undo_push
1:  lea rdi, [rbx + text]
    lea rsi, [rbx + r12 + text]
    mov rdx, [tlen]
    sub rdx, rbx
    sub rdx, r12
    call memmove
    sub [tlen], r12
    mov [cur], rbx
    mov qword ptr [dirty], 1
9:  pop r12
    pop rbx
    ret

# Undo/redo logs are stacks of records:
#   [type:8][pos:8][len:8][data:len][header offset:8]
# rec_append: rdi = log, rsi = &top, rdx = type, rcx = pos, r8 = src, r9 = n
rec_append:
    push rbx
    push r12
    push r13
    push r14
    push r15
    push rbp
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    mov r15, r8
    mov rbp, r9
    mov rax, [r12]
    lea rcx, [rax + rbp + 32]
    cmp rcx, UNDO_MAX
    jbe 1f
    xor eax, eax                    # log full: forget older history
    lea rcx, [rbp + 32]
    cmp rcx, UNDO_MAX
    jbe 1f
    mov [r12], rax
    jmp 9f
1:  mov [rbx + rax], r13
    mov [rbx + rax + 8], r14
    mov [rbx + rax + 16], rbp
    push rax
    lea rdi, [rbx + rax + 24]
    mov rsi, r15
    mov rdx, rbp
    call memmove
    pop rax
    lea rcx, [rax + rbp + 32]
    mov [rbx + rcx - 8], rax
    mov [r12], rcx
9:  pop rbp
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# undo_push: rdi = type, rsi = pos, rdx = src, rcx = n
# Consecutive typing / backspacing / deleting is merged into one record.
undo_push:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov r15, rcx
    mov qword ptr [redo_top], 0
    mov rax, [edit_kind]
    test rax, rax
    jz .Lup_new
    cmp rax, [prev_edit_kind]
    jne .Lup_new
    mov rax, [undo_top]
    test rax, rax
    jz .Lup_new
    lea rcx, [rax + r15]
    cmp rcx, UNDO_MAX
    ja .Lup_new
    mov rbx, [rax + undo - 8]       # header of the last record
    cmp [rbx + undo], r12
    jne .Lup_new
    cmp r12, U_INS
    jne .Lup_del
    mov rax, [rbx + undo + 8]
    add rax, [rbx + undo + 16]
    cmp rax, r13
    jne .Lup_new
.Lup_append:
    mov rdi, [undo_top]
    lea rdi, [rdi + undo - 8]
    mov rsi, r14
    mov rdx, r15
    call memmove
    add [rbx + undo + 16], r15
    jmp .Lup_trailer
.Lup_del:
    cmp [rbx + undo + 8], r13       # Delete key: same position, append
    je .Lup_append
    lea rax, [r13 + r15]            # Backspace: ends where last began, prepend
    cmp rax, [rbx + undo + 8]
    jne .Lup_new
    lea rsi, [rbx + undo + 24]
    lea rdi, [rsi + r15]
    mov rdx, [rbx + undo + 16]
    call memmove
    lea rdi, [rbx + undo + 24]
    mov rsi, r14
    mov rdx, r15
    call memmove
    add [rbx + undo + 16], r15
    mov [rbx + undo + 8], r13
.Lup_trailer:
    mov rax, [undo_top]
    add rax, r15
    mov [undo_top], rax
    mov [rax + undo - 8], rbx
    jmp .Lup_ret
.Lup_new:
    lea rdi, [undo]
    lea rsi, [undo_top]
    mov rdx, r12
    mov rcx, r13
    mov r8, r14
    mov r9, r15
    call rec_append
.Lup_ret:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

undo_cmd:
    push rbx
    mov rax, [undo_top]
    test rax, rax
    jz 8f
    mov rbx, [rax + undo - 8]
    mov [undo_top], rbx
    lea rdi, [redo]
    lea rsi, [redo_top]
    mov rdx, [rbx + undo]
    mov rcx, [rbx + undo + 8]
    lea r8, [rbx + undo + 24]
    mov r9, [rbx + undo + 16]
    call rec_append
    mov qword ptr [undo_suspend], 1
    cmp qword ptr [rbx + undo], U_INS
    jne 1f
    mov rdi, [rbx + undo + 8]
    mov rsi, [rbx + undo + 16]
    call do_delete
    jmp 2f
1:  mov rdi, [rbx + undo + 8]
    lea rsi, [rbx + undo + 24]
    mov rdx, [rbx + undo + 16]
    call do_insert
2:  mov qword ptr [undo_suspend], 0
    pop rbx
    ret
8:  SETMSG "Nothing to undo"
    pop rbx
    ret

redo_cmd:
    push rbx
    mov rax, [redo_top]
    test rax, rax
    jz 8f
    mov rbx, [rax + redo - 8]
    mov [redo_top], rbx
    lea rdi, [undo]
    lea rsi, [undo_top]
    mov rdx, [rbx + redo]
    mov rcx, [rbx + redo + 8]
    lea r8, [rbx + redo + 24]
    mov r9, [rbx + redo + 16]
    call rec_append
    mov qword ptr [undo_suspend], 1
    cmp qword ptr [rbx + redo], U_INS
    jne 1f
    mov rdi, [rbx + redo + 8]
    lea rsi, [rbx + redo + 24]
    mov rdx, [rbx + redo + 16]
    call do_insert
    jmp 2f
1:  mov rdi, [rbx + redo + 8]
    mov rsi, [rbx + redo + 16]
    call do_delete
2:  mov qword ptr [undo_suspend], 0
    pop rbx
    ret
8:  SETMSG "Nothing to redo"
    pop rbx
    ret

# =============================================================================
#  Clipboard
# =============================================================================
clip_set:                           # rdi = start, rsi = end; rax = 1 on success
    mov rdx, rsi
    sub rdx, rdi
    cmp rdx, CLIP_MAX
    ja 1f
    mov [clip_len], rdx
    mov qword ptr [clip_lines], 0
    lea rsi, [rdi + text]
    lea rdi, [clip]
    call memmove
    mov eax, 1
    ret
1:  SETMSG "Selection too large for the clipboard (4 MB limit)"
    xor eax, eax
    ret

clip_add_line:                      # rdi = start, rsi = end; appends + ensures '\n'
    mov rdx, rsi
    sub rdx, rdi
    mov rax, [clip_len]
    lea rcx, [rax + rdx + 1]
    cmp rcx, CLIP_MAX
    ja 3f
    push rdx
    lea rsi, [rdi + text]
    lea rdi, [rax + clip]
    call memmove
    pop rdx
    add [clip_len], rdx
    mov qword ptr [clip_lines], 1
    mov rax, [clip_len]
    test rax, rax
    jz 1f
    cmp byte ptr [rax + clip - 1], 10
    je 2f
1:  mov byte ptr [rax + clip], 10
    inc qword ptr [clip_len]
2:  mov eax, 1
    ret
3:  SETMSG "Clipboard full (4 MB limit)"
    xor eax, eax
    ret

line_bounds:                        # rax = start of cursor line, rdx = past its '\n'
    mov rdi, [cur]
    call line_start
    push rax
    mov rdi, [cur]
    call line_end
    mov rdx, rax
    pop rax
    cmp rdx, [tlen]
    jae 1f
    inc rdx
1:  ret

copy_cmd:
    push rbx
    push r12
    call get_sel
    cmp rax, -1
    je 1f
    mov rdi, rax
    mov rsi, rdx
    call clip_set
    test rax, rax
    jz 9f
    SETMSG "Selection copied"
    jmp 9f
1:  call line_bounds                # no selection: copy the whole line
    mov rbx, rax
    mov r12, rdx
    cmp qword ptr [last_key], K_CTRL_C
    jne 2f
    cmp qword ptr [clip_lines], 1
    je 3f
2:  mov qword ptr [clip_len], 0
3:  mov rdi, rbx
    mov rsi, r12
    call clip_add_line
    test rax, rax
    jz 9f
    mov rdi, rbx
    call count_lines_in_clip_msg
    MSGADD " copied (^C again adds the next line)"
    mov rax, [cur]
    cmp r12, rax                    # step to the next line
    jbe 9f
    cmp byte ptr [r12 + text - 1], 10
    jne 9f
    mov [cur], r12
9:  pop r12
    pop rbx
    ret

count_lines_in_clip_msg:            # message "N line(s)" for the clipboard
    xor edi, edi
    mov rsi, [clip_len]
    lea rax, [clip]
    lea rcx, [text]
    sub rax, rcx
    mov rdi, rax                    # count_nl works relative to text
    call count_nl
    mov rdi, rax
    push rax
    mov qword ptr [msg_len], 0
    call msg_num
    pop rax
    cmp rax, 1
    je 1f
    MSGADD " lines"
    ret
1:  MSGADD " line"
    ret

cut_cmd:
    push rbx
    push r12
    call get_sel
    cmp rax, -1
    je 1f
    mov rdi, rax
    mov rsi, rdx
    call clip_set
    test rax, rax
    jz 9f
    call delete_selection
    SETMSG "Selection cut"
    jmp 9f
1:  call line_bounds                # no selection: cut the whole line
    mov rbx, rax
    mov r12, rdx
    cmp rbx, r12
    jne 2f
    SETMSG "Nothing to cut"
    jmp 9f
2:  mov rax, [last_key]
    cmp rax, K_CTRL_X
    je 3f
    cmp rax, K_CTRL_K
    jne 4f
3:  cmp qword ptr [clip_lines], 1
    je 5f
4:  mov qword ptr [clip_len], 0
5:  mov rdi, rbx
    mov rsi, r12
    call clip_add_line
    test rax, rax
    jz 9f
    mov rdi, rbx
    mov rsi, r12
    sub rsi, rbx
    call do_delete
    call count_lines_in_clip_msg
    MSGADD " cut (^X again adds the next line)"
9:  pop r12
    pop rbx
    ret

paste_cmd:
    cmp qword ptr [clip_len], 0
    je 2f
    call delete_selection
    cmp qword ptr [clip_lines], 0
    je 1f
    mov rdi, [cur]                  # whole lines go above the current line
    call line_start
    mov [cur], rax
1:  mov rdi, [cur]
    lea rsi, [clip]
    mov rdx, [clip_len]
    call do_insert
    ret
2:  SETMSG "Clipboard is empty"
    ret

# =============================================================================
#  Search / go to line
# =============================================================================
find_range:                         # rdi = from, rsi = end (exclusive start) -> rax pos / -1
    mov r8, [slen]
    mov r9, rdi
1:  cmp r9, rsi
    jae 8f
    xor ecx, ecx
2:  cmp rcx, r8
    jae 7f
    movzx eax, byte ptr [r9 + rcx + text]
    movzx edx, byte ptr [rcx + sbuf]
    cmp al, 'A'
    jb 3f
    cmp al, 'Z'
    ja 3f
    or al, 0x20
3:  cmp dl, 'A'
    jb 4f
    cmp dl, 'Z'
    ja 4f
    or dl, 0x20
4:  cmp al, dl
    jne 5f
    inc rcx
    jmp 2b
5:  inc r9
    jmp 1b
7:  mov rax, r9
    ret
8:  mov rax, -1
    ret

find_from:                          # rdi = first position to try
    push rbx
    push r12
    mov rbx, rdi
    mov r12, [tlen]
    sub r12, [slen]
    jb 8f
    inc r12                         # one past the last possible start
    cmp rbx, r12
    jbe 1f
    mov rbx, r12
1:  mov rdi, rbx
    mov rsi, r12
    call find_range
    cmp rax, -1
    jne 2f
    xor edi, edi                    # wrap around to the top
    mov rsi, rbx
    call find_range
    cmp rax, -1
    je 8f
    push rax
    SETMSG "Search wrapped to the top"
    pop rax
2:  mov [cur], rax
    mov [found_pos], rax
    jmp 9f
8:  SETMSG "Not found: "
    lea rsi, [sbuf]
    mov rdx, [slen]
    call msg_add
9:  pop r12
    pop rbx
    ret

find_cmd:
    lea rsi, [sbuf]                 # pre-fill with the previous search
    lea rdi, [pbuf]
    mov rcx, [slen]
    mov [plen], rcx
    rep movsb
    PROMPT "Find (case-insensitive): "
    test rax, rax
    jz 1f
    mov rcx, [plen]
    test rcx, rcx
    jz 1f
    mov [slen], rcx
    lea rsi, [pbuf]
    lea rdi, [sbuf]
    rep movsb
    mov rdi, [cur]
    call find_from
1:  ret

find_next_cmd:
    cmp qword ptr [slen], 0
    je find_cmd
    mov rdi, [cur]
    inc rdi
    jmp find_from

goto_cmd:
    mov qword ptr [plen], 0
    PROMPT "Go to line: "
    test rax, rax
    jz 9f
    xor eax, eax
    xor ecx, ecx
1:  cmp rcx, [plen]
    jae 3f
    movzx edx, byte ptr [rcx + pbuf]
    cmp edx, ' '
    je 2f
    sub edx, '0'
    cmp edx, 9
    ja 8f
    mov r8, 100000000000
    cmp rax, r8
    jae 2f
    imul rax, rax, 10
    add rax, rdx
2:  inc rcx
    jmp 1b
3:  test rax, rax
    jz 8f
    dec rax                         # number of newlines to skip
    xor ecx, ecx
    mov rdx, [tlen]
4:  test rax, rax
    jz 6f
    cmp rcx, rdx
    jae 6f
    cmp byte ptr [rcx + text], 10
    jne 5f
    dec rax
5:  inc rcx
    jmp 4b
6:  mov rdi, rcx
    call line_start
    mov [cur], rax
    xor edi, edi                    # centre the target line
    mov rsi, rax
    call count_nl
    mov rcx, [text_rows]
    shr rcx, 1
    sub rax, rcx
    jge 7f
    xor eax, eax
7:  mov [rowoff], rax
    ret
8:  SETMSG "Invalid line number"
9:  ret

# =============================================================================
#  Prompt line
# =============================================================================
# prompt: rdi = label, rsi = label length; edits pbuf/plen (may be pre-filled).
# rax = 1 when confirmed with Enter, 0 when cancelled with Esc / Ctrl+Q / Ctrl+C.
prompt:
    push rbx
    push r12
    push r13
    mov r12, rdi
    mov r13, rsi
    mov qword ptr [prompt_active], 1
1:  mov rsi, r12
    mov rdx, r13
    call set_msg
    lea rsi, [pbuf]
    mov rdx, [plen]
    call msg_add
    call refresh
    call read_key
    mov rbx, rax
    cmp rbx, K_ENTER
    je 7f
    cmp rbx, K_CTRL_J
    je 7f
    cmp rbx, K_ESC
    je 8f
    cmp rbx, K_CTRL_Q
    je 8f
    cmp rbx, K_CTRL_C
    je 8f
    cmp rbx, K_BS
    je 3f
    cmp rbx, K_CTRL_H
    je 3f
    cmp rbx, K_TAB
    je 2f
    cmp rbx, 32
    jb 1b
    cmp rbx, 256
    jae 1b
2:  mov rax, [plen]
    cmp rax, PROMPT_MAX - 1
    jae 1b
    mov [rax + pbuf], bl
    inc qword ptr [plen]
    jmp 1b
3:  mov rax, [plen]                 # backspace one UTF-8 character
4:  test rax, rax
    jz 5f
    dec rax
    movzx edx, byte ptr [rax + pbuf]
    and edx, 0xC0
    cmp edx, 0x80
    je 4b
5:  mov [plen], rax
    jmp 1b
7:  mov ebx, 1
    jmp 9f
8:  xor ebx, ebx
9:  mov rax, [plen]
    mov byte ptr [rax + pbuf], 0
    mov qword ptr [prompt_active], 0
    mov qword ptr [msg_len], 0
    mov rax, rbx
    pop r13
    pop r12
    pop rbx
    ret

# =============================================================================
#  Files
# =============================================================================
copy_pbuf_to_fname:
    lea rsi, [pbuf]
    lea rdi, [fname]
    mov rcx, [plen]
    mov [fname_len], rcx
    rep movsb
    mov byte ptr [rdi], 0
    ret

reset_doc:                          # empty document, fresh history
    xor eax, eax
    mov [tlen], rax
    mov [cur], rax
    mov [rowoff], rax
    mov [coloff], rax
    mov [want_col], rax
    mov [dirty], rax
    mov [undo_top], rax
    mov [redo_top], rax
    mov [crlf], rax
    mov qword ptr [sel_anchor], -1
    ret

new_cmd:
    call ask_save
    test rax, rax
    jz 1f
    call reset_doc
    mov qword ptr [fname_len], 0
    mov byte ptr [fname], 0
    SETMSG "New document"
1:  ret

load_file:                          # loads [fname] into the buffer
    push rbx
    push r12
    push r13
    call reset_doc
    mov eax, SYS_OPEN
    lea rdi, [fname]
    xor esi, esi
    xor edx, edx
    syscall
    cmp rax, -ENOENT
    jne 1f
    SETMSG "New file: "
    call msg_add_fname
    jmp 9f
1:  test rax, rax
    jns 2f
    neg rax
    mov rbx, rax
    SETMSG "Cannot open "
    call msg_add_fname
    MSGADD " (error "
    mov rdi, rbx
    call msg_num
    MSGADD ")"
    mov qword ptr [fname_len], 0
    jmp 9f
2:  mov rbx, rax                    # fd
    xor r12d, r12d                  # 1 = file too large
    xor r13d, r13d                  # 1 = read error
3:  mov rdx, TEXT_MAX
    sub rdx, [tlen]
    jz 4f
    mov rsi, [tlen]
    lea rsi, [rsi + text]
    mov eax, SYS_READ
    mov rdi, rbx
    syscall
    cmp rax, -EINTR
    je 3b
    test rax, rax
    js 5f
    jz 6f
    add [tlen], rax
    jmp 3b
4:  mov eax, SYS_READ               # buffer full: is there more?
    mov rdi, rbx
    lea rsi, [iobuf]
    mov edx, 1
    syscall
    test rax, rax
    jle 6f
    mov r12d, 1
    jmp 6f
5:  mov r13d, 1
6:  mov eax, SYS_CLOSE
    mov rdi, rbx
    syscall
    xor ecx, ecx                    # convert CRLF -> LF (remembered for saving)
    xor edx, edx
    mov r8, [tlen]
7:  cmp rcx, r8
    jae 8f
    mov al, [rcx + text]
    cmp al, 13
    jne 10f
    lea r9, [rcx + 1]
    cmp r9, r8
    jae 10f
    cmp byte ptr [r9 + text], 10
    jne 10f
    mov qword ptr [crlf], 1
    inc rcx
    jmp 7b
10: mov [rdx + text], al
    inc rcx
    inc rdx
    jmp 7b
8:  mov [tlen], rdx
    test r13, r13
    jz 11f
    SETMSG "Error reading "
    call msg_add_fname
    mov qword ptr [fname_len], 0
    mov qword ptr [tlen], 0
    jmp 9f
11: test r12, r12
    jz 12f
    SETMSG "File too large: only the first 16 MB were loaded. Use ^W to save it under a new name."
    mov qword ptr [fname_len], 0
    jmp 9f
12: SETMSG "Opened "
    call msg_add_fname
    MSGADD " ("
    xor edi, edi
    mov rsi, [tlen]
    call count_nl
    lea rdi, [rax + 1]
    call msg_num
    MSGADD " lines)"
9:  pop r13
    pop r12
    pop rbx
    ret

msg_add_fname:                      # appends the file's base name
    mov rdx, [fname_len]
    lea rsi, [rdx + fname]
1:  cmp rsi, offset fname
    jbe 2f
    cmp byte ptr [rsi - 1], '/'
    je 2f
    dec rsi
    jmp 1b
2:  lea rdx, [rdx + fname]
    sub rdx, rsi
    jmp msg_add

open_cmd:
    call ask_save
    test rax, rax
    jz 2f
    mov qword ptr [plen], 0
    PROMPT "Open file: "
    test rax, rax
    jz 2f
    cmp qword ptr [plen], 0
    je 2f
    call copy_pbuf_to_fname
    call load_file
2:  ret

write_all:                          # rdi = fd, rsi = buf, rdx = n -> rax < 0 on error
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
1:  test r13, r13
    jz 2f
    mov eax, SYS_WRITE
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    syscall
    cmp rax, -EINTR
    je 1b
    cmp rax, -EAGAIN
    je 1b
    test rax, rax
    js 3f
    jz 4f
    add r12, rax
    sub r13, rax
    jmp 1b
4:  mov rax, -5
    jmp 3f
2:  xor eax, eax
3:  pop r13
    pop r12
    pop rbx
    ret

save_cmd:                           # rdi = 1 to always ask for a name
    push rbx
    push r12
    push r13
    push r14
    test rdi, rdi
    jnz 1f
    cmp qword ptr [fname_len], 0
    jne 2f
1:  lea rsi, [fname]                # pre-fill with the current name
    lea rdi, [pbuf]
    mov rcx, [fname_len]
    mov [plen], rcx
    rep movsb
    PROMPT "Save as: "
    test rax, rax
    jz 7f
    cmp qword ptr [plen], 0
    je 7f
    call copy_pbuf_to_fname
2:  mov eax, SYS_OPEN
    lea rdi, [fname]
    mov esi, O_WRCREAT
    mov edx, 0644
    syscall
    test rax, rax
    js 6f
    mov rbx, rax                    # fd
    cmp qword ptr [crlf], 0
    jne 3f
    mov rdi, rbx
    lea rsi, [text]
    mov rdx, [tlen]
    call write_all
    mov r12, rax
    mov r13, [tlen]
    jmp 5f
3:  xor r12d, r12d                  # write with CRLF line endings
    xor r13d, r13d                  # bytes written
    xor r14d, r14d                  # source index
    xor ecx, ecx                    # iobuf fill
31: cmp r14, [tlen]
    jae 33f
    mov al, [r14 + text]
    inc r14
    cmp al, 10
    jne 32f
    mov byte ptr [rcx + iobuf], 13
    inc rcx
32: mov [rcx + iobuf], al
    inc rcx
    cmp rcx, IO_MAX - 2
    jb 31b
33: test rcx, rcx
    jz 34f
    add r13, rcx
    mov rdi, rbx
    lea rsi, [iobuf]
    mov rdx, rcx
    call write_all
    xor ecx, ecx
    test rax, rax
    jns 31b
    mov r12, rax
    jmp 5f
34: cmp r14, [tlen]
    jb 31b
5:  mov eax, SYS_CLOSE
    mov rdi, rbx
    syscall
    test r12, r12
    js 8f
    test rax, rax
    js 8f
    mov qword ptr [dirty], 0
    SETMSG "Saved "
    call msg_add_fname
    MSGADD " ("
    mov rdi, r13
    call msg_num
    MSGADD " bytes)"
    jmp 9f
6:  neg rax
    mov rbx, rax
    SETMSG "\033[1;31mCannot write\033[0m "
    call msg_add_fname
    MSGADD " (error "
    mov rdi, rbx
    call msg_num
    MSGADD ")"
    jmp 9f
7:  SETMSG "Save cancelled"
    jmp 9f
8:  SETMSG "\033[1;31mError while writing\033[0m "
    call msg_add_fname
9:  pop r14
    pop r13
    pop r12
    pop rbx
    ret

# =============================================================================
#  Strings / output buffer
# =============================================================================
utoa:                               # rdi = n -> rsi = digits, rdx = length
    mov rax, rdi
    lea rsi, [numbuf + 32]
    mov ecx, 10
    xor r8d, r8d
1:  xor edx, edx
    div rcx
    add dl, '0'
    dec rsi
    mov [rsi], dl
    inc r8
    test rax, rax
    jnz 1b
    mov rdx, r8
    ret

append_to:                          # rsi = src, rdx = n, rdi = buf, r8 = &len, r9 = cap
    mov rax, [r8]
    mov rcx, r9
    sub rcx, rax
    cmp rdx, rcx
    jbe 1f
    mov rdx, rcx
1:  add rdi, rax
    mov rcx, rdx
    rep movsb
    add [r8], rdx
    ret

set_msg:
    mov qword ptr [msg_len], 0
msg_add:
    lea rdi, [msg]
    lea r8, [msg_len]
    mov r9d, MSG_MAX
    jmp append_to
msg_num:
    call utoa
    jmp msg_add

sb_add:
    lea rdi, [sb]
    lea r8, [sb_len]
    mov r9d, SB_MAX
    jmp append_to
sb_num:
    call utoa
    jmp sb_add

ob_flush:
    mov rdx, [oblen]
    test rdx, rdx
    jz 1f
    mov edi, 1
    lea rsi, [outbuf]
    call write_all
    mov qword ptr [oblen], 0
1:  ret

ob_write:                           # rsi = src, rdx = n
    mov rax, [oblen]
    lea rcx, [rax + rdx]
    cmp rcx, OUT_MAX
    jbe 1f
    push rsi
    push rdx
    call ob_flush
    pop rdx
    pop rsi
    xor eax, eax
1:  lea rdi, [rax + outbuf]
    mov rcx, rdx
    rep movsb
    add [oblen], rdx
    ret

ob_byte:                            # dil = byte
    mov rax, [oblen]
    cmp rax, OUT_MAX
    jb 1f
    push rdi
    call ob_flush
    pop rdi
    xor eax, eax
1:  mov [rax + outbuf], dil
    inc rax
    mov [oblen], rax
    ret

ob_num:
    call utoa
    jmp ob_write

# ob_write_cols: rsi = src, rdx = n, rcx = max columns. Escape sequences are
# copied without counting; UTF-8 continuation bytes take no column.
ob_write_cols:
    push rbx
    push r12
    push r13
    push r14
    mov rbx, rsi
    lea r12, [rsi + rdx]            # end
    mov r13, rcx                    # columns left
    xor r14d, r14d                  # 1 = inside an escape sequence
1:  cmp rbx, r12
    jae 9f
    movzx edi, byte ptr [rbx]
    test r14, r14
    jz 2f
    cmp edi, 0x40                   # final byte of the sequence?
    jb 4f
    cmp edi, '['
    je 4f
    xor r14d, r14d
    jmp 4f
2:  cmp edi, 27
    jne 3f
    mov r14d, 1
    jmp 4f
3:  mov eax, edi
    and eax, 0xC0
    cmp eax, 0x80
    je 4f
    test r13, r13
    jz 9f
    dec r13
4:  call ob_byte
    inc rbx
    jmp 1b
9:  pop r14
    pop r13
    pop r12
    pop rbx
    ret

ob_spaces:                          # rdi = count
    push rbx
    mov rbx, rdi
1:  test rbx, rbx
    jle 2f
    mov edi, ' '
    call ob_byte
    dec rbx
    jmp 1b
2:  pop rbx
    ret

# =============================================================================
#  Screen
# =============================================================================
refresh:
    push rbx
    push r12
    push r13
    push r14
    push r15
    push rbp
    call get_winsize
    mov rax, [rows]
    sub rax, 3                      # menu bar, status bar, message line
    cmp rax, 1
    jge 1f
    mov eax, 1
1:  mov [text_rows], rax

    xor edi, edi                    # cursor line and total line count
    mov rsi, [cur]
    call count_nl
    mov [cy], rax
    mov rdi, [cur]
    mov rsi, [tlen]
    sub rsi, rdi
    call count_nl
    add rax, [cy]
    inc rax
    mov [total_lines], rax

    mov rdi, rax                    # line-number gutter
    call utoa
    cmp rdx, 3
    jae 2f
    mov edx, 3
2:  add rdx, 2
    mov rax, [cols]
    sub rax, rdx
    cmp rax, 20
    jge 3f
    xor edx, edx
    mov rax, [cols]
3:  mov [gutter], rdx
    mov [text_cols], rax

    mov rdi, [cur]                  # cursor column
    call line_start
    mov rbx, rax
    mov rdi, rbx
    mov rsi, [cur]
    call col_of
    mov [rx], rax

    mov rax, [cy]                   # keep the cursor on screen
    mov rcx, [rowoff]
    cmp rax, rcx
    jae 4f
    mov rcx, rax
4:  mov rdx, rcx
    add rdx, [text_rows]
    cmp rax, rdx
    jb 5f
    mov rcx, rax
    sub rcx, [text_rows]
    inc rcx
5:  mov [rowoff], rcx
    mov rax, [rx]
    mov rcx, [coloff]
    cmp rax, rcx
    jae 6f
    mov rcx, rax
6:  mov rdx, rcx
    add rdx, [text_cols]
    cmp rax, rdx
    jb 7f
    mov rcx, rax
    sub rcx, [text_cols]
    inc rcx
7:  mov [coloff], rcx

    mov r12, [cy]                   # walk back to the first visible line
    sub r12, [rowoff]
8:  test r12, r12
    jz 9f
    lea rdi, [rbx - 1]
    call line_start
    mov rbx, rax
    dec r12
    jmp 8b
9:
    call get_sel                    # highlight: selection, else search hit
    cmp rax, -1
    je 10f
    mov [hl_start], rax
    mov [hl_end], rdx
    jmp 12f
10: mov rax, [found_pos]
    cmp rax, -1
    je 11f
    mov [hl_start], rax
    add rax, [slen]
    mov [hl_end], rax
    jmp 12f
11: mov qword ptr [hl_start], 0
    mov qword ptr [hl_end], 0
12:
    mov qword ptr [oblen], 0
    OBS "\033[?25l\033[H"
    call draw_menubar
    mov r13, [rowoff]               # line number
    xor r14d, r14d                  # screen row
.Lrf_row:
    cmp r14, [text_rows]
    jae .Lrf_status
    mov r15, [gutter]
    cmp r13, [total_lines]
    jae .Lrf_tilde
    test r15, r15
    jz .Lrf_text
    cmp r13, [cy]
    jne 1f
    OBS "\033[33m"
    jmp 2f
1:  OBS "\033[90m"
2:  lea rdi, [r13 + 1]
    call utoa
    push rsi
    push rdx
    mov rdi, r15
    sub rdi, 2
    sub rdi, rdx
    call ob_spaces
    pop rdx
    pop rsi
    call ob_write
    OBS "  \033[0m"
.Lrf_text:
    mov rdi, rbx
    call draw_line
    mov rbx, rax
    inc r13
    jmp .Lrf_eol
.Lrf_tilde:
    OBS "\033[90m~\033[0m"
.Lrf_eol:
    OBS "\033[K\r\n"
    inc r14
    jmp .Lrf_row

.Lrf_status:
    cmp qword ptr [menu_open], -1
    je 1f
    call draw_dropdown
1:  mov rdi, [rows]
    dec rdi
    mov esi, 1
    call ob_goto
    mov qword ptr [sb_len], 0
    SBADD " BeeNote \342\200\224 "
    mov rdx, [fname_len]
    test rdx, rdx
    jz 1f
    lea rsi, [rdx + fname]          # show only the base name
13: cmp rsi, offset fname
    jbe 14f
    cmp byte ptr [rsi - 1], '/'
    je 14f
    dec rsi
    jmp 13b
14: lea rdx, [rdx + fname]
    sub rdx, rsi
    call sb_add
    jmp 2f
1:  SBADD "[untitled]"
2:  cmp qword ptr [dirty], 0
    je 3f
    SBADD " [modified]"
3:  mov r12, [sb_len]               # r12 = left part length (bytes)
    SBADD "Ln "
    mov rdi, [cy]
    inc rdi
    call sb_num
    SBADD ", Col "
    mov rdi, [rx]
    inc rdi
    call sb_num
    mov rbp, [sb_len]               # rbp = end of the short right part
    SBADD "  \342\224\202  "
    mov rdi, [total_lines]
    call sb_num
    SBADD " lines  \342\224\202  "
    cmp qword ptr [crlf], 0
    je 4f
    SBADD "CRLF"
    jmp 5f
4:  SBADD "LF"
5:  SBADD "  \342\224\202  UTF-8"
    OBS "\033[7m"
    mov r14, [cols]
    mov r13, [sb_len]               # full right part: 3 box chars are 3 bytes / 1 column
    sub r13, r12
    lea r15, [r13 - 6]
    lea rax, [r12 + r15 + 1]        # left width = bytes - 2 (em dash), +3 spacing
    cmp rax, r14
    jbe 51f
    mov r13, rbp                    # fall back to "Ln, Col" only
    sub r13, r12
    mov r15, r13
    lea rax, [r12 + r15 + 1]
    cmp rax, r14
    ja 6f
51: lea rsi, [sb]
    mov rdx, r12
    call ob_write
    mov rdi, r14
    sub rdi, r12
    add rdi, 1
    sub rdi, r15
    call ob_spaces
    lea rsi, [r12 + sb]
    mov rdx, r13
    call ob_write
    mov edi, ' '
    call ob_byte
    jmp 7f
6:  lea rsi, [sb]                   # very narrow: left part only
    mov rdx, r12
    mov rcx, r14
    call ob_write_cols
    mov rdi, r14
    sub rdi, r12
    add rdi, 2
    call ob_spaces
7:  OBS "\033[0m\r\n\033[K"

    mov rdx, [msg_len]              # message line (or key help)
    test rdx, rdx
    jz 8f
    lea rsi, [msg]
    mov rcx, [cols]
    call ob_write_cols
    jmp 9f
8:  OBS "\033[2m"
    lea rsi, [help_txt]
    mov edx, help_end - help_txt
    mov rcx, [cols]
    call ob_write_cols
    OBS "\033[0m"
9:
    cmp qword ptr [prompt_active], 0
    je 10f
    mov r12, [rows]                 # cursor at the end of the prompt
    xor r13d, r13d
    xor ecx, ecx
91: cmp rcx, [msg_len]
    jae 92f
    movzx edx, byte ptr [rcx + msg]
    inc rcx
    cmp edx, 27                     # escape sequences take no space
    jne 94f
93: cmp rcx, [msg_len]
    jae 92f
    movzx edx, byte ptr [rcx + msg]
    inc rcx
    cmp edx, '['
    je 93b
    cmp edx, 0x40
    jb 93b
    jmp 91b
94: and edx, 0xC0
    cmp edx, 0x80
    je 91b
    inc r13
    jmp 91b
92: inc r13
    cmp r13, [cols]
    jbe 11f
    mov r13, [cols]
    jmp 11f
10: mov r12, [cy]
    sub r12, [rowoff]
    add r12, 2
    mov r13, [rx]
    sub r13, [coloff]
    add r13, [gutter]
    inc r13
11: mov rdi, r12
    mov rsi, r13
    call ob_goto
    cmp qword ptr [menu_open], -1   # no text cursor while a menu is open
    jne 12f
    OBS "\033[?25h"
12: call ob_flush
    pop rbp
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# draw_line: rdi = line start -> rax = start of the next line
draw_line:
    push rbx
    push r12
    push r13
    push r14
    push r15
    push rbp
    mov rbx, rdi                    # position
    xor r12d, r12d                  # rendered column
    mov r13, [coloff]
    mov r14, r13
    add r14, [text_cols]            # first column past the screen
    xor r15d, r15d                  # bit0: last lead byte shown, bit1: highlight on
.Ldl_loop:
    cmp rbx, [tlen]
    jae .Ldl_end
    cmp byte ptr [rbx + text], 10
    je .Ldl_nl
    xor ecx, ecx
    cmp rbx, [hl_start]
    jb 1f
    cmp rbx, [hl_end]
    jae 1f
    mov ecx, 2
1:  mov edx, r15d
    and edx, 2
    cmp ecx, edx
    je .Ldl_char
    xor r15d, 2
    test ecx, ecx
    jz 2f
    OBS "\033[7m"
    jmp .Ldl_char
2:  OBS "\033[27m"
.Ldl_char:
    movzx eax, byte ptr [rbx + text]
    cmp eax, 9
    je .Ldl_tab
    mov ecx, eax
    and ecx, 0xC0
    cmp ecx, 0x80
    je .Ldl_cont
    and r15d, ~1
    cmp eax, 32
    jb .Ldl_ctrl
    cmp eax, 127
    je .Ldl_ctrl
    cmp r12, r13
    jb .Ldl_adv
    cmp r12, r14
    jae .Ldl_adv
    or r15d, 1
    mov edi, eax
    call ob_byte
.Ldl_adv:
    inc r12
    inc rbx
    jmp .Ldl_loop
.Ldl_ctrl:                          # control characters are shown as '?'
    cmp r12, r13
    jb .Ldl_adv
    cmp r12, r14
    jae .Ldl_adv
    mov edi, '?'
    call ob_byte
    jmp .Ldl_adv
.Ldl_cont:                          # UTF-8 continuation byte
    test r15d, 1
    jz 3f
    mov edi, eax
    call ob_byte
3:  inc rbx
    jmp .Ldl_loop
.Ldl_tab:
    and r15d, ~1
    mov rbp, r12
    or rbp, TABW - 1
    inc rbp
4:  cmp r12, rbp
    jae 6f
    cmp r12, r13
    jb 5f
    cmp r12, r14
    jae 5f
    mov edi, ' '
    call ob_byte
5:  inc r12
    jmp 4b
6:  inc rbx
    jmp .Ldl_loop
.Ldl_nl:
    inc rbx
.Ldl_end:
    test r15d, 2
    jz 7f
    OBS "\033[27m"
7:  mov rax, rbx
    pop rbp
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

ob_goto:                            # rdi = row, rsi = column (1-based)
    push rbx
    push r12
    mov rbx, rdi
    mov r12, rsi
    OBS "\033["
    mov rdi, rbx
    call ob_num
    mov edi, ';'
    call ob_byte
    mov rdi, r12
    call ob_num
    mov edi, 'H'
    call ob_byte
    pop r12
    pop rbx
    ret

ob_hline:                           # rdi = width of a horizontal box line
    push rbx
    mov rbx, rdi
1:  test rbx, rbx
    jle 2f
    OBS "\342\224\200"
    dec rbx
    jmp 1b
2:  pop rbx
    ret

# =============================================================================
#  Menus
# =============================================================================
draw_menubar:                       # top row: titles, with the open one highlighted
    push rbx
    push r12
    OBS "\033[7m"
    xor ebx, ebx                    # menu index
    xor r12d, r12d                  # columns used
1:  cmp rbx, NMENUS
    jae 4f
    cmp rbx, [menu_open]
    jne 2f
    OBS "\033[27;1m"
2:  mov edi, ' '
    call ob_byte
    mov rax, rbx
    shl rax, 5
    mov rsi, [rax + menu_tab]
    mov rdx, [rax + menu_tab + 8]
    lea r12, [r12 + rdx + 2]
    push rsi
    push rdx
    OBS "\033[4m"                   # underline the Alt+letter
    mov rsi, [rsp + 8]
    movzx edi, byte ptr [rsi]
    call ob_byte
    OBS "\033[24m"
    pop rdx
    pop rsi
    inc rsi
    dec rdx
    call ob_write
    mov edi, ' '
    call ob_byte
    cmp rbx, [menu_open]
    jne 3f
    OBS "\033[22;7m"
3:  inc rbx
    jmp 1b
4:  mov rdi, [cols]
    sub rdi, r12
    sub rdi, menu_hint_end - menu_hint
    jl 5f
    call ob_spaces
    lea rsi, [menu_hint]
    mov edx, menu_hint_end - menu_hint
    call ob_write
    jmp 6f
5:  mov rdi, [cols]
    sub rdi, r12
    call ob_spaces
6:  OBS "\033[0m\r\n"
    pop r12
    pop rbx
    ret

menu_items:                         # rax = items of the open menu, rdx = count
    mov rax, [menu_open]
    shl rax, 5
    mov rdx, [rax + menu_tab + 24]
    mov rax, [rax + menu_tab + 16]
    ret

draw_item_text:                     # rdi = item; mnemonic letter underlined
    push rbx
    push r12
    mov rbx, rdi
    xor r12d, r12d
1:  cmp r12, MW
    jae 9f
    cmp r12, [rbx + 8]
    jne 2f
    OBS "\033[4m"
    movzx edi, byte ptr [rbx + r12 + 16]
    call ob_byte
    OBS "\033[24m"
    jmp 3f
2:  movzx edi, byte ptr [rbx + r12 + 16]
    call ob_byte
3:  inc r12
    jmp 1b
9:  pop r12
    pop rbx
    ret

draw_dropdown:                      # box below the open menu's title
    push rbx
    push r12
    push r13
    push r14
    push r15
    push rbp
    mov r13d, 1                     # r13 = left column
    xor ecx, ecx
1:  cmp rcx, [menu_open]
    jae 2f
    mov rax, rcx
    shl rax, 5
    add r13, [rax + menu_tab + 8]
    add r13, 2
    inc rcx
    jmp 1b
2:  mov rax, [cols]                 # keep the box on screen
    sub rax, MW + 1
    cmp r13, rax
    jle 3f
    mov r13, rax
3:  cmp r13, 1
    jge 4f
    mov r13d, 1
4:  call menu_items
    mov r14, rax                    # items
    mov r15, rdx                    # count
    mov r12d, 2                     # screen row
    mov rdi, r12
    mov rsi, r13
    call ob_goto
    OBS "\033[0m\342\224\214"
    mov edi, MW
    call ob_hline
    OBS "\342\224\220"
    xor ebp, ebp                    # item index
5:  cmp rbp, r15
    jae 8f
    inc r12
    mov rax, [rows]
    dec rax
    cmp r12, rax                    # never draw over the status bar
    jae 9f
    mov rdi, r12
    mov rsi, r13
    call ob_goto
    imul rbx, rbp, 40
    add rbx, r14
    cmp qword ptr [rbx], 0
    jne 6f
    OBS "\342\224\234"              # separator
    mov edi, MW
    call ob_hline
    OBS "\342\224\244"
    jmp 7f
6:  OBS "\342\224\202"
    cmp rbp, [menu_sel]
    jne 61f
    OBS "\033[7m"
61: mov rdi, rbx
    call draw_item_text
    OBS "\033[27m\342\224\202"
7:  inc rbp
    jmp 5b
8:  inc r12
    mov rax, [rows]
    dec rax
    cmp r12, rax
    jae 9f
    mov rdi, r12
    mov rsi, r13
    call ob_goto
    OBS "\342\224\224"
    mov edi, MW
    call ob_hline
    OBS "\342\224\230"
9:  pop rbp
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

menu_find:                          # dil = lower-case letter -> rax = menu index / -1
    xor eax, eax
    or dil, 0x20
1:  cmp rax, NMENUS
    jae 2f
    mov rcx, rax
    shl rcx, 5
    mov rcx, [rcx + menu_tab]
    movzx edx, byte ptr [rcx]
    or dl, 0x20
    cmp dl, dil
    je 3f
    inc rax
    jmp 1b
2:  mov rax, -1
3:  ret

menu_move:                          # rdi = +1 / -1, skipping separators
    mov r8, rdi
    call menu_items
    mov r9, rax
    mov rcx, [menu_sel]
1:  add rcx, r8
    jns 2f
    lea rcx, [rdx - 1]
2:  cmp rcx, rdx
    jb 3f
    xor ecx, ecx
3:  imul rax, rcx, 40
    cmp qword ptr [r9 + rax], 0
    je 1b
    mov [menu_sel], rcx
    ret

# menu_key: rdi = key; opens a menu for F10 / Alt+letter.
# rax = key to process (the chosen item's shortcut, or the key itself)
menu_key:
    mov rax, rdi
    cmp rax, K_F10
    jne 1f
    xor edi, edi
    jmp run_menu
1:  test rax, K_ALT
    jz 2f
    call menu_find
    cmp rax, -1
    je 3f
    mov rdi, rax
    jmp run_menu
3:  mov eax, K_NONE
2:  ret

run_menu:                           # rdi = menu index -> rax = key to process
    push rbx
    mov [menu_open], rdi
    mov qword ptr [menu_sel], 0
.Lrm_loop:
    call refresh
    call read_key
    mov rbx, rax
    cmp rbx, K_ESC
    je .Lrm_none
    cmp rbx, K_F10
    je .Lrm_none
    cmp rbx, K_LEFT
    jne 1f
    mov rax, [menu_open]
    add rax, NMENUS - 1
    jmp 2f
1:  cmp rbx, K_RIGHT
    jne 3f
    mov rax, [menu_open]
    inc rax
2:  xor edx, edx
    mov ecx, NMENUS
    div rcx
    mov [menu_open], rdx
    mov qword ptr [menu_sel], 0
    jmp .Lrm_loop
3:  cmp rbx, K_UP
    jne 4f
    mov rdi, -1
    call menu_move
    jmp .Lrm_loop
4:  cmp rbx, K_DOWN
    jne 5f
    mov edi, 1
    call menu_move
    jmp .Lrm_loop
5:  cmp rbx, K_ENTER
    je 6f
    cmp rbx, K_CTRL_J
    jne 7f
6:  call menu_items
    imul rcx, [menu_sel], 40
    mov rax, [rax + rcx]
    jmp .Lrm_ret
7:  test rbx, K_ALT                 # Alt+letter: switch menus
    jz 8f
    mov edi, ebx
    call menu_find
    cmp rax, -1
    je .Lrm_loop
    mov [menu_open], rax
    mov qword ptr [menu_sel], 0
    jmp .Lrm_loop
8:  cmp rbx, 256                    # mnemonic letter picks an item
    jae .Lrm_loop
    or bl, 0x20
    call menu_items
    xor ecx, ecx
9:  cmp rcx, rdx
    jae .Lrm_loop
    imul r8, rcx, 40
    add r8, rax
    cmp qword ptr [r8], 0
    je 10f
    mov r9, [r8 + 8]
    movzx r9d, byte ptr [r8 + r9 + 16]
    or r9b, 0x20
    cmp r9b, bl
    jne 10f
    mov rax, [r8]
    jmp .Lrm_ret
10: inc rcx
    jmp 9b
.Lrm_none:
    mov eax, K_NONE
.Lrm_ret:
    mov qword ptr [menu_open], -1
    pop rbx
    ret

# =============================================================================
#  Dialogs
# =============================================================================
# ask_save: before discarding a modified document. rax = 1 to go ahead, 0 to stop.
ask_save:
    cmp qword ptr [dirty], 0
    je 8f
    push rbx
1:  SETMSG "\033[1mSave changes to "
    cmp qword ptr [fname_len], 0
    je 2f
    call msg_add_fname
    jmp 3f
2:  MSGADD "this document"
3:  MSGADD "?\033[0m  (Y)es  (N)o  (Esc) Cancel "
    mov qword ptr [prompt_active], 1
    call refresh
    call read_key
    mov rbx, rax
    mov qword ptr [prompt_active], 0
    mov qword ptr [msg_len], 0
    cmp rbx, 'y'
    je 4f
    cmp rbx, 'Y'
    je 4f
    cmp rbx, K_ENTER
    je 4f
    cmp rbx, 'n'
    je 5f
    cmp rbx, 'N'
    je 5f
    cmp rbx, K_ESC
    je 6f
    cmp rbx, K_CTRL_C
    je 6f
    jmp 1b
4:  xor edi, edi
    call save_cmd
    cmp qword ptr [dirty], 0
    jne 6f                          # save failed or was cancelled
5:  mov eax, 1
    pop rbx
    ret
6:  xor eax, eax
    pop rbx
    ret
8:  mov eax, 1
    ret

show_help:
    mov qword ptr [oblen], 0
    OBS "\033[?25l\033[H\033[2J"
    lea rsi, [help_screen]
    mov edx, help_screen_end - help_screen
    call ob_write
    call ob_flush
    call read_key
    ret
