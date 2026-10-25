# =============================================================================
#  BeeNote - input and commands: the event queue, the keyboard and the
#  mouse, menus, the prompt bar (find as you type, go to line, open and save
#  as with Tab completion), dialogs, and every command.
#
#  The compositor's events arrive while wayland.s is parsing its buffer, so
#  the ui_* callbacks only queue them; process_events handles them after.
#  That way a command may wait for an answer (a dialog, the prompt bar) by
#  running the event loop itself (pump in main.s).
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "beenote.inc"

.globl ui_init
.globl ui_key
.globl ui_key_repeat
.globl ui_motion
.globl ui_button
.globl ui_axis
.globl ui_leave
.globl ui_drop_file
.globl request_quit
.globl process_events
.globl ui_config_changed
.globl key_mods
.globl enter_serial
.globl cur_shape
.globl key_chars
.globl pr_scale
.globl base_px
.globl modal
.globl typed_char
.globl utf8_enc
.globl set_cursor_default

.equ EVQ_N,         512                 # queued events (a power of two)
.equ EV_SZ,         32
.equ PASTE_CAP,     4194304
.equ SYS_GETCWD,    79
.equ SYS_GETDENTS64, 217
.equ SYS_STAT,      4

.section .data
.align 4
pr_scale:       .long 100               # (BeeModel's UI scale preference: 100 %)
base_px:        .long 16                # the configured document font size (px)

.section .bss
.align 8
key_mods:       .skip 4                 # (wayland.s: the depressed modifiers)
enter_serial:   .skip 4
cur_shape:      .skip 4
evq_head:       .skip 4
evq_tail:       .skip 4
dead_key:       .skip 4                 # a dead key waiting for its letter
.align 8
mx:             .skip 8                 # the pointer, physical px
my:             .skip 8
drag_mode:      .skip 8                 # 1 selecting text, 2 the scrollbar's thumb
drag_unit:      .skip 8                 # 0 characters, 1 words, 2 lines
drag_s:         .skip 8
drag_e:         .skip 8
drag_off:       .skip 8
click_time:     .skip 8
click_x:        .skip 8
click_y:        .skip 8
click_n:        .skip 8
zoom_acc:       .skip 8
modal:          .skip 8                 # dialogs / prompts open (nested loops)
dlg_result:     .skip 8
prompt_done:    .skip 8
prompt_result:  .skip 8
find_origin:    .skip 8
clip_line:      .skip 8                 # the clipboard holds whole lines (ours)
chbuf:          .skip 8
drop_req:       .skip 1024
dirbuf:         .skip 4096              # Tab completion
lcp:            .skip 1024
statb:          .skip 144
.align 64
evq:            .skip EVQ_N*EV_SZ
pastebuf:       .skip PASTE_CAP + 8

.section .rodata
key_chars:                              # evdev 0..57 -> the QWERTY letter (keyboard.s)
    .byte 0, 0
    .ascii "1234567890-="
    .byte 0, 0
    .ascii "QWERTYUIOP[]"
    .byte 0, 0
    .ascii "ASDFGHJKL;'`"
    .byte 0
    .ascii "\\ZXCVBNM,./"
    .byte 0, '*', 0, 0
modifier_keys:  .byte 29, 97, 42, 54, 56, 100, 125, 126, 58, 69, 0
s_home:         .asciz "HOME="
l_find:         .asciz "Find:"
l_goto:         .asciz "Go to line:"
l_open:         .asciz "Open file:"
l_saveas:       .asciz "Save as:"
s_untitled_txt: .asciz "untitled.txt"

.text

# =============================================================================
#  The queue (filled from wayland.s's callbacks)
# =============================================================================
# enqueue(edi=type, esi=a, edx=b, ecx=c, r8d=d)
enqueue:
    mov     eax, [rip+evq_tail]
    lea     r9d, [rax+1]
    and     r9d, EVQ_N-1
    cmp     r9d, [rip+evq_head]
    je      9f                          # full: dropped
    shl     eax, 5
    lea     r10, [rip+evq]
    add     r10, rax
    mov     [r10], edi
    mov     [r10+4], esi
    mov     [r10+8], edx
    mov     [r10+12], ecx
    mov     [r10+16], r8d
    mov     [rip+evq_tail], r9d
9:  ret

# key_event(edi=evdev) - queue a key with what it types now (the modifiers
#   may change before the queue is read)
key_event:
    push    rbx
    push    r12
    push    r13
    mov     ebx, edi
    call    kb_text
    mov     r12d, eax                   # symbol
    call    kb_canon_mods
    mov     r13d, eax
    mov     edi, ebx
    call    kb_layout_code
    shl     eax, 16
    or      r13d, eax
    mov     edi, EV_KEY
    mov     esi, ebx
    mov     edx, r12d
    mov     ecx, r13d
    xor     r8d, r8d
    call    enqueue
    pop     r13
    pop     r12
    pop     rbx
    ret

# ui_key(edi=evdev, esi=state)
ui_key:
    cmp     esi, 1
    je      1f
    cmp     edi, [rip+rep_code]         # released: no more repeats
    jne     9f
    jmp     kb_repeat_stop
1:  push    rbx
    mov     ebx, edi
    call    key_event
    lea     rax, [rip+modifier_keys]    # held keys repeat, modifiers not
2:  movzx   ecx, byte ptr [rax]
    test    ecx, ecx
    jz      3f
    cmp     ecx, ebx
    je      4f
    inc     rax
    jmp     2b
3:  mov     edi, ebx
    call    kb_repeat_start
4:  pop     rbx
9:  ret

# ui_key_repeat(edi=evdev) - the repeat timer (keyboard.s)
ui_key_repeat:
    jmp     key_event

ui_motion:                              # (edi=x, esi=y) logical
    mov     eax, [rip+evq_tail]         # the last queued event a motion too?
    cmp     eax, [rip+evq_head]
    je      1f
    dec     eax
    and     eax, EVQ_N-1
    shl     eax, 5
    lea     rcx, [rip+evq]
    cmp     dword ptr [rcx+rax], EV_MOTION
    jne     1f
    mov     [rcx+rax+4], edi            # yes: it moves on
    mov     [rcx+rax+8], esi
    ret
1:  mov     edx, esi
    mov     esi, edi
    mov     edi, EV_MOTION
    xor     ecx, ecx
    xor     r8d, r8d
    jmp     enqueue

ui_button:                              # (edi=button, esi=state, edx=serial, ecx=time)
    push    rbx
    push    r12
    push    r13
    mov     ebx, edi
    mov     r12d, esi
    mov     r13d, ecx
    test    esi, esi
    jz      1f
    mov     [rip+clip_serial], edx      # (setting the clipboard needs one)
1:  call    kb_canon_mods
    mov     r8d, eax
    mov     edi, EV_BUTTON
    mov     esi, ebx
    mov     edx, r12d
    mov     ecx, r13d
    call    enqueue
    pop     r13
    pop     r12
    pop     rbx
    ret

ui_axis:                                # (edi=axis, esi=value 24.8)
    push    rbx
    push    r12
    mov     ebx, edi
    mov     r12d, esi
    call    kb_canon_mods
    mov     ecx, eax
    mov     edi, EV_AXIS
    mov     esi, ebx
    mov     edx, r12d
    xor     r8d, r8d
    call    enqueue
    pop     r12
    pop     rbx
    ret

ui_leave:
    mov     edi, EV_LEAVE
    xor     esi, esi
    xor     edx, edx
    xor     ecx, ecx
    xor     r8d, r8d
    jmp     enqueue

request_quit:                           # the window's close button
    mov     edi, EV_CLOSE
    xor     esi, esi
    xor     edx, edx
    xor     ecx, ecx
    xor     r8d, r8d
    jmp     enqueue

ui_drop_file:                           # (rdi=path) a file dropped on the window
    lea     rsi, [rip+drop_req]
    xor     ecx, ecx
1:  mov     al, [rdi+rcx]
    mov     [rsi+rcx], al
    inc     ecx
    test    al, al
    jz      2f
    cmp     ecx, 1023
    jb      1b
    mov     byte ptr [rsi+rcx], 0
2:  mov     edi, EV_DROP
    xor     esi, esi
    xor     edx, edx
    xor     ecx, ecx
    xor     r8d, r8d
    jmp     enqueue

# process_events - handle what was queued (may run nested loops)
process_events:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
1:  mov     eax, [rip+evq_head]
    cmp     eax, [rip+evq_tail]
    je      9f
    mov     ecx, eax
    shl     ecx, 5
    lea     rdx, [rip+evq]
    add     rdx, rcx
    mov     ebx, [rdx]                  # (taken out before it is handled)
    mov     r12d, [rdx+4]
    mov     r13d, [rdx+8]
    mov     r14d, [rdx+12]
    mov     r15d, [rdx+16]
    inc     eax
    and     eax, EVQ_N-1
    mov     [rip+evq_head], eax
    mov     edi, r12d
    mov     esi, r13d
    mov     edx, r14d
    mov     ecx, r15d
    cmp     ebx, EV_KEY
    jne     2f
    call    on_key
    jmp     1b
2:  cmp     ebx, EV_MOTION
    jne     3f
    call    on_motion
    jmp     1b
3:  cmp     ebx, EV_BUTTON
    jne     4f
    call    on_button
    jmp     1b
4:  cmp     ebx, EV_AXIS
    jne     5f
    call    on_axis
    jmp     1b
5:  cmp     ebx, EV_CLOSE
    jne     6f
    cmp     qword ptr [rip+modal], 0    # (a dialog or prompt is open: ignored)
    jne     1b
    mov     edi, CMD_QUIT
    call    run_cmd
    jmp     1b
6:  cmp     ebx, EV_DROP
    jne     7f
    call    on_drop
    jmp     1b
7:  cmp     ebx, EV_LEAVE
    jne     1b
    mov     qword ptr [rip+hover_thumb], 0
    mov     dword ptr [rip+dirty], 1
    jmp     1b
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  Keyboard
# =============================================================================
# on_key(edi=evdev, esi=symbol, edx=mods | layout code << 16)
on_key:
    mov     ecx, edx
    shr     ecx, 16                     # layout code
    and     edx, 0xffff                 # mods
    cmp     qword ptr [rip+dlg_kind], 0
    jne     dlg_key
    cmp     qword ptr [rip+fd_open], 0
    jne     fd_key
    cmp     qword ptr [rip+menu_open], 0
    jge     menu_key
    cmp     qword ptr [rip+prompt_mode], 0
    jne     prompt_key
    jmp     ed_key

# typed_char(esi=symbol) -> eax = the character to type, 0 for none (a dead
#   key is remembered and combined with the next one)
typed_char:
    test    esi, esi
    jns     1f
    and     esi, 0x7fffffff             # a dead key
    mov     [rip+dead_key], esi
    xor     eax, eax
    ret
1:  xor     eax, eax
    cmp     esi, 0x20
    jb      9f
    cmp     esi, 0x7f
    je      9f
    cmp     esi, 0x10ffff
    ja      9f
    mov     eax, esi
    mov     edi, [rip+dead_key]
    test    edi, edi
    jz      9f
    mov     dword ptr [rip+dead_key], 0
    push    rax
    call    kb_compose
    pop     rcx
    test    eax, eax
    jnz     9f
    mov     eax, ecx                    # no combination: the plain letter
9:  ret

# ed_key(edi=evdev, esi=symbol, edx=mods, ecx=layout code) - the document
ed_key:
    push    rbx
    push    r12
    push    r13
    push    r14
    mov     ebx, edi
    mov     r12d, esi
    mov     r13d, edx
    mov     r14d, ecx
    mov     qword ptr [rip+msg_len], 0
    mov     edi, CMD_HELP
    cmp     ebx, KEY_F1
    je      .Lek_cmd
    cmp     ebx, EK_F3
    jne     1f
    mov     edi, CMD_NEXT
    test    r13d, MOD_SHIFT
    jz      .Lek_cmd
    mov     edi, CMD_PREV
    jmp     .Lek_cmd
1:  cmp     ebx, EK_F10
    jne     2f
    xor     edi, edi
    xor     esi, esi
    call    open_menu
    jmp     .Lek_ret
2:  cmp     ebx, KEY_ESC
    jne     3f
    mov     qword ptr [rip+sel_anchor], -1
    mov     dword ptr [rip+dirty], 1
    jmp     .Lek_ret
3:  test    r13d, MOD_ALT               # Alt+letter: a menu
    jz      4f
    test    r13d, MOD_CTRL
    jnz     4f
    mov     edi, r12d
    call    menu_find
    cmp     rax, -1
    je      .Lek_ret
    mov     rdi, rax
    xor     esi, esi
    call    open_menu
    jmp     .Lek_ret
4:  test    r13d, MOD_CTRL
    jz      .Lek_nav
    # Ctrl shortcuts (by the key's letter on this keyboard layout)
    lea     rax, [rip+ctrl_keys]
5:  movzx   ecx, word ptr [rax]
    test    ecx, ecx
    jz      .Lek_nav
    cmp     ecx, r14d
    je      6f
    cmp     ecx, ebx
    je      6f
    add     rax, 6
    jmp     5b
6:  movzx   edi, word ptr [rax+2]       # the command (with Shift: the other one)
    test    r13d, MOD_SHIFT
    jz      .Lek_cmd
    movzx   ecx, word ptr [rax+4]
    test    ecx, ecx
    jz      .Lek_cmd
    mov     edi, ecx
.Lek_cmd:
    call    run_cmd
    jmp     .Lek_ret
.Lek_nav:
    lea     rax, [rip+nav_keys]         # movement and editing keys
7:  movzx   ecx, word ptr [rax]
    test    ecx, ecx
    jz      .Lek_char
    cmp     ecx, ebx
    je      8f
    add     rax, 6
    jmp     7b
8:  movzx   edi, word ptr [rax+2]
    test    r13d, MOD_CTRL
    jz      81f
    movzx   ecx, word ptr [rax+4]
    test    ecx, ecx
    jz      81f
    mov     edi, ecx
81: cmp     edi, K_DOCEND               # movements extend the selection with Shift
    ja      82f
    test    r13d, MOD_SHIFT
    jz      82f
    or      edi, K_SHIFT
82: call    edit_key
    jmp     .Lek_ret
.Lek_char:
    test    r13d, MOD_CTRL
    jnz     .Lek_ret
    mov     esi, r12d
    call    typed_char
    test    eax, eax
    jz      .Lek_ret
    mov     edi, eax
    or      edi, K_CHAR
    call    edit_key
.Lek_ret:
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

.section .rodata
.align 2
ctrl_keys:      # key, command, command with Shift
    .short 44, CMD_UNDO, CMD_REDO        # Z
    .short 21, CMD_REDO, 0               # Y
    .short 45, CMD_CUT, 0                # X
    .short 46, CMD_COPY, 0               # C
    .short 47, CMD_PASTE, 0              # V
    .short 30, CMD_SELALL, 0             # A
    .short 31, CMD_SAVE, CMD_SAVEAS      # S
    .short 24, CMD_OPEN, 0               # O
    .short 49, CMD_NEW, 0                # N
    .short 33, CMD_FIND, 0               # F
    .short 34, CMD_GOTO, 0               # G
    .short 16, CMD_QUIT, 0               # Q
    .short 13, CMD_ZOOMIN, CMD_ZOOMIN    # = / +
    .short 78, CMD_ZOOMIN, 0             # keypad +
    .short 12, CMD_ZOOMOUT, 0            # -
    .short 74, CMD_ZOOMOUT, 0            # keypad -
    .short 11, CMD_ZOOM0, 0              # 0
    .short 0
nav_keys:       # key, editor key, with Ctrl
    .short 105, K_LEFT, K_WLEFT
    .short 106, K_RIGHT, K_WRIGHT
    .short 103, K_UP, 0
    .short 108, K_DOWN, 0
    .short 102, K_HOME, K_DOCHOME
    .short 107, K_END, K_DOCEND
    .short 104, K_PGUP, 0
    .short 109, K_PGDN, 0
    .short 111, K_DEL, K_WDEL
    .short 14, K_BS, K_WBS
    .short 28, K_ENTER, 0
    .short 96, K_ENTER, 0
    .short 15, K_TAB, 0
    .short 0
.text

# utf8_enc(edi=code point, rsi=dest) -> eax = bytes (1..4)
utf8_enc:
    cmp     edi, 0x80
    jae     1f
    mov     [rsi], dil
    mov     eax, 1
    ret
1:  cmp     edi, 0x800
    jae     2f
    mov     eax, edi
    shr     eax, 6
    or      al, 0xC0
    mov     [rsi], al
    mov     eax, edi
    and     al, 0x3F
    or      al, 0x80
    mov     [rsi+1], al
    mov     eax, 2
    ret
2:  cmp     edi, 0x10000
    jae     3f
    mov     eax, edi
    shr     eax, 12
    or      al, 0xE0
    mov     [rsi], al
    mov     eax, edi
    shr     eax, 6
    and     al, 0x3F
    or      al, 0x80
    mov     [rsi+1], al
    mov     eax, edi
    and     al, 0x3F
    or      al, 0x80
    mov     [rsi+2], al
    mov     eax, 3
    ret
3:  mov     eax, edi
    shr     eax, 18
    or      al, 0xF0
    mov     [rsi], al
    mov     eax, edi
    shr     eax, 12
    and     al, 0x3F
    or      al, 0x80
    mov     [rsi+1], al
    mov     eax, edi
    shr     eax, 6
    and     al, 0x3F
    or      al, 0x80
    mov     [rsi+2], al
    mov     eax, edi
    and     al, 0x3F
    or      al, 0x80
    mov     [rsi+3], al
    mov     eax, 4
    ret

move_up:
    mov     rdi, [rip+cur]
    call    line_start
    test    rax, rax
    jz      1f
    lea     rdi, [rax-1]
    call    line_start
    mov     rdi, rax
    mov     rsi, [rip+want_col]
    call    pos_at_col
    mov     [rip+cur], rax
1:  ret

move_down:
    mov     rdi, [rip+cur]
    call    line_end
    cmp     rax, [rip+tlen]
    jae     1f
    lea     rdi, [rax+1]
    mov     rsi, [rip+want_col]
    call    pos_at_col
    mov     [rip+cur], rax
1:  ret

page_lines:                             # -> eax = lines in a page (at least 1)
    mov     rax, [rip+L_ed_h]
    xor     edx, edx
    mov     ecx, [rip+ed_lh]
    div     rcx
    dec     eax
    cmp     eax, 1
    jge     1f
    mov     eax, 1
1:  ret

# edit_key(edi=key) - a movement or edit (K_*), or K_CHAR | code point
edit_key:
    push    rbx
    push    r12
    push    r13
    mov     ebx, edi
    mov     qword ptr [rip+edit_kind], 0
    xor     r12d, r12d                  # 1: the selection stays
    test    ebx, K_CHAR
    jnz     .Lk_char
    test    ebx, K_SHIFT
    jz      1f
    and     ebx, ~K_SHIFT
    mov     r12d, 1
    cmp     qword ptr [rip+sel_anchor], -1
    jne     .Lk_go
    mov     rax, [rip+cur]
    mov     [rip+sel_anchor], rax
    jmp     .Lk_go
1:  cmp     ebx, K_RIGHT                # Left / Right with a selection: to its edge
    ja      .Lk_go
    call    get_sel
    cmp     rax, -1
    je      .Lk_go
    cmp     ebx, K_RIGHT
    jne     2f
    mov     rax, rdx
2:  mov     [rip+cur], rax
    jmp     .Lk_done
.Lk_go:
    cmp     ebx, K_LEFT
    je      .Lk_left
    cmp     ebx, K_RIGHT
    je      .Lk_right
    cmp     ebx, K_UP
    je      .Lk_up
    cmp     ebx, K_DOWN
    je      .Lk_down
    cmp     ebx, K_PGUP
    je      .Lk_pgup
    cmp     ebx, K_PGDN
    je      .Lk_pgdn
    cmp     ebx, K_HOME
    je      .Lk_home
    cmp     ebx, K_END
    je      .Lk_end
    cmp     ebx, K_WLEFT
    je      .Lk_wleft
    cmp     ebx, K_WRIGHT
    je      .Lk_wright
    cmp     ebx, K_DOCHOME
    je      .Lk_dochome
    cmp     ebx, K_DOCEND
    je      .Lk_docend
    cmp     ebx, K_DEL
    je      .Lk_del
    cmp     ebx, K_BS
    je      .Lk_bs
    cmp     ebx, K_WBS
    je      .Lk_wbs
    cmp     ebx, K_WDEL
    je      .Lk_wdel
    cmp     ebx, K_ENTER
    je      .Lk_enter
    cmp     ebx, K_TAB
    je      .Lk_tab
    jmp     .Lk_done
.Lk_left:
    mov     rdi, [rip+cur]
    call    prev_char
    mov     [rip+cur], rax
    jmp     .Lk_done
.Lk_right:
    mov     rdi, [rip+cur]
    call    next_char
    mov     [rip+cur], rax
    jmp     .Lk_done
.Lk_up:
    call    move_up
    jmp     .Lk_done
.Lk_down:
    call    move_down
    jmp     .Lk_done
.Lk_pgup:
    call    page_lines
    mov     r13d, eax
    imul    eax, [rip+ed_lh]            # the view moves along
    sub     [rip+scroll_y], rax
1:  call    move_up
    dec     r13d
    jnz     1b
    jmp     .Lk_done
.Lk_pgdn:
    call    page_lines
    mov     r13d, eax
    imul    eax, [rip+ed_lh]
    add     [rip+scroll_y], rax
1:  call    move_down
    dec     r13d
    jnz     1b
    jmp     .Lk_done
.Lk_home:                               # the indentation first, then column 1
    mov     rdi, [rip+cur]
    call    line_start
    mov     rcx, rax
    lea     rdx, [rip+text]
1:  cmp     rcx, [rip+tlen]
    jae     2f
    movzx   r8d, byte ptr [rdx+rcx]
    cmp     r8d, ' '
    je      3f
    cmp     r8d, 9
    jne     2f
3:  inc     rcx
    jmp     1b
2:  cmp     rcx, [rip+cur]
    jne     4f
    mov     rcx, rax
4:  mov     [rip+cur], rcx
    jmp     .Lk_done
.Lk_end:
    mov     rdi, [rip+cur]
    call    line_end
    mov     [rip+cur], rax
    jmp     .Lk_done
.Lk_wleft:
    mov     rdi, [rip+cur]
    call    word_left
    mov     [rip+cur], rax
    jmp     .Lk_done
.Lk_wright:
    mov     rdi, [rip+cur]
    call    word_right
    mov     [rip+cur], rax
    jmp     .Lk_done
.Lk_dochome:
    mov     qword ptr [rip+cur], 0
    jmp     .Lk_done
.Lk_docend:
    mov     rax, [rip+tlen]
    mov     [rip+cur], rax
    jmp     .Lk_done
.Lk_del:
    call    delete_selection
    test    rax, rax
    jnz     .Lk_done
    mov     rdi, [rip+cur]
    cmp     rdi, [rip+tlen]
    jae     .Lk_done
    call    next_char
    mov     rsi, rax
    mov     rdi, [rip+cur]
    sub     rsi, rdi
    mov     qword ptr [rip+edit_kind], 3
    call    do_delete
    jmp     .Lk_done
.Lk_bs:
    call    delete_selection
    test    rax, rax
    jnz     .Lk_done
    mov     rdi, [rip+cur]
    test    rdi, rdi
    jz      .Lk_done
    call    prev_char
    mov     rdi, rax
    mov     rsi, [rip+cur]
    sub     rsi, rax
    mov     qword ptr [rip+edit_kind], 2
    call    do_delete
    jmp     .Lk_done
.Lk_wbs:
    call    delete_selection
    test    rax, rax
    jnz     .Lk_done
    mov     rdi, [rip+cur]
    call    word_left
    mov     rdi, rax
    mov     rsi, [rip+cur]
    sub     rsi, rax
    call    do_delete
    jmp     .Lk_done
.Lk_wdel:
    call    delete_selection
    test    rax, rax
    jnz     .Lk_done
    mov     rdi, [rip+cur]
    call    word_right
    mov     rsi, rax
    mov     rdi, [rip+cur]
    sub     rsi, rdi
    call    do_delete
    jmp     .Lk_done
.Lk_enter:                              # a new line, with this line's indentation
    call    delete_selection
    mov     rdi, [rip+cur]
    call    line_start
    lea     rsi, [rip+dirbuf]
    mov     byte ptr [rsi], 10
    mov     ecx, 1
    lea     rdx, [rip+text]
1:  cmp     rax, [rip+cur]
    jae     2f
    cmp     ecx, 256
    jae     2f
    movzx   r8d, byte ptr [rdx+rax]
    cmp     r8d, ' '
    je      3f
    cmp     r8d, 9
    jne     2f
3:  mov     [rsi+rcx], r8b
    inc     ecx
    inc     rax
    jmp     1b
2:  mov     rdi, [rip+cur]
    mov     edx, ecx
    call    do_insert
    jmp     .Lk_done
.Lk_tab:
    mov     ebx, 9 | K_CHAR
.Lk_char:
    call    delete_selection
    mov     edi, ebx
    and     edi, K_CHAR-1
    lea     rsi, [rip+chbuf]
    call    utf8_enc
    mov     qword ptr [rip+edit_kind], 1
    mov     rdi, [rip+cur]
    lea     rsi, [rip+chbuf]
    mov     edx, eax
    call    do_insert
.Lk_done:
    test    r12d, r12d
    jnz     1f
    mov     qword ptr [rip+sel_anchor], -1
1:  cmp     ebx, K_UP
    je      2f
    cmp     ebx, K_DOWN
    je      2f
    cmp     ebx, K_PGUP
    je      2f
    cmp     ebx, K_PGDN
    je      2f
    call    update_want_col
2:  mov     rax, [rip+edit_kind]
    mov     [rip+prev_edit_kind], rax
    mov     qword ptr [rip+follow], 1
    mov     dword ptr [rip+dirty], 1
    pop     r13
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  Commands
# =============================================================================
.section .rodata
.align 8
cmd_tab:
    .quad 0, c_new, c_open, c_save, c_saveas, c_quit, c_undo, c_redo
    .quad c_cut, c_copy, c_paste, c_delete, c_selall, c_find, c_next, c_prev
    .quad c_goto, c_zoomin, c_zoomout, c_zoom0, c_lnum, c_help, c_about
    .rept RECENT_N
    .quad c_recent
    .endr
    .quad c_rclear
.equ CMD_N, (. - cmd_tab) / 8
.text

# run_cmd(edi=command)
run_cmd:
    test    edi, edi
    jz      9f
    cmp     edi, CMD_N
    jae     9f
    push    rbx
    mov     qword ptr [rip+edit_kind], 0
    lea     rax, [rip+cmd_tab]
    call    [rax+rdi*8]
    mov     qword ptr [rip+prev_edit_kind], 0
    mov     dword ptr [rip+dirty], 1
    pop     rbx
9:  ret

c_new:
    call    ask_save
    test    eax, eax
    jz      9f
    call    doc_reset
    mov     qword ptr [rip+fname_len], 0
    mov     byte ptr [rip+fname], 0
    call    view_reset
    SETMSG  "New document"
9:  ret

view_reset:
    xor     eax, eax
    mov     [rip+scroll_y], rax
    mov     [rip+scroll_x], rax
    mov     qword ptr [rip+follow], 1
    ret

# set_fname_from_pbuf - the prompt's path (~ expanded) becomes the file name
set_fname_from_pbuf:
    call    expand_tilde
    lea     rsi, [rip+pbuf]
    lea     rdi, [rip+fname]
    mov     rcx, [rip+plen]
    cmp     rcx, FNAME_MAX-1
    jbe     1f
    mov     ecx, FNAME_MAX-1
1:  mov     [rip+fname_len], rcx
    rep     movsb
    mov     byte ptr [rdi], 0
    ret

c_open:
    call    ask_save
    test    eax, eax
    jz      9f
    push    qword ptr [rip+fname_len]   # (cancelled: the name stays)
    lea     rsi, [rip+fname]
    lea     rdi, [rip+pbuf]
    mov     ecx, FNAME_MAX
    cmp     rcx, PROMPT_MAX
    jbe     1f
    mov     ecx, PROMPT_MAX
1:  rep     movsb
    call    filedlg_run
    pop     rcx
    test    eax, eax
    jnz     2f
    mov     [rip+fname_len], rcx
    lea     rsi, [rip+pbuf]
    lea     rdi, [rip+fname]
    rep     movsb
    mov     byte ptr [rdi], 0
    jmp     9f
2:  call    doc_load
    call    view_reset
9:  ret

# c_recent(edi=CMD_RECENT + n) - open the nth recent file (run_cmd passes
#   the command on in edi); one that no longer opens leaves the list
c_recent:
    push    rbx
    lea     ebx, [rdi-CMD_RECENT]
    call    ask_save
    test    eax, eax
    jz      9f
    mov     edi, ebx
    call    recent_path
    test    rax, rax
    jz      9f
    lea     rdi, [rip+fname]
    xor     ecx, ecx
1:  mov     dl, [rax+rcx]
    mov     [rdi+rcx], dl
    test    dl, dl
    jz      2f
    inc     ecx
    jmp     1b
2:  mov     [rip+fname_len], rcx
    call    doc_load
    test    eax, eax
    jz      3f
    mov     edi, ebx
    call    recent_forget
    MSGADD  " \342\200\224 taken off the recent files"
3:  call    view_reset
9:  pop     rbx
    ret

c_rclear:
    call    recent_clear
    SETMSG  "Recent files cleared"
    ret

c_save:
    cmp     qword ptr [rip+fname_len], 0
    je      c_saveas
    jmp     doc_save

c_saveas:
    cmp     qword ptr [rip+fname_len], 0
    je      1f
    lea     rsi, [rip+fname]            # pre-filled with the current name
    lea     rdi, [rip+pbuf]
    mov     rcx, [rip+fname_len]
    mov     [rip+plen], rcx
    rep     movsb
    jmp     2f
1:  call    prefill_dir                 # or the folder and "untitled.txt"
    lea     rdi, [rip+s_untitled_txt]
    call    pbuf_add_cstr
2:  mov     edi, P_SAVEAS
    lea     rsi, [rip+l_saveas]
    call    prompt_run
    test    eax, eax
    jz      8f
    cmp     qword ptr [rip+plen], 0
    je      8f
    call    set_fname_from_pbuf
    jmp     doc_save
8:  SETMSG  "Not saved"
    ret

c_quit:
    call    ask_save
    test    eax, eax
    jz      9f
    mov     dword ptr [rip+quit_flag], 1
9:  ret

c_undo:
    call    undo_cmd
    mov     qword ptr [rip+follow], 1
    jmp     update_want_col
c_redo:
    call    redo_cmd
    mov     qword ptr [rip+follow], 1
    jmp     update_want_col

# the selection, or the cursor's whole line -> rax = start, rdx = end;
#   rcx = 1 for a line
sel_or_line:
    call    get_sel
    xor     ecx, ecx
    cmp     rax, -1
    jne     9f
    mov     rdi, [rip+cur]
    call    line_start
    push    rax
    mov     rdi, [rip+cur]
    call    line_end
    mov     rdx, rax
    pop     rax
    cmp     rdx, [rip+tlen]
    jae     1f
    inc     rdx                         # (with its line break)
1:  mov     ecx, 1
9:  ret

c_copy:
    push    rbx
    call    sel_or_line
    mov     [rip+clip_line], rcx
    mov     rbx, rcx
    lea     rdi, [rip+text]
    add     rdi, rax
    mov     esi, edx
    sub     esi, eax
    call    clip_copy
    test    rbx, rbx
    jz      1f
    SETMSG  "Line copied"
1:  pop     rbx
    ret

c_cut:
    push    rbx
    push    r12
    call    sel_or_line
    mov     [rip+clip_line], rcx
    mov     rbx, rax
    mov     r12, rdx
    cmp     rbx, r12
    je      9f
    lea     rdi, [rip+text]
    add     rdi, rbx
    mov     esi, r12d
    sub     esi, ebx
    call    clip_copy
    mov     qword ptr [rip+sel_anchor], -1
    mov     rdi, rbx
    mov     rsi, r12
    sub     rsi, rbx
    call    do_delete
    mov     qword ptr [rip+follow], 1
    call    update_want_col
9:  pop     r12
    pop     rbx
    ret

c_paste:
    push    rbx
    lea     rdi, [rip+pastebuf]
    mov     esi, PASTE_CAP
    call    clip_paste
    test    eax, eax
    jnz     1f
    SETMSG  "The clipboard is empty"
    jmp     9f
1:  mov     ebx, eax                    # CRLF and CR -> LF
    lea     rsi, [rip+pastebuf]
    xor     ecx, ecx                    # from
    xor     edx, edx                    # to
2:  cmp     ecx, ebx
    jae     4f
    mov     al, [rsi+rcx]
    inc     ecx
    cmp     al, 13
    jne     3f
    mov     al, 10
    cmp     ecx, ebx
    jae     3f
    cmp     byte ptr [rsi+rcx], 10
    jne     3f
    inc     ecx
3:  mov     [rsi+rdx], al
    inc     edx
    jmp     2b
4:  mov     ebx, edx
    call    delete_selection
    cmp     qword ptr [rip+clip_line], 0  # our own copied lines: above this line
    je      5f
    cmp     dword ptr [rip+clip_own], 0
    je      5f
    mov     rdi, [rip+cur]
    call    line_start
    mov     [rip+cur], rax
5:  mov     rdi, [rip+cur]
    lea     rsi, [rip+pastebuf]
    mov     edx, ebx
    call    do_insert
    mov     qword ptr [rip+follow], 1
    call    update_want_col
9:  pop     rbx
    ret

c_delete:
    call    delete_selection
    test    rax, rax
    jnz     1f
    mov     edi, K_DEL
    jmp     edit_key
1:  mov     qword ptr [rip+follow], 1
    ret

c_selall:
    mov     qword ptr [rip+sel_anchor], 0
    mov     rax, [rip+tlen]
    mov     [rip+cur], rax
    ret

c_find:
    mov     edi, P_FIND
    lea     rsi, [rip+l_find]
    jmp     prompt_run

c_next:
    cmp     qword ptr [rip+slen], 0
    je      c_find
    mov     edi, 1
    jmp     find_step
c_prev:
    cmp     qword ptr [rip+slen], 0
    je      c_find
    mov     edi, -1
    jmp     find_step

# find_step(edi=1 next / -1 previous) - select the next match of sbuf
find_step:
    push    rbx
    push    r12
    mov     r12d, edi
    call    get_sel                     # from the selection (a match), or the cursor
    cmp     rax, -1
    jne     1f
    mov     rax, [rip+cur]
    test    r12d, r12d
    jns     2f
    dec     rax
    jmp     2f
1:  add     rax, r12                    # (start +/- 1)
2:  mov     rbx, rax
    mov     rdi, rax
    mov     esi, r12d
    call    find_from
    cmp     rax, -1
    jne     3f
    mov     qword ptr [rip+find_fail], 1
    ERRMSG  "Not found: "
    lea     rsi, [rip+sbuf]
    mov     rdx, [rip+slen]
    call    msg_add
    jmp     9f
3:  mov     qword ptr [rip+find_fail], 0
    mov     [rip+sel_anchor], rax
    mov     rcx, rax
    add     rcx, [rip+slen]
    mov     [rip+cur], rcx
    test    r12d, r12d                  # wrapped around?
    js      4f
    cmp     rax, rbx
    jge     5f
    jmp     41f
4:  cmp     rax, rbx
    jle     5f
41: SETMSG  "Search wrapped around"
5:  mov     qword ptr [rip+follow], 1
    call    update_want_col
9:  pop     r12
    pop     rbx
    ret

c_goto:
    mov     qword ptr [rip+plen], 0
    mov     edi, P_GOTO
    lea     rsi, [rip+l_goto]
    call    prompt_run
    test    eax, eax
    jz      9f
    xor     eax, eax                    # the number (other characters skipped)
    xor     ecx, ecx
    lea     rsi, [rip+pbuf]
1:  cmp     rcx, [rip+plen]
    jae     2f
    movzx   edx, byte ptr [rsi+rcx]
    inc     rcx
    sub     edx, '0'
    cmp     edx, 9
    ja      1b
    cmp     rax, 100000000
    jae     1b
    imul    rax, rax, 10
    add     rax, rdx
    jmp     1b
2:  test    rax, rax
    jz      9f
    dec     rax
    push    rax
    mov     rdi, rax
    call    line_offset
    mov     [rip+cur], rax
    mov     qword ptr [rip+sel_anchor], -1
    call    update_want_col
    pop     rax                         # centred
    imul    eax, [rip+ed_lh]
    mov     rcx, [rip+L_ed_h]
    shr     rcx, 1
    sub     rax, rcx
    mov     [rip+scroll_y], rax
    mov     qword ptr [rip+follow], 1
9:  ret

# zoom_to(edi=px) - the document's font size; the top line stays on top
zoom_to:
    push    rbx
    cmp     edi, 6
    jge     1f
    mov     edi, 6
1:  cmp     edi, 96
    jle     2f
    mov     edi, 96
2:  mov     ebx, edi
    mov     rax, [rip+scroll_y]
    xor     edx, edx
    mov     ecx, [rip+ed_lh]
    div     rcx
    push    rax
    mov     [rip+ed_px], ebx
    call    fonts_resize
    pop     rax
    imul    eax, [rip+ed_lh]
    mov     [rip+scroll_y], rax
    SETMSG  "Zoom "
    mov     eax, [rip+ed_px]
    imul    eax, eax, 100
    xor     edx, edx
    div     dword ptr [rip+base_px]
    mov     edi, eax
    call    msg_num
    MSGADD  "%"
    pop     rbx
    ret

c_zoomin:
    mov     edi, [rip+ed_px]
    mov     eax, edi                    # +1 px, or +10 % when that is more
    xor     edx, edx
    mov     ecx, 10
    div     ecx
    cmp     eax, 1
    jge     1f
    mov     eax, 1
1:  add     edi, eax
    jmp     zoom_to
c_zoomout:
    mov     edi, [rip+ed_px]
    mov     eax, edi
    xor     edx, edx
    mov     ecx, 10
    div     ecx
    cmp     eax, 1
    jge     1f
    mov     eax, 1
1:  sub     edi, eax
    jmp     zoom_to
c_zoom0:
    mov     edi, [rip+base_px]
    jmp     zoom_to

c_lnum:
    xor     qword ptr [rip+show_lnum], 1
    ret

c_help:
    mov     edi, D_HELP
    jmp     dialog_run
c_about:
    mov     edi, D_ABOUT
    jmp     dialog_run

# =============================================================================
#  Menus
# =============================================================================
# menu_find(edi=character) -> rax = the menu with that first letter, or -1
menu_find:
    or      edi, 0x20
    xor     eax, eax
1:  cmp     eax, NMENUS
    jae     8f
    mov     rcx, rax
    shl     rcx, 5
    lea     rdx, [rip+menu_tab]
    mov     rcx, [rdx+rcx]
    movzx   ecx, byte ptr [rcx]
    or      ecx, 0x20
    cmp     ecx, edi
    je      9f
    inc     eax
    jmp     1b
8:  mov     rax, -1
9:  ret

# open_menu(rdi=menu, esi=1 for the context menu at the pointer)
open_menu:
    mov     [rip+menu_open], rdi
    mov     qword ptr [rip+menu_sel], -1
    mov     [rip+ctx_menu], rsi
    test    esi, esi
    jz      1f
    mov     rax, [rip+mx]
    mov     [rip+ctx_x], rax
    mov     rax, [rip+my]
    mov     [rip+ctx_y], rax
1:  mov     dword ptr [rip+dirty], 1
    call    set_cursor_default
    jmp     layout

close_menu:
    mov     qword ptr [rip+menu_open], -1
    mov     qword ptr [rip+ctx_menu], 0
    mov     dword ptr [rip+dirty], 1
    ret

cur_items:                              # -> rax = the open menu's items, rdx = count
    mov     rax, [rip+menu_open]
    shl     rax, 5
    lea     rcx, [rip+menu_tab]
    mov     rdx, [rcx+rax+24]
    mov     rax, [rcx+rax+16]
    ret

# menu_move(edi=+1 / -1) - the next item that is not a separator
menu_move:
    mov     r8d, edi
    call    cur_items
    mov     r9, rax
    mov     rcx, [rip+menu_sel]
    mov     r10, rdx                    # (at most every item once)
1:  movsxd  r11, r8d
    add     rcx, r11
    jns     2f
    lea     rcx, [rdx-1]
2:  cmp     rcx, rdx
    jb      3f
    xor     ecx, ecx
3:  mov     rax, rcx
    shl     rax, 5
    cmp     qword ptr [r9+rax], 0
    jne     4f
    dec     r10
    jnz     1b
4:  mov     [rip+menu_sel], rcx
    mov     dword ptr [rip+dirty], 1
    ret

# menu_exec(rdi=item index) - close the menu and run the item's command
menu_exec:
    call    cur_items
    shl     rdi, 5
    mov     edi, [rax+rdi+16]
    push    rdi
    call    close_menu
    pop     rdi
    jmp     run_cmd

# menu_key(edi=evdev, esi=symbol, edx=mods, ecx=layout code)
menu_key:
    push    rbx
    push    r12
    push    r13
    mov     ebx, edi
    mov     r12d, esi
    mov     r13d, edx
    cmp     ebx, KEY_ESC
    je      .Lmk_close
    cmp     ebx, EK_F10
    je      .Lmk_close
    cmp     ebx, EK_LEFT
    jne     1f
    cmp     qword ptr [rip+ctx_menu], 0
    jne     .Lmk_ret
    mov     rax, [rip+menu_open]
    add     rax, NMENUS-1
    jmp     2f
1:  cmp     ebx, EK_RIGHT
    jne     3f
    cmp     qword ptr [rip+ctx_menu], 0
    jne     .Lmk_ret
    mov     rax, [rip+menu_open]
    inc     rax
2:  xor     edx, edx
    mov     ecx, NMENUS
    div     rcx
    mov     rdi, rdx
    xor     esi, esi
    call    open_menu
    mov     edi, 1
    call    menu_move
    jmp     .Lmk_ret
3:  cmp     ebx, EK_UP
    jne     4f
    mov     rdi, -1
    call    menu_move
    jmp     .Lmk_ret
4:  cmp     ebx, EK_DOWN
    jne     5f
    mov     edi, 1
    call    menu_move
    jmp     .Lmk_ret
5:  cmp     ebx, EK_ENTER
    je      51f
    cmp     ebx, EK_KPENTER
    jne     6f
51: mov     rdi, [rip+menu_sel]
    test    rdi, rdi
    js      .Lmk_ret
    call    menu_exec
    jmp     .Lmk_ret
6:  test    r13d, MOD_ALT               # Alt+letter: another menu
    jz      7f
    mov     edi, r12d
    call    menu_find
    cmp     rax, -1
    je      .Lmk_ret
    mov     rdi, rax
    xor     esi, esi
    call    open_menu
    mov     edi, 1
    call    menu_move
    jmp     .Lmk_ret
7:  cmp     r12d, 0x20                  # a letter: the item it underlines
    jb      .Lmk_ret
    cmp     r12d, 0x7f
    jae     .Lmk_ret
    or      r12d, 0x20
    call    cur_items
    xor     ecx, ecx
8:  cmp     rcx, rdx
    jae     .Lmk_ret
    mov     r8, rcx
    shl     r8, 5
    add     r8, rax
    mov     r9, [r8]
    test    r9, r9
    jz      81f
    mov     r10d, [r8+20]
    movzx   r10d, byte ptr [r9+r10]
    or      r10d, 0x20
    cmp     r10d, r12d
    jne     81f
    mov     rdi, rcx
    call    menu_exec
    jmp     .Lmk_ret
81: inc     rcx
    jmp     8b
.Lmk_close:
    call    close_menu
.Lmk_ret:
    pop     r13
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  Modal loops: the prompt bar and dialogs
# =============================================================================
# prompt_run(edi=mode, rsi=label) -> eax = 1 when confirmed with Enter
prompt_run:
    push    rbx
    mov     [rip+prompt_mode], rdi
    mov     [rip+prompt_label], rsi
    mov     qword ptr [rip+prompt_done], 0
    mov     qword ptr [rip+prompt_result], 0
    mov     qword ptr [rip+find_fail], 0
    inc     qword ptr [rip+modal]
    cmp     edi, P_FIND
    jne     2f
    call    get_sel                     # find: from the selection's start
    cmp     rax, -1
    jne     1f
    mov     rax, [rip+cur]
1:  mov     [rip+find_origin], rax
    call    find_prefill
    call    prompt_changed
2:  mov     dword ptr [rip+dirty], 1
3:  cmp     qword ptr [rip+prompt_done], 0
    jne     4f
    cmp     dword ptr [rip+quit_flag], 0
    jne     4f
    call    pump
    jmp     3b
4:  mov     qword ptr [rip+prompt_mode], 0
    dec     qword ptr [rip+modal]
    mov     dword ptr [rip+dirty], 1
    mov     rax, [rip+prompt_result]
    pop     rbx
    ret

# find_prefill - the selected text (one short line), else the last search
find_prefill:
    call    get_sel
    cmp     rax, -1
    je      3f
    mov     rcx, rdx
    sub     rcx, rax
    cmp     rcx, 200
    ja      3f
    lea     rsi, [rip+text]
    add     rsi, rax
    xor     edx, edx
1:  cmp     rdx, rcx                    # no line break in it
    jae     2f
    cmp     byte ptr [rsi+rdx], 10
    je      3f
    inc     rdx
    jmp     1b
2:  lea     rdi, [rip+pbuf]
    mov     [rip+plen], rcx
    rep     movsb
    ret
3:  lea     rsi, [rip+sbuf]
    lea     rdi, [rip+pbuf]
    mov     rcx, [rip+slen]
    mov     [rip+plen], rcx
    rep     movsb
    ret

# prompt_changed - find as you type: from where the search began
prompt_changed:
    cmp     qword ptr [rip+prompt_mode], P_FIND
    jne     9f
    lea     rsi, [rip+pbuf]
    lea     rdi, [rip+sbuf]
    mov     rcx, [rip+plen]
    mov     [rip+slen], rcx
    rep     movsb
    mov     qword ptr [rip+find_fail], 0
    cmp     qword ptr [rip+plen], 0
    jne     1f
    mov     rax, [rip+find_origin]      # nothing typed: back where it began
    mov     [rip+cur], rax
    mov     qword ptr [rip+sel_anchor], -1
    jmp     8f
1:  mov     rdi, [rip+find_origin]
    mov     esi, 1
    call    find_from
    cmp     rax, -1
    jne     2f
    mov     qword ptr [rip+find_fail], 1
    jmp     8f
2:  mov     [rip+sel_anchor], rax
    add     rax, [rip+slen]
    mov     [rip+cur], rax
8:  mov     qword ptr [rip+follow], 1
    call    update_want_col
    mov     dword ptr [rip+dirty], 1
9:  ret

pbuf_add:                               # (rsi=bytes, rdx=count) append to the prompt
    mov     rax, [rip+plen]
    mov     rcx, PROMPT_MAX-2
    sub     rcx, rax
    jbe     9f
    cmp     rdx, rcx
    jbe     1f
    mov     rdx, rcx
1:  lea     rdi, [rip+pbuf]
    add     rdi, rax
    mov     rcx, rdx
    rep     movsb
    add     [rip+plen], rdx
9:  ret
pbuf_add_cstr:                          # (rdi=asciz)
    push    rdi
    call    str_len
    mov     rdx, rax
    pop     rsi
    jmp     pbuf_add

# prompt_key(edi=evdev, esi=symbol, edx=mods, ecx=layout code)
prompt_key:
    push    rbx
    push    r12
    push    r13
    push    r14
    mov     ebx, edi
    mov     r12d, esi
    mov     r13d, edx
    mov     r14d, ecx
    cmp     ebx, KEY_ESC
    jne     1f
    mov     qword ptr [rip+prompt_result], 0
    mov     qword ptr [rip+prompt_done], 1
    jmp     .Lpk_ret
1:  cmp     ebx, EK_ENTER
    je      2f
    cmp     ebx, EK_KPENTER
    je      2f
    cmp     ebx, EK_F3
    jne     3f
2:  cmp     qword ptr [rip+prompt_mode], P_FIND
    je      21f
    mov     qword ptr [rip+prompt_result], 1
    mov     qword ptr [rip+prompt_done], 1
    jmp     .Lpk_ret
21: cmp     qword ptr [rip+plen], 0     # find: Enter goes to the next match
    je      .Lpk_ret
    mov     edi, 1
    test    r13d, MOD_SHIFT
    jz      22f
    mov     edi, -1
22: call    find_step
    mov     qword ptr [rip+msg_len], 0
    jmp     .Lpk_ret
3:  cmp     ebx, EK_BACKSPACE
    jne     4f
    test    r13d, MOD_CTRL              # Ctrl: all of it
    jz      31f
    mov     qword ptr [rip+plen], 0
    jmp     .Lpk_changed
31: mov     rax, [rip+plen]             # one character
    lea     rcx, [rip+pbuf]
32: test    rax, rax
    jz      33f
    dec     rax
    movzx   edx, byte ptr [rcx+rax]
    and     edx, 0xC0
    cmp     edx, 0x80
    je      32b
33: mov     [rip+plen], rax
    jmp     .Lpk_changed
4:  cmp     ebx, EK_TAB
    jne     5f
    cmp     qword ptr [rip+prompt_mode], P_OPEN
    jb      .Lpk_ret
    call    complete_path
    jmp     .Lpk_redraw
5:  test    r13d, MOD_CTRL
    jz      6f
    cmp     r14d, 47                    # Ctrl+V: paste (its first line)
    jne     .Lpk_ret
    lea     rdi, [rip+pastebuf]
    mov     esi, 4096
    call    clip_paste
    lea     rsi, [rip+pastebuf]
    xor     edx, edx
51: cmp     edx, eax
    jae     52f
    cmp     byte ptr [rsi+rdx], 10
    je      52f
    cmp     byte ptr [rsi+rdx], 13
    je      52f
    inc     edx
    jmp     51b
52: call    pbuf_add
    jmp     .Lpk_changed
6:  test    r13d, MOD_ALT
    jnz     .Lpk_ret
    mov     esi, r12d
    call    typed_char
    test    eax, eax
    jz      .Lpk_ret
    mov     edi, eax
    lea     rsi, [rip+chbuf]
    call    utf8_enc
    lea     rsi, [rip+chbuf]
    mov     edx, eax
    call    pbuf_add
.Lpk_changed:
    call    prompt_changed
.Lpk_redraw:
    mov     dword ptr [rip+dirty], 1
.Lpk_ret:
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# dialog_run(edi=kind) -> eax = the button chosen (Esc: the last one)
dialog_run:
    mov     [rip+dlg_kind], rdi
    mov     qword ptr [rip+dlg_focus], 0
    mov     qword ptr [rip+dlg_result], -1
    call    close_menu
    inc     qword ptr [rip+modal]
    call    set_cursor_default
1:  cmp     qword ptr [rip+dlg_result], -1
    jne     2f
    cmp     dword ptr [rip+quit_flag], 0
    jne     2f
    call    pump
    jmp     1b
2:  mov     qword ptr [rip+dlg_kind], 0
    dec     qword ptr [rip+modal]
    mov     dword ptr [rip+dirty], 1
    mov     rax, [rip+dlg_result]
    ret

# dlg_key(edi=evdev, esi=symbol, edx=mods, ecx=layout code)
dlg_key:
    mov     rax, [rip+dlg_nb]
    test    rax, rax
    jnz     0f
    mov     eax, 1
0:  cmp     edi, KEY_ESC                # Esc: the last button (Cancel / OK)
    jne     1f
    dec     rax
    mov     [rip+dlg_result], rax
    ret
1:  cmp     edi, EK_ENTER
    je      2f
    cmp     edi, EK_KPENTER
    je      2f
    cmp     edi, KEY_SPACE
    jne     3f
2:  mov     rax, [rip+dlg_focus]
    mov     [rip+dlg_result], rax
    ret
3:  cmp     edi, EK_LEFT                # move the focus
    je      31f
    cmp     edi, EK_TAB
    jne     4f
    test    edx, MOD_SHIFT
    jz      32f
31: mov     rcx, [rip+dlg_focus]
    add     rcx, rax
    dec     rcx
    jmp     33f
4:  cmp     edi, EK_RIGHT
    jne     5f
32: mov     rcx, [rip+dlg_focus]
    inc     rcx
33: xchg    rax, rcx
    xor     edx, edx
    div     rcx
    mov     [rip+dlg_focus], rdx
    mov     dword ptr [rip+dirty], 1
    ret
5:  cmp     qword ptr [rip+dlg_kind], D_ASK  # Save / Don't save / Cancel by letter
    jne     9f
    or      esi, 0x20
    xor     eax, eax
    cmp     esi, 's'
    je      6f
    cmp     esi, 'y'
    je      6f
    inc     eax
    cmp     esi, 'd'
    je      6f
    cmp     esi, 'n'
    je      6f
    inc     eax
    cmp     esi, 'c'
    jne     9f
6:  mov     [rip+dlg_result], rax
9:  ret

# ask_save -> eax = 1 to go on (saved, or the changes may go), 0 to stop
ask_save:
    cmp     qword ptr [rip+dirty_doc], 0
    je      8f
    mov     edi, D_ASK
    call    dialog_run
    cmp     rax, 1                      # Don't Save
    je      8f
    test    rax, rax
    jnz     9f                          # Cancel
    call    c_save                      # Save (may ask for a name)
    cmp     qword ptr [rip+dirty_doc], 0
    jne     9f
8:  mov     eax, 1
    ret
9:  xor     eax, eax
    ret

# =============================================================================
#  Paths: ~, the starting folder, Tab completion
# =============================================================================
expand_tilde:                           # pbuf: "~" or "~/..." -> $HOME...
    lea     rdi, [rip+pbuf]             # (C:\x -> /C:/x on Windows)
    lea     rsi, [rip+plen]
    mov     edx, PROMPT_MAX
    call    plat_path_in
    cmp     qword ptr [rip+plen], 0
    je      9f
    cmp     byte ptr [rip+pbuf], '~'
    jne     9f
    cmp     qword ptr [rip+plen], 1
    je      1f
    cmp     byte ptr [rip+pbuf+1], '/'
    jne     9f
1:  push    rbx
    lea     rdi, [rip+s_home]
    call    getenv
    test    rax, rax
    jz      8f
    mov     rbx, rax
    mov     rdi, rax
    call    str_len                     # room: shift the rest right
    mov     rcx, [rip+plen]
    lea     rdx, [rcx+rax-1]
    cmp     rdx, PROMPT_MAX-2
    ja      8f
    push    rax
    lea     rsi, [rip+pbuf+1]
    lea     rdi, [rip+pbuf]
    add     rdi, rax
    lea     rdx, [rcx-1]
    call    memmove
    pop     rcx
    lea     rax, [rcx-1]
    add     [rip+plen], rax
    lea     rdi, [rip+pbuf]
    mov     rsi, rbx
    rep     movsb
8:  pop     rbx
9:  ret

# prefill_dir - pbuf = the current file's folder, or the working folder, + '/'
prefill_dir:
    mov     qword ptr [rip+plen], 0
    mov     rcx, [rip+fname_len]
    lea     rsi, [rip+fname]
1:  test    rcx, rcx                    # the file's folder (up to its last '/')
    jz      2f
    cmp     byte ptr [rsi+rcx-1], '/'
    je      3f
    dec     rcx
    jmp     1b
3:  lea     rdi, [rip+pbuf]
    mov     [rip+plen], rcx
    rep     movsb
    ret
2:  mov     eax, SYS_GETCWD
    lea     rdi, [rip+pbuf]
    mov     esi, PROMPT_MAX-64
    call    plat_sys
    test    rax, rax
    jle     9f
    dec     rax                         # (without its 0)
    mov     [rip+plen], rax
    cmp     rax, 1                      # "/" stays "/"
    je      9f
    lea     rcx, [rip+pbuf]
    mov     byte ptr [rcx+rax], '/'
    inc     qword ptr [rip+plen]
9:  ret

# complete_path - Tab: complete the file name being typed in the folder
complete_path:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 24                     # [rsp] matches, [rsp+8] the only one is a folder
    call    expand_tilde
    mov     rcx, [rip+plen]             # the name starts after the last '/'
    lea     rsi, [rip+pbuf]
1:  test    rcx, rcx
    jz      2f
    cmp     byte ptr [rsi+rcx-1], '/'
    je      2f
    dec     rcx
    jmp     1b
2:  mov     r12, rcx                    # r12 = where the name starts
    lea     rdi, [rip+lcp]              # the folder: what is before it, or "."
    test    rcx, rcx
    jnz     3f
    mov     word ptr [rdi], '.'
    jmp     4f
3:  rep     movsb
    mov     byte ptr [rdi], 0
4:  mov     eax, 2                      # open(folder, O_RDONLY|O_DIRECTORY|O_CLOEXEC)
    lea     rdi, [rip+lcp]
    mov     esi, 0x90000
    xor     edx, edx
    call    plat_sys
    test    rax, rax
    js      .Lcp_none
    mov     rbx, rax                    # fd
    mov     qword ptr [rsp], 0
    mov     qword ptr [rsp+8], 0
    xor     r15d, r15d                  # r15 = the common prefix's length
.Lcp_read:
    mov     eax, SYS_GETDENTS64
    mov     rdi, rbx
    lea     rsi, [rip+dirbuf]
    mov     edx, 4096
    call    plat_sys
    test    rax, rax
    jle     .Lcp_done
    lea     r13, [rip+dirbuf]
    lea     r14, [r13+rax]              # end
.Lcp_ent:
    cmp     r13, r14
    jae     .Lcp_read
    lea     rbp, [r13+19]               # its name
    cmp     byte ptr [rbp], '.'         # hidden only when asked for (".x")
    jne     5f
    mov     rax, [rip+plen]
    cmp     rax, r12
    je      .Lcp_next
    lea     rcx, [rip+pbuf]
    cmp     byte ptr [rcx+r12], '.'
    jne     .Lcp_next
    cmp     byte ptr [rbp+1], 0         # "." and ".." never
    je      .Lcp_next
    cmp     word ptr [rbp+1], '.'
    je      .Lcp_next
5:  mov     rcx, [rip+plen]             # starts with what was typed?
    sub     rcx, r12
    lea     rsi, [rip+pbuf]
    add     rsi, r12
    xor     edx, edx
6:  cmp     rdx, rcx
    jae     7f
    mov     al, [rsi+rdx]
    cmp     al, [rbp+rdx]
    jne     .Lcp_next
    inc     rdx
    jmp     6b
7:  inc     qword ptr [rsp]
    cmp     qword ptr [rsp], 1
    jne     8f
    lea     rdi, [rip+lcp]              # the first: the prefix is all of it
    xor     ecx, ecx
71: mov     al, [rbp+rcx]
    mov     [rdi+rcx], al
    test    al, al
    jz      72f
    inc     ecx
    cmp     ecx, 1000
    jb      71b
72: mov     r15, rcx
    movzx   eax, byte ptr [r13+18]      # d_type: 4 a folder, 0 unknown
    mov     [rsp+8], rax
    jmp     .Lcp_next
8:  lea     rdi, [rip+lcp]              # more: the prefix they share
    xor     ecx, ecx
81: cmp     rcx, r15
    jae     82f
    mov     al, [rdi+rcx]
    cmp     al, [rbp+rcx]
    jne     82f
    inc     rcx
    jmp     81b
82: mov     r15, rcx
.Lcp_next:
    movzx   eax, word ptr [r13+16]      # d_reclen
    add     r13, rax
    jmp     .Lcp_ent
.Lcp_done:
    mov     eax, SYS_CLOSE
    mov     rdi, rbx
    call    plat_sys
    cmp     qword ptr [rsp], 0
    je      .Lcp_none
    mov     [rip+plen], r12             # the name becomes the shared prefix
    lea     rsi, [rip+lcp]
    mov     rdx, r15
    call    pbuf_add
    cmp     qword ptr [rsp], 1
    jne     .Lcp_many
    mov     rax, [rsp+8]                # one match: a folder gets its '/'
    cmp     rax, 4
    je      9f
    test    rax, rax
    jnz     .Lcp_ret
    lea     rax, [rip+pbuf]             # (type unknown: ask stat)
    mov     rcx, [rip+plen]
    mov     byte ptr [rax+rcx], 0
    mov     eax, SYS_STAT
    lea     rdi, [rip+pbuf]
    lea     rsi, [rip+statb]
    call    plat_sys
    test    rax, rax
    jnz     .Lcp_ret
    mov     eax, [rip+statb+24]         # st_mode
    and     eax, 0xF000
    cmp     eax, 0x4000
    jne     .Lcp_ret
9:  LSTR    "/"
    call    pbuf_add
    jmp     .Lcp_ret
.Lcp_many:
    mov     rdi, [rsp]
    SETMSG  ""
    mov     rdi, [rsp]
    call    msg_num
    MSGADD  " matches"
    jmp     .Lcp_ret
.Lcp_none:
    ERRMSG  "No file starts with that"
.Lcp_ret:
    add     rsp, 24
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

# =============================================================================
#  Mouse
# =============================================================================
set_cursor_default:
    mov     edi, SHAPE_DEFAULT
    jmp     set_cursor

in_doc:                                 # -> eax = 1 when the pointer is over the text
    xor     eax, eax
    mov     rcx, [rip+mx]
    cmp     rcx, [rip+L_ed_w]
    jge     9f
    mov     rcx, [rip+my]
    cmp     rcx, [rip+L_ed_y]
    jl      9f
    mov     rdx, [rip+L_ed_y]
    add     rdx, [rip+L_ed_h]
    cmp     rcx, rdx
    jge     9f
    mov     eax, 1
9:  ret

in_thumb:                               # -> eax = 1 over the scrollbar's thumb
    xor     eax, eax
    cmp     qword ptr [rip+L_th_h], 0
    je      9f
    mov     rcx, [rip+mx]
    cmp     rcx, [rip+L_ed_w]
    jl      9f
    mov     rcx, [rip+my]
    cmp     rcx, [rip+L_th_y]
    jl      9f
    mov     rdx, [rip+L_th_y]
    add     rdx, [rip+L_th_h]
    cmp     rcx, rdx
    jge     9f
    mov     eax, 1
9:  ret

# unit_at(rdi=pos) -> rax, rdx = the word or line there (as drag_unit says)
unit_at:
    cmp     qword ptr [rip+drag_unit], 1
    jne     1f
    jmp     word_bounds
1:  push    rbx
    mov     rbx, rdi
    call    line_start
    push    rax
    mov     rdi, rbx
    call    line_end
    mov     rdx, rax
    pop     rax
    cmp     rdx, [rip+tlen]
    jae     2f
    inc     rdx                         # (with its line break)
2:  pop     rbx
    ret

# drag_to(rdi=pos) - the selection follows the pointer: by character, or by
#   whole words or lines from the first one [drag_s, drag_e)
drag_to:
    push    rbx
    mov     rbx, rdi
    cmp     qword ptr [rip+drag_unit], 0
    jne     1f
    mov     [rip+cur], rbx
    jmp     9f
1:  call    unit_at
    cmp     rbx, [rip+drag_s]           # before the first unit: backwards
    jae     4f
    mov     rcx, [rip+drag_e]
    mov     [rip+sel_anchor], rcx
    mov     [rip+cur], rax
    jmp     9f
4:  mov     rcx, [rip+drag_s]
    cmp     rdx, [rip+drag_e]
    jae     5f
    mov     rdx, [rip+drag_e]
5:  mov     [rip+sel_anchor], rcx
    mov     [rip+cur], rdx
9:  call    update_want_col
    mov     qword ptr [rip+follow], 1
    mov     dword ptr [rip+dirty], 1
    pop     rbx
    ret

on_motion:                              # (edi=x, esi=y) logical
    push    rbx
    push    rsi
    call    to_px
    mov     [rip+mx], rax
    pop     rdi
    call    to_px
    mov     [rip+my], rax
    cmp     qword ptr [rip+dlg_kind], 0
    jne     .Lmo_default
    cmp     qword ptr [rip+fd_open], 0
    jne     .Lmo_default
    call    layout
    cmp     qword ptr [rip+menu_open], 0
    jl      3f
    mov     rdi, [rip+mx]               # a menu is open: hover its items
    mov     rsi, [rip+my]
    call    menu_item_at
    cmp     rax, -1
    je      1f
    cmp     rax, -2
    je      .Lmo_default
    cmp     rax, [rip+menu_sel]
    je      .Lmo_default
    mov     [rip+menu_sel], rax
    mov     dword ptr [rip+dirty], 1
    jmp     .Lmo_default
1:  cmp     qword ptr [rip+ctx_menu], 0  # or another title
    jne     .Lmo_default
    mov     rdi, [rip+mx]
    mov     rsi, [rip+my]
    call    menu_title_at
    cmp     rax, -1
    je      .Lmo_default
    cmp     rax, [rip+menu_open]
    je      .Lmo_default
    mov     rdi, rax
    xor     esi, esi
    call    open_menu
    jmp     .Lmo_default
3:  cmp     qword ptr [rip+drag_mode], 1
    jne     4f
    mov     rdi, [rip+mx]
    mov     rsi, [rip+my]
    call    pos_from_xy
    mov     rdi, rax
    call    drag_to
    jmp     .Lmo_text
4:  cmp     qword ptr [rip+drag_mode], 2
    jne     5f
    mov     rax, [rip+L_ed_h]           # the thumb: scroll = offset * max / room
    sub     rax, [rip+L_th_h]
    jle     .Lmo_default
    mov     rcx, rax
    mov     rax, [rip+my]
    sub     rax, [rip+drag_off]
    sub     rax, [rip+L_ed_y]
    imul    rax, [rip+L_maxscroll]
    cqo
    idiv    rcx
    mov     [rip+scroll_y], rax
    mov     dword ptr [rip+dirty], 1
    jmp     .Lmo_default
5:  call    in_thumb                    # hover the thumb
    cmp     rax, [rip+hover_thumb]
    je      6f
    mov     [rip+hover_thumb], rax
    mov     dword ptr [rip+dirty], 1
6:  call    in_doc
    test    eax, eax
    jz      .Lmo_default
.Lmo_text:
    mov     edi, SHAPE_TEXT
    call    set_cursor
    pop     rbx
    ret
.Lmo_default:
    call    set_cursor_default
    pop     rbx
    ret

# on_button(edi=button, esi=state, edx=time, ecx=mods)
on_button:
    push    rbx
    push    r12
    push    r13
    push    r14
    mov     ebx, edi
    mov     r12d, esi
    mov     r13d, edx
    mov     r14d, ecx
    test    r12d, r12d
    jnz     1f
    cmp     ebx, BTN_LEFT               # released
    jne     .Lbt_ret
    mov     qword ptr [rip+drag_mode], 0
    jmp     .Lbt_ret
1:  cmp     qword ptr [rip+fd_open], 0  # the Open dialog
    je      11f
    mov     edi, ebx
    mov     esi, r12d
    mov     edx, r13d
    mov     r8, [rip+mx]
    mov     r9, [rip+my]
    call    fd_button
    jmp     .Lbt_ret
11: cmp     qword ptr [rip+dlg_kind], 0  # a dialog: only its buttons
    je      2f
    mov     rdi, [rip+mx]
    mov     rsi, [rip+my]
    call    dlg_button_at
    cmp     rax, -1
    je      .Lbt_ret
    mov     [rip+dlg_result], rax
    jmp     .Lbt_ret
2:  call    layout
    cmp     qword ptr [rip+menu_open], 0
    jl      4f
    mov     rdi, [rip+mx]               # a menu is open: an item, or close it
    mov     rsi, [rip+my]
    call    menu_item_at
    cmp     rax, -2
    je      .Lbt_ret
    cmp     rax, -1
    je      3f
    mov     rdi, rax
    call    menu_exec
    jmp     .Lbt_ret
3:  mov     r12, [rip+menu_open]
    call    close_menu
    mov     rdi, [rip+mx]               # (a click on another title opens that)
    mov     rsi, [rip+my]
    call    menu_title_at
    cmp     rax, -1
    je      .Lbt_ret
    cmp     rax, r12
    je      .Lbt_ret
    mov     rdi, rax
    xor     esi, esi
    call    open_menu
    jmp     .Lbt_ret
4:  mov     rdi, [rip+mx]               # the menu bar
    mov     rsi, [rip+my]
    call    menu_title_at
    cmp     rax, -1
    je      5f
    mov     rdi, rax
    xor     esi, esi
    call    open_menu
    jmp     .Lbt_ret
5:  cmp     qword ptr [rip+prompt_mode], 0  # the prompt bar: clicks elsewhere close Find
    je      6f
    mov     rax, [rip+my]
    cmp     rax, [rip+L_pb_y]
    jge     .Lbt_ret
    mov     rcx, [rip+L_ed_y]
    add     rcx, [rip+L_ed_h]
    cmp     rax, rcx
    jge     .Lbt_ret
    cmp     qword ptr [rip+prompt_mode], P_FIND
    jne     .Lbt_ret
    mov     qword ptr [rip+prompt_result], 0
    mov     qword ptr [rip+prompt_done], 1
6:  mov     rax, [rip+mx]               # the scrollbar
    cmp     rax, [rip+L_ed_w]
    jl      8f
    call    in_doc_rows
    test    eax, eax
    jz      .Lbt_ret
    cmp     ebx, BTN_LEFT
    jne     .Lbt_ret
    call    in_thumb
    test    eax, eax
    jz      7f
    mov     qword ptr [rip+drag_mode], 2
    mov     rax, [rip+my]
    sub     rax, [rip+L_th_y]
    mov     [rip+drag_off], rax
    jmp     .Lbt_ret
7:  mov     rax, [rip+L_ed_h]           # beside the thumb: a page that way
    mov     rcx, [rip+my]
    cmp     rcx, [rip+L_th_y]
    jge     71f
    neg     rax
71: add     [rip+scroll_y], rax
    mov     dword ptr [rip+dirty], 1
    jmp     .Lbt_ret
8:  call    in_doc
    test    eax, eax
    jz      .Lbt_ret
    mov     qword ptr [rip+msg_len], 0
    mov     rdi, [rip+mx]
    mov     rsi, [rip+my]
    call    pos_from_xy
    cmp     ebx, BTN_RIGHT              # right: the Edit menu, here
    jne     80f
    mov     rbx, rax
    call    get_sel                     # (outside the selection: the cursor moves)
    cmp     rax, -1
    je      801f
    cmp     rbx, rax
    jb      801f
    cmp     rbx, rdx
    jb      802f
801: mov    qword ptr [rip+sel_anchor], -1
    mov     [rip+cur], rbx
    call    update_want_col
802: mov    edi, 1
    mov     esi, 1
    call    open_menu
    mov     edi, 1
    call    menu_move
    mov     qword ptr [rip+menu_sel], -1
    jmp     .Lbt_ret
80: cmp     ebx, BTN_LEFT
    jne     .Lbt_ret
    mov     rbx, rax                    # rbx = the position clicked
    mov     rax, r13                    # clicks in a row: 2 words, 3 lines
    sub     rax, [rip+click_time]
    cmp     rax, 400
    ja      82f
    mov     rax, [rip+mx]
    sub     rax, [rip+click_x]
    cqo
    xor     rax, rdx
    sub     rax, rdx
    cmp     rax, 6
    ja      82f
    mov     rax, [rip+my]
    sub     rax, [rip+click_y]
    cqo
    xor     rax, rdx
    sub     rax, rdx
    cmp     rax, 6
    ja      82f
    inc     qword ptr [rip+click_n]
    cmp     qword ptr [rip+click_n], 3
    jbe     83f
82: mov     qword ptr [rip+click_n], 1
83: mov     [rip+click_time], r13
    mov     rax, [rip+mx]
    mov     [rip+click_x], rax
    mov     rax, [rip+my]
    mov     [rip+click_y], rax
    mov     qword ptr [rip+prev_edit_kind], 0
    mov     qword ptr [rip+drag_mode], 1
    mov     rax, [rip+click_n]
    mov     [rip+drag_unit], rax
    dec     qword ptr [rip+drag_unit]
    cmp     rax, 1
    jne     85f
    test    r14d, MOD_SHIFT             # one click: the cursor (Shift: extend)
    jz      84f
    cmp     qword ptr [rip+sel_anchor], -1
    jne     841f
    mov     rax, [rip+cur]
    mov     [rip+sel_anchor], rax
841: mov    [rip+cur], rbx
    mov     rax, [rip+sel_anchor]
    mov     [rip+drag_s], rax
    mov     [rip+drag_e], rax
    jmp     86f
84: mov     [rip+sel_anchor], rbx
    mov     [rip+cur], rbx
    jmp     86f
85: mov     rdi, rbx                    # a word or a line: selected whole
    call    unit_at
    mov     [rip+drag_s], rax
    mov     [rip+drag_e], rdx
    mov     [rip+sel_anchor], rax
    mov     [rip+cur], rdx
86: call    update_want_col
    mov     qword ptr [rip+follow], 1
    mov     dword ptr [rip+dirty], 1
.Lbt_ret:
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

in_doc_rows:                            # -> eax = 1 when y is within the text rows
    xor     eax, eax
    mov     rcx, [rip+my]
    cmp     rcx, [rip+L_ed_y]
    jl      9f
    mov     rdx, [rip+L_ed_y]
    add     rdx, [rip+L_ed_h]
    cmp     rcx, rdx
    jge     9f
    mov     eax, 1
9:  ret

# on_axis(edi=axis, esi=value 24.8, edx=mods) - wheel and touchpad
on_axis:
    cmp     qword ptr [rip+fd_open], 0
    jne     fd_wheel
    cmp     qword ptr [rip+dlg_kind], 0
    jne     9f
    cmp     qword ptr [rip+menu_open], 0
    jge     9f
    test    edx, MOD_CTRL
    jz      3f
    test    edi, edi                    # Ctrl+wheel: zoom, a step per notch
    jnz     9f
    movsxd  rax, esi
    add     [rip+zoom_acc], rax
1:  cmp     qword ptr [rip+zoom_acc], -2560
    jg      2f
    add     qword ptr [rip+zoom_acc], 2560
    mov     edi, CMD_ZOOMIN
    call    run_cmd
    jmp     1b
2:  cmp     qword ptr [rip+zoom_acc], 2560
    jl      9f
    sub     qword ptr [rip+zoom_acc], 2560
    mov     edi, CMD_ZOOMOUT
    call    run_cmd
    jmp     2b
3:  test    edx, MOD_SHIFT              # Shift+wheel: sideways
    jz      4f
    mov     edi, 1
4:  movsxd  rax, esi                    # a notch (10.0) moves 3 lines / cells
    imul    rax, rax, 3
    test    edi, edi
    jnz     5f
    mov     ecx, [rip+ed_lh]
    imul    rax, rcx
    cqo
    mov     ecx, 2560
    idiv    rcx
    add     [rip+scroll_y], rax
    jmp     6f
5:  mov     ecx, [rip+ed_cw16]
    imul    rax, rcx
    sar     rax, 16
    cqo
    mov     ecx, 2560
    idiv    rcx
    add     [rip+scroll_x], rax
6:  mov     dword ptr [rip+dirty], 1
9:  ret

on_drop:                                # a file was dropped on the window: open it
    cmp     qword ptr [rip+modal], 0
    jne     9f
    call    ask_save
    test    eax, eax
    jz      9f
    lea     rsi, [rip+drop_req]
    lea     rdi, [rip+fname]
    xor     ecx, ecx
1:  mov     al, [rsi+rcx]
    mov     [rdi+rcx], al
    test    al, al
    jz      2f
    inc     ecx
    jmp     1b
2:  mov     [rip+fname_len], rcx
    call    doc_load
    call    view_reset
9:  ret

# =============================================================================
#  Start-up and configuration
# =============================================================================
# pt_to_px(edi=points) -> eax = px (at 96 dpi: 4/3)
pt_to_px:
    lea     eax, [rdi*4+1]
    xor     edx, edx
    mov     ecx, 3
    div     ecx
    ret

ui_init:                                # the font from the configuration
    mov     edi, [rip+cfg_size]
    test    edi, edi
    jz      1f
    call    pt_to_px
    mov     [rip+base_px], eax
1:  mov     eax, [rip+base_px]
    mov     [rip+ed_px], eax
    xor     edi, edi
    cmp     byte ptr [rip+cfg_font], 0
    je      2f
    lea     rdi, [rip+cfg_font]
2:  jmp     fonts_init

# ui_config_changed - beenote.conf changed (an Omarchy font switch): reload
ui_config_changed:
    push    rbx
    cmp     byte ptr [rip+cfg_font], 0
    je      1f
    lea     rdi, [rip+cfg_font]
    lea     rsi, [rip+font_path]
    call    str_eq
    test    eax, eax
    jnz     1f
    lea     rdi, [rip+cfg_font]
    call    fonts_init
1:  mov     edi, [rip+cfg_size]
    test    edi, edi
    jz      9f
    call    pt_to_px
    cmp     eax, [rip+base_px]
    je      9f
    mov     [rip+base_px], eax
    mov     edi, eax
    call    zoom_to
    mov     qword ptr [rip+msg_len], 0  # (no "Zoom" message for this)
9:  mov     dword ptr [rip+dirty], 1
    pop     rbx
    ret

.section .note.GNU-stack,"",@progbits
