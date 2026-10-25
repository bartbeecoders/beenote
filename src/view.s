# =============================================================================
#  BeeNote - the window's contents: layout, the document view (line numbers,
#  the cursor's line, the selection, the caret), the scrollbar, the menu bar
#  and its menus, the tab bar, the status bar, the prompt bar and dialogs.
#
#  Everything is drawn in physical pixels in the Omarchy theme's colours;
#  logical sizes go through to_px. Geometry the mouse needs (menu titles and
#  items, the scrollbar's thumb, dialog buttons) is kept from the last layout.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "beenote.inc"

.globl ui_draw
.globl dim_all
.globl layout
.globl pos_from_xy
.globl menu_title_at
.globl menu_item_at
.globl dlg_button_at
.globl tab_at
.globl menu_tab
.globl mi_file
.globl mi_file_var
.globl s_app_id
.globl s_app_title
# state (input.s changes it)
.globl scroll_y
.globl scroll_x
.globl follow
.globl show_lnum
.globl last_title
.globl menu_open
.globl menu_sel
.globl ctx_menu
.globl ctx_x
.globl ctx_y
.globl prompt_mode
.globl prompt_label
.globl pbuf
.globl plen
.globl find_fail
.globl dlg_kind
.globl dlg_focus
.globl dlg_nb
.globl hover_thumb
# layout (input.s reads it)
.globl L_mb_h
.globl L_ed_y
.globl L_ed_h
.globl L_ed_w
.globl L_scr_w
.globl L_text_x
.globl L_total
.globl L_th_y
.globl L_th_h
.globl L_maxscroll
.globl L_pb_y

.section .data
.align 8
menu_open:      .quad -1
menu_sel:       .quad -1
show_lnum:      .quad 1
last_title:     .byte 0
                .skip 255

.section .bss
.align 8
scroll_y:       .skip 8                 # px
scroll_x:       .skip 8
follow:         .skip 8                 # 1: bring the caret into view
ctx_menu:       .skip 8                 # 1: the open menu is the context menu
ctx_x:          .skip 8
ctx_y:          .skip 8
prompt_mode:    .skip 8
prompt_label:   .skip 8                 # asciz
plen:           .skip 8
find_fail:      .skip 8
dlg_kind:       .skip 8
dlg_focus:      .skip 8
dlg_nb:         .skip 8
hover_thumb:    .skip 8
L_mb_h:         .skip 8
L_sb_h:         .skip 8
L_tb_h:         .skip 8                 # the tab bar (0: one tab, none shown)
L_tw:           .skip 8                 # a tab's width
L_tx:           .skip 8                 # the first tab's x (<= 0: scrolled)
L_pb_h:         .skip 8
L_pb_y:         .skip 8
L_ed_y:         .skip 8
L_ed_h:         .skip 8
L_ed_w:         .skip 8
L_scr_w:        .skip 8
L_gw:           .skip 8
L_text_x:       .skip 8
L_total:        .skip 8
L_cy:           .skip 8
L_ccol:         .skip 8
L_th_y:         .skip 8
L_th_h:         .skip 8
L_maxscroll:    .skip 8
mt_x:           .skip 8*NMENUS
mt_w:           .skip 8*NMENUS
dd_x:           .skip 8
dd_y:           .skip 8
dd_w:           .skip 8
dd_h:           .skip 8
dlg_x:          .skip 8
dlg_y:          .skip 8
dlg_w:          .skip 8
dlg_h:          .skip 8
dlg_bx:         .skip 8*4
dlg_bw:         .skip 8*4
dlg_by:         .skip 8
dlg_bh:         .skip 8
sb:             .skip 512               # status / title text being built
sb_len:         .skip 8
pbuf:           .skip PROMPT_MAX

.section .rodata
s_app_id:       .asciz "beenote"
s_app_title:    .asciz "BeeNote"
s_untitled:     .asciz "Untitled"
s_check:        .ascii "\342\234\223"   # ✓
s_dot:          .ascii " \342\227\217"  # ●
s_tab_x:        .ascii "\303\227"        # ×
s_sep:          .ascii "    "
s_title_tail:   .ascii " \342\200\224 BeeNote"   # " — BeeNote"
s_title_tail_e:

# ---- menus --------------------------------------------------------------------
t_file:  .ascii "File"
t_edit:  .ascii "Edit"
t_search: .ascii "Search"
t_view:  .ascii "View"
t_help:  .ascii "Help"
.align 8
mi_edit:
    ITEM "Undo", "Ctrl+Z", CMD_UNDO, 0
    ITEM "Redo", "Ctrl+Shift+Z", CMD_REDO, 0
    SEP
    ITEM "Cut", "Ctrl+X", CMD_CUT, 2
    ITEM "Copy", "Ctrl+C", CMD_COPY, 0
    ITEM "Paste", "Ctrl+V", CMD_PASTE, 0
    ITEM "Delete", "Del", CMD_DELETE, 0
    SEP
    ITEM "Select All", "Ctrl+A", CMD_SELALL, 7
mi_edit_end:
mi_search:
    ITEM "Find\342\200\246", "Ctrl+F", CMD_FIND, 0
    ITEM "Find Next", "F3", CMD_NEXT, 5
    ITEM "Find Previous", "Shift+F3", CMD_PREV, 5
    SEP
    ITEM "Go to Line\342\200\246", "Ctrl+G", CMD_GOTO, 0
mi_search_end:
mi_view:
    ITEM "Zoom In", "Ctrl++", CMD_ZOOMIN, 5
    ITEM "Zoom Out", "Ctrl+-", CMD_ZOOMOUT, 5
    ITEM "Actual Size", "Ctrl+0", CMD_ZOOM0, 0
    SEP
    ITEM "Line Numbers", "", CMD_LNUM, 0, 1
    SEP
    ITEM "Next Tab", "Ctrl+Tab", CMD_TABNEXT, 0
    ITEM "Previous Tab", "Ctrl+Shift+Tab", CMD_TABPREV, 0
mi_view_end:
mi_help:
    ITEM "Keyboard Shortcuts", "F1", CMD_HELP, 0
    ITEM "About BeeNote", "", CMD_ABOUT, 0
mi_help_end:
.section .data
.align 8
mi_file:                                # (writable: recent.s lists the files)
    ITEM "New", "Ctrl+N", CMD_NEW, 0
    ITEM "Open\342\200\246", "Ctrl+O", CMD_OPEN, 0
    ITEM "Save", "Ctrl+S", CMD_SAVE, 0
    ITEM "Save As\342\200\246", "Ctrl+Shift+S", CMD_SAVEAS, 5
    ITEM "Close Tab", "Ctrl+W", CMD_CLOSE, 6
    SEP
mi_file_var:                            # the recent files, then Quit
    ITEM "Quit", "Ctrl+Q", CMD_QUIT, 0
    .skip MI_SZ*(RECENT_N+3)
menu_tab:       # title, title length, items, item count (rc_menu sets File's)
    .quad t_file, 4, mi_file, (mi_file_var - mi_file) / MI_SZ + 1
    .quad t_edit, 4, mi_edit, (mi_edit_end - mi_edit) / MI_SZ
    .quad t_search, 6, mi_search, (mi_search_end - mi_search) / MI_SZ
    .quad t_view, 4, mi_view, (mi_view_end - mi_view) / MI_SZ
    .quad t_help, 4, mi_help, (mi_help_end - mi_help) / MI_SZ
.section .rodata

# ---- dialogs --------------------------------------------------------------------
b_save:     .asciz "Save"
b_nosave:   .asciz "Don't Save"
b_cancel:   .asciz "Cancel"
b_ok:       .asciz "OK"
.align 8
dlg_buttons:                            # per dialog kind: count, labels
    .quad 0, 0, 0, 0
    .quad 3, b_save, b_nosave, b_cancel # 1: unsaved changes
    .quad 1, b_ok, 0, 0                 # 2: about
    .quad 1, b_ok, 0, 0                 # 3: keyboard shortcuts
d_ask_t:    .asciz "Save changes?"
d_ask_1:    .asciz "has unsaved changes."
d_ask_2:    .asciz "They are lost if you don't save them."
d_about_t:  .asciz "BeeNote"
d_about_1:  .asciz "A notepad written in pure x86-64 assembly:"
d_about_2:  .asciz "no libc, no toolkit, a native Wayland window."
d_about_3:  .asciz "Colours and font follow your Omarchy theme."
d_about_4:  .asciz "Wayland, keyboard and font code from BeeModel."
d_help_t:   .asciz "Keyboard shortcuts"
.macro HK k, d
    .pushsection .rodata.str
1:  .asciz "\k"
2:  .asciz "\d"
    .popsection
    .quad 1b, 2b
.endm
.align 8
help_rows:
    HK "Ctrl+N, Ctrl+O, Ctrl+S", "New tab, open, save"
    HK "Ctrl+Shift+S", "Save as"
    HK "Ctrl+Q", "Quit"
    HK "Ctrl+W", "Close the tab (or middle click it)"
    HK "Ctrl+Tab, Ctrl+Shift+Tab", "Next, previous tab"
    HK "Alt+1 ... Alt+9", "That tab (Alt+9: the last)"
    HK "Ctrl+Z, Ctrl+Shift+Z", "Undo, redo"
    HK "Ctrl+X, Ctrl+C, Ctrl+V", "Cut, copy, paste (no selection: the line)"
    HK "Ctrl+A", "Select all"
    HK "Ctrl+F, F3, Shift+F3", "Find, next, previous"
    HK "Ctrl+G", "Go to line"
    HK "Ctrl++, Ctrl+-, Ctrl+0", "Zoom in, out, reset (also Ctrl+wheel)"
    HK "Ctrl+Left, Ctrl+Right", "Move by word"
    HK "Ctrl+Backspace, Ctrl+Del", "Delete a word"
    HK "Shift + any move", "Select"
    HK "Double, triple click", "Select a word, a line"
    HK "F10, Alt+F/E/S/V/H", "Menus (right click: Edit menu)"
    HK "Ctrl+O dialog: type", "Filter the list, or type a path (~/...)"
    HK "Backspace, Ctrl+H", "Up a folder, show hidden files"
    HK "Tab in Save as", "Complete a file name"
help_rows_end:
.equ HELP_N, (help_rows_end - help_rows) / 16

.text

# rect(edi=x, esi=y, edx=w, ecx=h, r8d=colour) in physical px
rect:
    jmp     fill_rect_px

# text_c(rdi=asciz, edx=x, ecx=centre y, r8d=colour) -> eax = x after
text_c:
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

# width_c(rdi=asciz) -> eax
width_c:
    push    rdi
    call    str_len
    mov     rsi, rax
    pop     rdi
    jmp     ui_text_w

ndigits:                                # rdi = n -> eax = decimal digits
    mov     eax, 1
    mov     rcx, 10
1:  cmp     rdi, rcx
    jb      2f
    inc     eax
    imul    rcx, rcx, 10
    jmp     1b
2:  ret

# =============================================================================
#  Layout
# =============================================================================
layout:
    push    rbx
    push    r12
    push    r13
    push    r14
    mov     ebx, [rip+ui_lh]
    SP      eax, 14
    add     eax, ebx
    mov     [rip+L_mb_h], rax
    SP      eax, 12
    add     eax, ebx
    mov     [rip+L_sb_h], rax
    xor     eax, eax                    # the tab bar, for more than one tab
    cmp     qword ptr [rip+tab_n], 1
    jbe     0f
    SP      eax, 12
    add     eax, ebx
0:  mov     [rip+L_tb_h], rax
    xor     eax, eax
    cmp     qword ptr [rip+prompt_mode], 0
    je      1f
    SP      eax, 22
    add     eax, ebx
1:  mov     [rip+L_pb_h], rax
    SP      eax, 12
    mov     [rip+L_scr_w], rax
    mov     rax, [rip+L_mb_h]
    add     rax, [rip+L_tb_h]
    mov     [rip+L_ed_y], rax
    mov     eax, [rip+fb_h]             # the prompt bar ends where the status bar begins
    sub     rax, [rip+L_sb_h]
    mov     [rip+L_pb_y], rax
    sub     rax, [rip+L_ed_y]
    sub     rax, [rip+L_pb_h]
    cmp     rax, 1
    jge     2f
    mov     eax, 1
2:  mov     [rip+L_ed_h], rax
    mov     eax, [rip+fb_w]
    sub     rax, [rip+L_scr_w]
    mov     [rip+L_ed_w], rax
    xor     edi, edi                    # lines
    mov     rsi, [rip+tlen]
    call    count_nl
    inc     rax
    mov     [rip+L_total], rax
    xor     eax, eax                    # the line-number gutter
    cmp     qword ptr [rip+show_lnum], 0
    je      3f
    mov     rdi, [rip+L_total]
    call    ndigits
    cmp     eax, 3
    jae     21f
    mov     eax, 3
21: add     eax, 2
    imul    eax, [rip+ed_cw16]
    shr     eax, 16
3:  mov     [rip+L_gw], rax
    SP      ecx, 10
    add     rax, rcx
    mov     [rip+L_text_x], rax
    mov     rdi, [rip+cur]              # the caret's line and column
    call    line_start
    mov     rbx, rax
    xor     edi, edi
    mov     rsi, rax
    call    count_nl
    mov     [rip+L_cy], rax
    mov     rdi, rbx
    mov     rsi, [rip+cur]
    call    col_of
    mov     [rip+L_ccol], rax
    SP      r12d, 4                     # menu titles
    xor     ebx, ebx
4:  cmp     ebx, NMENUS
    jae     5f
    mov     rax, rbx
    shl     rax, 5
    lea     rcx, [rip+menu_tab]
    mov     rdi, [rcx+rax]
    mov     rsi, [rcx+rax+8]
    call    ui_text_w
    mov     r13d, eax
    SP      eax, 20
    add     r13d, eax
    lea     rcx, [rip+mt_x]
    mov     [rcx+rbx*8], r12
    lea     rcx, [rip+mt_w]
    mov     [rcx+rbx*8], r13
    add     r12, r13
    inc     ebx
    jmp     4b
5:  call    tab_geom
    cmp     qword ptr [rip+menu_open], 0
    jl      9f
    call    dropdown_geom
9:  pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# tab_geom - the tabs share the window's width (within limits); when they
#   do not fit, the strip scrolls to keep the active one in view
tab_geom:
    mov     eax, [rip+fb_w]
    xor     edx, edx
    div     qword ptr [rip+tab_n]
    SP      ecx, 220
    cmp     rax, rcx
    jle     1f
    mov     rax, rcx
1:  SP      ecx, 100
    cmp     rax, rcx
    jge     2f
    mov     rax, rcx
2:  mov     [rip+L_tw], rax
    mov     rcx, [rip+tab_cur]
    inc     rcx
    imul    rcx, rax
    mov     eax, [rip+fb_w]
    sub     rcx, rax
    jge     3f
    xor     ecx, ecx
3:  neg     rcx
    mov     [rip+L_tx], rcx
    ret

# the open menu: its items and their count -> rax, rdx
menu_items:
    mov     rax, [rip+menu_open]
    shl     rax, 5
    lea     rcx, [rip+menu_tab]
    mov     rdx, [rcx+rax+24]
    mov     rax, [rcx+rax+16]
    ret

item_h:                                 # rdi = item -> eax = its height
    cmp     qword ptr [rdi], 0
    je      1f
    mov     eax, [rip+ui_lh]
    push    rax
    mov     edi, 12
    call    to_px
    pop     rcx
    add     eax, ecx
    ret
1:  mov     edi, 9
    jmp     to_px

dropdown_geom:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    call    menu_items
    mov     rbx, rax
    mov     r12, rdx
    xor     r13d, r13d                  # widest label + shortcut
    SP      r15d, 8                     # height: padding above and below
1:  test    r12, r12
    jz      3f
    mov     rdi, rbx
    call    item_h
    add     r15d, eax
    cmp     qword ptr [rbx], 0
    je      2f
    mov     rdi, [rbx]
    call    width_c
    mov     r14d, eax
    mov     rdi, [rbx+8]
    call    width_c
    add     r14d, eax
    cmp     r14d, r13d
    jbe     2f
    mov     r13d, r14d
2:  add     rbx, MI_SZ
    dec     r12
    jmp     1b
3:  SP      eax, 80
    add     r13d, eax
    SP      eax, 220
    cmp     r13d, eax
    jae     4f
    mov     r13d, eax
4:  mov     [rip+dd_w], r13
    mov     [rip+dd_h], r15
    cmp     qword ptr [rip+ctx_menu], 0
    jne     5f
    mov     rax, [rip+menu_open]
    lea     rcx, [rip+mt_x]
    mov     rax, [rcx+rax*8]
    mov     [rip+dd_x], rax
    mov     rax, [rip+L_mb_h]
    mov     [rip+dd_y], rax
    jmp     6f
5:  mov     rax, [rip+ctx_x]
    mov     [rip+dd_x], rax
    mov     rax, [rip+ctx_y]
    mov     [rip+dd_y], rax
6:  mov     eax, [rip+fb_w]             # keep it on screen
    sub     rax, [rip+dd_w]
    cmp     [rip+dd_x], rax
    jle     7f
    mov     [rip+dd_x], rax
7:  cmp     qword ptr [rip+dd_x], 0
    jge     8f
    mov     qword ptr [rip+dd_x], 0
8:  mov     eax, [rip+fb_h]
    sub     rax, [rip+dd_h]
    cmp     [rip+dd_y], rax
    jle     9f
    mov     [rip+dd_y], rax
9:  pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  Hit testing (physical px)
# =============================================================================
# menu_title_at(edi=x, esi=y) -> rax = menu index or -1
menu_title_at:
    mov     rax, -1
    cmp     rsi, [rip+L_mb_h]
    jge     9f
    xor     ecx, ecx
1:  cmp     ecx, NMENUS
    jae     9f
    lea     rdx, [rip+mt_x]
    mov     r8, [rdx+rcx*8]
    cmp     rdi, r8
    jl      2f
    lea     rdx, [rip+mt_w]
    add     r8, [rdx+rcx*8]
    cmp     rdi, r8
    jge     2f
    mov     eax, ecx
    ret
2:  inc     ecx
    jmp     1b
9:  ret

# menu_item_at(edi=x, esi=y) -> rax = item index, -2 inside but not on an
#   item (a separator, the padding), -1 outside the open menu
menu_item_at:
    push    rbx
    push    r12
    push    r13
    push    r14
    mov     r13, rdi
    mov     r14, rsi
    mov     rax, -1
    cmp     qword ptr [rip+menu_open], 0
    jl      9f
    mov     rcx, [rip+dd_x]
    cmp     r13, rcx
    jl      9f
    add     rcx, [rip+dd_w]
    cmp     r13, rcx
    jge     9f
    mov     rcx, [rip+dd_y]
    cmp     r14, rcx
    jl      9f
    add     rcx, [rip+dd_h]
    cmp     r14, rcx
    jge     9f
    call    menu_items
    mov     rbx, rax
    push    rdx
    SP      r12d, 4
    add     r12, [rip+dd_y]             # the first item's top
    pop     rcx
    xor     edx, edx                    # index
1:  cmp     rdx, rcx
    jae     8f
    push    rcx
    push    rdx
    mov     rdi, rbx
    call    item_h
    pop     rdx
    pop     rcx
    add     rax, r12
    cmp     r14, rax
    jl      2f
    mov     r12, rax
    add     rbx, MI_SZ
    inc     rdx
    jmp     1b
2:  cmp     r14, r12
    jl      8f
    cmp     qword ptr [rbx], 0
    je      8f
    mov     rax, rdx
    jmp     9f
8:  mov     rax, -2
9:  pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# dlg_button_at(edi=x, esi=y) -> rax = button index or -1
dlg_button_at:
    mov     rax, -1
    cmp     rsi, [rip+dlg_by]
    jl      9f
    mov     rcx, [rip+dlg_by]
    add     rcx, [rip+dlg_bh]
    cmp     rsi, rcx
    jge     9f
    xor     ecx, ecx
1:  cmp     rcx, [rip+dlg_nb]
    jae     9f
    lea     rdx, [rip+dlg_bx]
    mov     r8, [rdx+rcx*8]
    cmp     rdi, r8
    jl      2f
    lea     rdx, [rip+dlg_bw]
    add     r8, [rdx+rcx*8]
    cmp     rdi, r8
    jge     2f
    mov     rax, rcx
    ret
2:  inc     ecx
    jmp     1b
9:  ret

# tab_at(edi=x, esi=y) -> rax = the tab there, -2 on the tab bar but on no
#   tab, -1 off the tab bar; edx = 1 on the tab's close mark (its right end)
tab_at:
    mov     rax, -1
    cmp     qword ptr [rip+L_tb_h], 0
    je      9f
    cmp     rsi, [rip+L_mb_h]
    jl      9f
    mov     rcx, [rip+L_mb_h]
    add     rcx, [rip+L_tb_h]
    cmp     rsi, rcx
    jge     9f
    mov     rax, rdi
    sub     rax, [rip+L_tx]
    js      8f
    xor     edx, edx
    div     qword ptr [rip+L_tw]
    cmp     rax, [rip+tab_n]
    jae     8f
    mov     rcx, [rip+L_tw]
    sub     rcx, rdx                    # (from the right end)
    SP      r8d, 30
    xor     edx, edx
    cmp     rcx, r8
    setle   dl
    ret
8:  mov     rax, -2
9:  ret

# pos_from_xy(edi=x, esi=y) -> rax = the document position there
pos_from_xy:
    push    rbx
    push    r12
    mov     r12, rdi
    mov     rax, rsi                    # line = (y - top + scroll) / lh
    sub     rax, [rip+L_ed_y]
    add     rax, [rip+scroll_y]
    jns     1f
    xor     eax, eax
1:  xor     edx, edx
    mov     ecx, [rip+ed_lh]
    div     rcx
    mov     rcx, [rip+L_total]
    dec     rcx
    cmp     rax, rcx
    jbe     2f
    mov     rax, rcx
2:  mov     rdi, rax
    call    line_offset
    mov     rbx, rax
    mov     rax, r12                    # column = (x - origin + scroll) / cell, rounded
    sub     rax, [rip+L_text_x]
    add     rax, [rip+scroll_x]
    jns     3f
    xor     eax, eax
3:  shl     rax, 16
    mov     ecx, [rip+ed_cw16]
    mov     rdx, rcx
    shr     rdx, 1
    add     rax, rdx
    xor     edx, edx
    div     rcx
    mov     rdi, rbx
    mov     rsi, rax
    call    pos_at_col
    pop     r12
    pop     rbx
    ret

# =============================================================================
#  Drawing
# =============================================================================
ui_draw:
    push    rbx
    call    reset_clip
    call    layout
    call    scroll_fix
    COL     r8d, C_BG
    xor     edi, edi
    xor     esi, esi
    mov     edx, [rip+fb_w]
    mov     ecx, [rip+fb_h]
    call    rect
    call    draw_doc
    call    draw_scrollbar
    call    reset_clip
    call    draw_menubar
    call    draw_tabbar
    call    draw_status
    cmp     qword ptr [rip+prompt_mode], 0
    je      1f
    call    draw_prompt
1:  cmp     qword ptr [rip+menu_open], 0
    jl      2f
    call    draw_dropdown
2:  cmp     qword ptr [rip+fd_open], 0  # the Open dialog
    je      21f
    call    dim_all
    call    draw_filedlg
21: cmp     qword ptr [rip+dlg_kind], 0
    je      3f
    call    dim_all
    call    draw_dialog
3:  call    update_title
    pop     rbx
    ret

# scroll_fix - the caret in view (when asked), the scroll in range, and the
#   scrollbar's thumb
scroll_fix:
    push    rbx
    mov     ebx, [rip+ed_lh]
    cmp     qword ptr [rip+follow], 0
    je      3f
    mov     qword ptr [rip+follow], 0
    mov     rax, [rip+L_cy]             # vertical
    imul    rax, rbx
    cmp     rax, [rip+scroll_y]
    jge     1f
    mov     [rip+scroll_y], rax
1:  add     rax, rbx
    sub     rax, [rip+L_ed_h]
    cmp     rax, [rip+scroll_y]
    jle     2f
    mov     [rip+scroll_y], rax
2:  mov     rax, [rip+L_ccol]           # horizontal
    imul    eax, [rip+ed_cw16]
    shr     rax, 16
    mov     rcx, [rip+L_ed_w]           # text width
    sub     rcx, [rip+L_text_x]
    mov     rdx, rcx
    shr     rdx, 2                      # (a quarter of it as margin)
    cmp     rax, [rip+scroll_x]
    jge     21f
    sub     rax, rdx
    mov     [rip+scroll_x], rax
    jmp     3f
21: mov     r8d, [rip+ed_cw16]
    shr     r8, 16
    lea     r9, [rax+r8]
    sub     r9, rcx
    cmp     r9, [rip+scroll_x]
    jle     3f
    add     r9, rdx
    mov     [rip+scroll_x], r9
3:  cmp     qword ptr [rip+scroll_x], 0
    jge     4f
    mov     qword ptr [rip+scroll_x], 0
4:  mov     rax, [rip+L_total]          # the last line may scroll to the top
    dec     rax
    imul    rax, rbx
    mov     [rip+L_maxscroll], rax
    cmp     [rip+scroll_y], rax
    jle     5f
    mov     [rip+scroll_y], rax
5:  cmp     qword ptr [rip+scroll_y], 0
    jge     6f
    mov     qword ptr [rip+scroll_y], 0
6:  mov     qword ptr [rip+L_th_h], 0   # the thumb
    mov     rcx, [rip+L_maxscroll]
    test    rcx, rcx
    jz      9f
    mov     rax, [rip+L_ed_h]           # height = view * view / (view + max)
    imul    rax, rax
    mov     r8, [rip+L_ed_h]
    add     r8, rcx
    xor     edx, edx
    div     r8
    push    rax
    SP      eax, 28
    pop     rdx
    cmp     rdx, rax
    jge     7f
    mov     rdx, rax
7:  mov     [rip+L_th_h], rdx
    mov     rax, [rip+L_ed_h]           # top = scroll * (view - height) / max
    sub     rax, rdx
    imul    rax, [rip+scroll_y]
    xor     edx, edx
    div     qword ptr [rip+L_maxscroll]
    add     rax, [rip+L_ed_y]
    mov     [rip+L_th_y], rax
9:  pop     rbx
    ret

# draw_doc - the visible lines: gutter, cursor line, selection, text, caret
draw_doc:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 56
    # [rsp] line number, [rsp+8] its y, [rsp+16] sel start, [rsp+24] sel end,
    # [rsp+32] line end, [rsp+40] text left edge
    mov     edi, 0                      # clip: the document area
    mov     esi, [rip+L_ed_y]
    mov     edx, [rip+L_ed_w]
    mov     ecx, [rip+L_ed_y]
    add     ecx, [rip+L_ed_h]
    call    set_clip_px
    call    get_sel
    mov     [rsp+16], rax
    mov     [rsp+24], rdx
    mov     rax, [rip+scroll_y]         # the first visible line
    xor     edx, edx
    mov     ecx, [rip+ed_lh]
    div     rcx
    mov     [rsp], rax
    neg     rdx
    add     rdx, [rip+L_ed_y]
    mov     [rsp+8], rdx
    mov     rdi, rax
    call    line_offset
    mov     rbx, rax                    # rbx = the line's start
.Ldd_line:
    mov     rax, [rsp]
    cmp     rax, [rip+L_total]
    jae     .Ldd_caret
    mov     rax, [rsp+8]
    mov     rcx, [rip+L_ed_y]
    add     rcx, [rip+L_ed_h]
    cmp     rax, rcx
    jge     .Ldd_caret
    mov     rdi, rbx
    call    line_end
    mov     [rsp+32], rax
    # the cursor's line (no selection): a lighter band
    mov     rax, [rsp]
    cmp     rax, [rip+L_cy]
    jne     1f
    cmp     qword ptr [rsp+16], -1
    jne     1f
    xor     edi, edi
    mov     esi, [rsp+8]
    mov     edx, [rip+L_ed_w]
    mov     ecx, [rip+ed_lh]
    COL     r8d, C_CURLINE
    call    rect
1:  # the line number
    cmp     qword ptr [rip+show_lnum], 0
    je      2f
    mov     rdi, [rsp]
    inc     rdi
    call    utoa                        # rsi = digits, rdx = count
    mov     r12, rsi
    mov     r13, rdx
    mov     eax, [rip+L_gw]             # right edge: one cell before the gutter's end
    shl     eax, 16
    sub     eax, [rip+ed_cw16]
    mov     ecx, r13d
    imul    ecx, [rip+ed_cw16]
    sub     eax, ecx
    mov     r14d, eax                   # pen (16.16)
    COL     r15d, C_MUTED
    mov     rax, [rsp]
    cmp     rax, [rip+L_cy]
    jne     11f
    COL     r15d, C_FG
11: test    r13, r13
    jz      2f
    movzx   esi, byte ptr [r12]
    mov     edi, FONT_MONO
    mov     edx, r14d
    sar     edx, 16
    mov     ecx, [rsp+8]
    add     ecx, [rip+ed_asc]
    mov     r8d, r15d
    call    draw_glyph
    add     r14d, [rip+ed_cw16]
    inc     r12
    dec     r13
    jmp     11b
2:  # the text, clipped to the text area
    mov     edi, [rip+L_gw]
    mov     esi, [rip+L_ed_y]
    mov     edx, [rip+L_ed_w]
    mov     ecx, [rip+L_ed_y]
    add     ecx, [rip+L_ed_h]
    call    set_clip_px
    mov     rax, [rip+L_text_x]
    sub     rax, [rip+scroll_x]
    mov     [rsp+40], rax
    # the selection on this line
    mov     rax, [rsp+16]
    cmp     rax, -1
    je      3f
    mov     rcx, [rsp+24]
    cmp     rcx, rbx                    # ends before the line?
    jbe     3f
    cmp     rax, [rsp+32]               # starts after it?
    ja      3f
    xor     r12d, r12d                  # start column
    cmp     rax, rbx
    jbe     21f
    mov     rdi, rbx
    mov     rsi, rax
    call    col_of
    mov     r12, rax
21: mov     rcx, [rsp+24]               # end column (+1 for the line break)
    cmp     rcx, [rsp+32]
    ja      22f
    mov     rdi, rbx
    mov     rsi, rcx
    call    col_of
    jmp     23f
22: mov     rdi, rbx
    mov     rsi, [rsp+32]
    call    col_of
    inc     rax
23: sub     rax, r12
    jbe     3f
    imul    eax, [rip+ed_cw16]          # width
    shr     eax, 16
    mov     edx, eax
    mov     eax, r12d
    imul    eax, [rip+ed_cw16]
    shr     eax, 16
    mov     edi, eax
    add     edi, [rsp+40]
    mov     esi, [rsp+8]
    mov     ecx, [rip+ed_lh]
    COL     r8d, C_SEL
    call    rect
3:  # the characters
    mov     r12, rbx                    # position
    xor     r13d, r13d                  # column
    mov     r15d, [rsp+8]
    add     r15d, [rip+ed_asc]          # baseline
4:  cmp     r12, [rsp+32]
    jae     .Ldd_next
    mov     eax, r13d                   # x
    imul    eax, [rip+ed_cw16]
    shr     eax, 16
    add     eax, [rsp+40]
    mov     ebp, eax
    cmp     ebp, [rip+L_ed_w]
    jge     .Ldd_next                   # (the rest is off to the right)
    lea     rax, [rip+text]
    movzx   eax, byte ptr [rax+r12]
    cmp     eax, 9
    jne     5f
    or      r13, TABW-1
    inc     r13
    inc     r12
    jmp     4b
5:  mov     rdi, r12
    call    utf8_at
    mov     r12, rdx
    mov     r14d, eax                   # code point
    mov     eax, ebp                    # visible at all?
    add     eax, 64
    cmp     eax, [rip+L_gw]
    jl      7f
    COL     r8d, C_FG
    cmp     r14d, 32                    # control characters: a red '?'
    jb      6f
    cmp     r14d, 127
    jne     61f
6:  mov     r14d, '?'
    COL     r8d, C_RED
61: mov     edi, FONT_MONO
    mov     esi, r14d
    mov     edx, ebp
    mov     ecx, r15d
    call    draw_glyph
7:  inc     r13
    jmp     4b
.Ldd_next:
    mov     rax, [rsp+32]               # the next line
    lea     rbx, [rax+1]
    inc     qword ptr [rsp]
    mov     eax, [rip+ed_lh]
    add     [rsp+8], rax
    mov     edi, 0                      # (the gutter's clip again)
    mov     esi, [rip+L_ed_y]
    mov     edx, [rip+L_ed_w]
    mov     ecx, [rip+L_ed_y]
    add     ecx, [rip+L_ed_h]
    call    set_clip_px
    jmp     .Ldd_line
.Ldd_caret:
    cmp     qword ptr [rip+dlg_kind], 0
    jne     9f
    mov     edi, [rip+L_gw]
    mov     esi, [rip+L_ed_y]
    mov     edx, [rip+L_ed_w]
    mov     ecx, [rip+L_ed_y]
    add     ecx, [rip+L_ed_h]
    call    set_clip_px
    mov     rax, [rip+L_ccol]
    imul    eax, [rip+ed_cw16]
    shr     eax, 16
    add     rax, [rip+L_text_x]
    sub     rax, [rip+scroll_x]
    mov     rbx, rax
    mov     rax, [rip+L_cy]
    imul    eax, [rip+ed_lh]
    add     rax, [rip+L_ed_y]
    sub     rax, [rip+scroll_y]
    mov     r12, rax
    SP      edx, 2
    mov     edi, ebx
    mov     esi, r12d
    mov     ecx, [rip+ed_lh]
    COL     r8d, C_ACCENT
    call    rect
9:  call    reset_clip
    add     rsp, 56
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

draw_scrollbar:
    push    rbx
    cmp     qword ptr [rip+L_th_h], 0
    je      9f
    SP      ebx, 3
    mov     edi, [rip+L_ed_w]
    add     edi, ebx
    mov     esi, [rip+L_th_y]
    mov     edx, [rip+L_scr_w]
    sub     edx, ebx
    sub     edx, ebx
    mov     ecx, [rip+L_th_h]
    COL     r8d, C_MUTED
    cmp     qword ptr [rip+hover_thumb], 0
    je      1f
    COL     r8d, C_FG_DIM
    cmp     r8d, [rip+th_col+C_MUTED]
    jne     1f
    COL     r8d, C_FG
1:  call    rect
9:  pop     rbx
    ret

draw_menubar:
    push    rbx
    push    r12
    push    r13
    xor     edi, edi
    xor     esi, esi
    mov     edx, [rip+fb_w]
    mov     ecx, [rip+L_mb_h]
    COL     r8d, C_BG_DARK
    call    rect
    mov     r13, [rip+L_mb_h]
    shr     r13, 1                      # text centre
    xor     ebx, ebx
1:  cmp     ebx, NMENUS
    jae     9f
    cmp     rbx, [rip+menu_open]
    jne     2f
    cmp     qword ptr [rip+ctx_menu], 0
    jne     2f
    lea     rax, [rip+mt_x]
    mov     edi, [rax+rbx*8]
    xor     esi, esi
    lea     rax, [rip+mt_w]
    mov     edx, [rax+rbx*8]
    mov     ecx, [rip+L_mb_h]
    COL     r8d, C_SEL
    call    rect
2:  mov     rax, rbx
    shl     rax, 5
    lea     rcx, [rip+menu_tab]
    mov     rdi, [rcx+rax]
    mov     rsi, [rcx+rax+8]
    lea     rax, [rip+mt_x]
    mov     r12d, [rax+rbx*8]
    push    rdi
    push    rsi
    SP      edx, 10
    pop     rsi
    pop     rdi
    add     edx, r12d
    mov     ecx, r13d
    COL     r8d, C_FG
    call    ui_text
    inc     ebx
    jmp     1b
9:  pop     r13
    pop     r12
    pop     rbx
    ret

# draw_tabbar - under the menu bar when more than one tab is open: each
#   file's name, the active tab in the document's colour, and a close mark
#   (a dot instead while it has unsaved changes)
draw_tabbar:
    cmp     qword ptr [rip+L_tb_h], 0
    je      .Ldt_none
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 24                     # [rsp] unsaved, [rsp+8] name, [rsp+16] its bytes
    mov     r13, [rip+L_mb_h]           # r13 = top
    xor     edi, edi
    mov     esi, r13d
    mov     edx, [rip+fb_w]
    mov     ecx, [rip+L_tb_h]
    COL     r8d, C_BG_DARK
    call    rect
    xor     edi, edi                    # a hairline under it
    mov     esi, r13d
    add     esi, [rip+L_tb_h]
    dec     esi
    mov     edx, [rip+fb_w]
    mov     ecx, 1
    COL     r8d, C_BG_LIGHT
    call    rect
    mov     r14, [rip+L_tb_h]
    shr     r14, 1
    add     r14, r13                    # r14 = centre
    xor     ebx, ebx                    # rbx = the tab
1:  cmp     rbx, [rip+tab_n]
    jae     9f
    mov     r12, rbx                    # r12 = its x
    imul    r12, [rip+L_tw]
    add     r12, [rip+L_tx]
    mov     eax, [rip+fb_w]
    cmp     r12, rax
    jge     9f
    cmp     rbx, [rip+tab_cur]
    jne     2f
    mov     edi, r12d                   # the active one: the document's colour
    mov     esi, r13d
    mov     edx, [rip+L_tw]
    mov     ecx, [rip+L_tb_h]
    COL     r8d, C_BG
    call    rect
    mov     edi, r12d                   # ... with an accent line on top
    mov     esi, r13d
    mov     edx, [rip+L_tw]
    SP      ecx, 2
    COL     r8d, C_ACCENT
    call    rect
    jmp     3f
2:  SP      eax, 8                      # the others: a line between them
    mov     edi, r12d
    add     edi, [rip+L_tw]
    dec     edi
    lea     esi, [r13+rax]
    mov     ecx, [rip+L_tb_h]
    sub     ecx, eax
    sub     ecx, eax
    mov     edx, 1
    COL     r8d, C_BG_LIGHT
    call    rect
3:  mov     rdi, rbx                    # the name (not its folders)
    call    tab_info
    mov     [rsp], rcx
    test    rdx, rdx
    jnz     4f
    lea     rsi, [rip+s_untitled]
    mov     edx, 8
    jmp     5f
4:  lea     rax, [rsi+rdx]
    mov     rcx, rax
41: cmp     rcx, rsi
    jbe     42f
    cmp     byte ptr [rcx-1], '/'
    je      42f
    dec     rcx
    jmp     41b
42: sub     rax, rcx
    mov     rsi, rcx
    mov     rdx, rax
5:  mov     [rsp+8], rsi
    mov     [rsp+16], rdx
    SP      eax, 12                     # clipped short of the mark
    lea     edi, [r12+rax]
    mov     esi, r13d
    mov     edx, r12d
    add     edx, [rip+L_tw]
    SP      eax, 32
    sub     edx, eax
    mov     ecx, r13d
    add     ecx, [rip+L_tb_h]
    call    set_clip_px
    mov     rdi, [rsp+8]
    mov     rsi, [rsp+16]
    SP      eax, 12
    lea     edx, [r12+rax]
    mov     ecx, r14d
    COL     r8d, C_FG_DIM
    cmp     rbx, [rip+tab_cur]
    jne     6f
    COL     r8d, C_FG
6:  call    ui_text
    call    reset_clip
    lea     rbp, [rip+s_tab_x]          # the mark: x, or a dot when unsaved
    mov     qword ptr [rsp+8], 2
    COL     r15d, C_FG_DIM
    cmp     qword ptr [rsp], 0
    je      7f
    lea     rbp, [rip+s_dot+1]
    mov     qword ptr [rsp+8], 3
    COL     r15d, C_ACCENT
7:  mov     rdi, rbp
    mov     rsi, [rsp+8]
    call    ui_text_w
    mov     edx, r12d                   # centred 16 px from the right end
    add     edx, [rip+L_tw]
    SP      ecx, 16
    sub     edx, ecx
    shr     eax, 1
    sub     edx, eax
    mov     rdi, rbp
    mov     rsi, [rsp+8]
    mov     ecx, r14d
    mov     r8d, r15d
    call    ui_text
    inc     rbx
    jmp     1b
9:  call    reset_clip
    add     rsp, 24
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
.Ldt_none:
    ret

# sb_add(rsi=text, rdx=bytes) / sb_cstr(rdi=asciz) / sb_num(rdi) - build sb
sb_add:
    mov     rax, [rip+sb_len]
    mov     rcx, 500
    sub     rcx, rax
    cmp     rdx, rcx
    jbe     1f
    mov     rdx, rcx
1:  lea     rdi, [rip+sb]
    add     rdi, rax
    mov     rcx, rdx
    rep     movsb
    add     [rip+sb_len], rdx
    ret
sb_cstr:
    push    rdi
    call    str_len
    mov     rdx, rax
    pop     rsi
    jmp     sb_add
sb_num:
    call    utoa
    jmp     sb_add
# sb_name - the file's name, or "Untitled"
sb_name:
    mov     rdx, [rip+fname_len]
    test    rdx, rdx
    jnz     1f
    lea     rdi, [rip+s_untitled]
    jmp     sb_cstr
1:  lea     rax, [rip+fname]
    lea     rsi, [rax+rdx]
2:  cmp     rsi, rax
    jbe     3f
    cmp     byte ptr [rsi-1], '/'
    je      3f
    dec     rsi
    jmp     2b
3:  add     rdx, rax
    sub     rdx, rsi
    jmp     sb_add

draw_status:
    push    rbx
    push    r12
    push    r13
    push    r14
    mov     ebx, [rip+fb_h]
    sub     rbx, [rip+L_sb_h]           # top
    xor     edi, edi
    mov     esi, ebx
    mov     edx, [rip+fb_w]
    mov     ecx, [rip+L_sb_h]
    COL     r8d, C_BG_DARK
    call    rect
    mov     r12, [rip+L_sb_h]
    shr     r12, 1
    add     r12, rbx                    # text centre
    # right: Ln, Col, lines, line endings, encoding, zoom
    mov     qword ptr [rip+sb_len], 0
    LSTR    "Ln "
    call    sb_add
    mov     rdi, [rip+L_cy]
    inc     rdi
    call    sb_num
    LSTR    ", Col "
    call    sb_add
    mov     rdi, [rip+L_ccol]
    inc     rdi
    call    sb_num
    lea     rsi, [rip+s_sep]
    mov     edx, 4
    call    sb_add
    mov     rdi, [rip+L_total]
    call    sb_num
    LSTR    " lines"
    call    sb_add
    lea     rsi, [rip+s_sep]
    mov     edx, 4
    call    sb_add
    cmp     qword ptr [rip+crlf], 0
    je      1f
    LSTR    "CRLF"
    jmp     2f
1:  LSTR    "LF"
2:  call    sb_add
    lea     rsi, [rip+s_sep]
    mov     edx, 4
    call    sb_add
    LSTR    "UTF-8"
    call    sb_add
    lea     rsi, [rip+s_sep]
    mov     edx, 4
    call    sb_add
    mov     eax, [rip+ed_px]            # zoom: the size against the configured one
    imul    eax, eax, 100
    xor     edx, edx
    div     dword ptr [rip+base_px]
    mov     edi, eax
    call    sb_num
    LSTR    "%"
    call    sb_add
    lea     rdi, [rip+sb]
    mov     rsi, [rip+sb_len]
    call    ui_text_w
    mov     r13d, [rip+fb_w]
    sub     r13d, eax
    SP      eax, 12
    sub     r13d, eax                   # r13 = where the right part starts
    lea     rdi, [rip+sb]
    mov     rsi, [rip+sb_len]
    mov     edx, r13d
    mov     ecx, r12d
    COL     r8d, C_FG_DIM
    call    ui_text
    # left: the message, or the file's name and whether it is modified
    xor     edi, edi
    mov     esi, ebx
    mov     edx, r13d
    SP      eax, 12
    sub     edx, eax
    mov     ecx, [rip+fb_h]
    call    set_clip_px
    SP      r14d, 12
    cmp     qword ptr [rip+msg_len], 0
    je      3f
    lea     rdi, [rip+msg]
    mov     rsi, [rip+msg_len]
    mov     edx, r14d
    mov     ecx, r12d
    COL     r8d, C_FG
    cmp     qword ptr [rip+msg_err], 0
    je      21f
    COL     r8d, C_RED
21: call    ui_text
    jmp     9f
3:  mov     qword ptr [rip+sb_len], 0
    call    sb_name
    lea     rdi, [rip+sb]
    mov     rsi, [rip+sb_len]
    mov     edx, r14d
    mov     ecx, r12d
    COL     r8d, C_FG
    call    ui_text
    cmp     qword ptr [rip+dirty_doc], 0
    je      9f
    lea     rdi, [rip+s_dot]
    mov     esi, 4
    mov     edx, eax
    mov     ecx, r12d
    COL     r8d, C_ACCENT
    call    ui_text
9:  call    reset_clip
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

# the prompt bar: a label and an input field (Find, Go to line, Open, Save as)
draw_prompt:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     rbx, [rip+L_pb_y]
    sub     rbx, [rip+L_pb_h]           # top
    xor     edi, edi
    mov     esi, ebx
    mov     edx, [rip+fb_w]
    mov     ecx, [rip+L_pb_h]
    COL     r8d, C_BG_DARK
    call    rect
    xor     edi, edi                    # a hairline above it
    mov     esi, ebx
    mov     edx, [rip+fb_w]
    mov     ecx, 1
    COL     r8d, C_BG_LIGHT
    call    rect
    mov     r12, [rip+L_pb_h]
    shr     r12, 1
    add     r12, rbx                    # centre
    SP      edx, 12
    mov     rdi, [rip+prompt_label]
    mov     ecx, r12d
    COL     r8d, C_FG_DIM
    call    text_c
    SP      ecx, 10
    lea     r13d, [rax+rcx]             # the field's left edge
    mov     r14d, [rip+fb_w]            # ... and right edge
    SP      eax, 12
    sub     r14d, eax
    cmp     qword ptr [rip+prompt_mode], P_FIND
    jne     2f
    LSTR    "No results"                # find: how it went, on the right
    cmp     qword ptr [rip+find_fail], 0
    jne     1f
    LSTR    "Enter next   Shift+Enter previous   Esc close"
1:  push    rsi
    push    rdx
    mov     rdi, rsi
    mov     rsi, rdx
    call    ui_text_w
    pop     rsi                         # rdi = text, rsi = bytes
    pop     rdi
    sub     r14d, eax
    mov     edx, r14d
    mov     ecx, r12d
    COL     r8d, C_FG_DIM
    cmp     qword ptr [rip+find_fail], 0
    je      11f
    COL     r8d, C_RED
11: call    ui_text
    SP      eax, 16
    sub     r14d, eax
2:  SP      r15d, 5                     # the field
    mov     edi, r13d
    lea     esi, [rbx+r15]
    mov     edx, r14d
    sub     edx, r13d
    mov     ecx, [rip+L_pb_h]
    sub     ecx, r15d
    sub     ecx, r15d
    COL     r8d, C_ACCENT
    push    rdi
    push    rsi
    push    rdx
    push    rcx
    call    rect
    pop     rcx
    pop     rdx
    pop     rsi
    pop     rdi
    inc     edi                         # (its border: 1 px)
    inc     esi
    sub     edx, 2
    sub     ecx, 2
    COL     r8d, C_BG
    call    rect
    SP      eax, 8                      # the text, its tail when it is long
    add     r13d, eax
    sub     r14d, eax
    mov     edi, r13d
    mov     esi, ebx
    mov     edx, r14d
    mov     ecx, ebx
    add     ecx, [rip+L_pb_h]
    call    set_clip_px
    lea     rdi, [rip+pbuf]
    mov     rsi, [rip+plen]
    call    ui_text_w
    mov     edx, r13d
    mov     ecx, r14d
    sub     ecx, r13d
    SP      r15d, 4
    sub     ecx, r15d
    cmp     eax, ecx
    jle     3f
    sub     eax, ecx
    sub     edx, eax
3:  lea     rdi, [rip+pbuf]
    mov     rsi, [rip+plen]
    mov     ecx, r12d
    COL     r8d, C_FG
    call    ui_text
    mov     edi, eax                    # the caret
    inc     edi
    mov     esi, r12d
    mov     eax, [rip+ui_lh]
    shr     eax, 1
    sub     esi, eax
    SP      edx, 2
    mov     ecx, [rip+ui_lh]
    COL     r8d, C_ACCENT
    call    rect
    call    reset_clip
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

draw_dropdown:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
    mov     edi, [rip+dd_x]             # the frame: accent border, dark inside
    mov     esi, [rip+dd_y]
    mov     edx, [rip+dd_w]
    mov     ecx, [rip+dd_h]
    COL     r8d, C_ACCENT
    call    rect
    mov     edi, [rip+dd_x]
    inc     edi
    mov     esi, [rip+dd_y]
    inc     esi
    mov     edx, [rip+dd_w]
    sub     edx, 2
    mov     ecx, [rip+dd_h]
    sub     ecx, 2
    COL     r8d, C_BG_DARK
    call    rect
    call    menu_items
    mov     rbx, rax
    mov     r15, rdx
    SP      r12d, 4
    add     r12, [rip+dd_y]             # item top
    xor     ebp, ebp                    # index
1:  cmp     rbp, r15
    jae     9f
    mov     rdi, rbx
    call    item_h
    mov     r13d, eax                   # height
    cmp     qword ptr [rbx], 0
    jne     2f
    SP      eax, 10                     # a separator line
    mov     edi, [rip+dd_x]
    add     edi, eax
    mov     esi, r13d
    shr     esi, 1
    add     esi, r12d
    mov     edx, [rip+dd_w]
    sub     edx, eax
    sub     edx, eax
    mov     ecx, 1
    COL     r8d, C_BG_LIGHT
    call    rect
    jmp     8f
2:  cmp     rbp, [rip+menu_sel]         # the highlighted item
    jne     3f
    SP      eax, 4
    mov     edi, [rip+dd_x]
    add     edi, eax
    mov     esi, r12d
    mov     edx, [rip+dd_w]
    sub     edx, eax
    sub     edx, eax
    mov     ecx, r13d
    COL     r8d, C_SEL
    call    rect
3:  mov     r14d, r13d
    shr     r14d, 1
    add     r14d, r12d                  # centre
    cmp     dword ptr [rbx+24], 1       # a check box: Line numbers
    jne     4f
    cmp     qword ptr [rip+show_lnum], 0
    je      4f
    SP      edx, 10
    add     edx, [rip+dd_x]
    lea     rdi, [rip+s_check]
    mov     esi, 3
    mov     ecx, r14d
    COL     r8d, C_ACCENT
    call    ui_text
4:  SP      edx, 28                     # the label
    add     edx, [rip+dd_x]
    mov     [rsp], rdx
    mov     rdi, [rbx]
    mov     ecx, r14d
    COL     r8d, C_FG
    call    text_c
    mov     rdi, [rbx]                  # its mnemonic, underlined
    mov     esi, [rbx+20]
    call    ui_text_w
    add     [rsp], rax
    mov     rdi, [rbx]
    mov     eax, [rbx+20]
    add     rdi, rax
    mov     esi, 1
    call    ui_text_w
    mov     edx, eax
    mov     edi, [rsp]
    mov     esi, r14d
    add     esi, [rip+ui_asc]
    sub     esi, [rip+ui_desc]
    sar     esi, 1
    add     esi, r14d
    sub     esi, r14d
    mov     esi, r14d                   # baseline + 2
    mov     eax, [rip+ui_asc]
    sub     eax, [rip+ui_desc]
    sar     eax, 1
    add     esi, eax
    add     esi, 2
    mov     ecx, 1
    COL     r8d, C_FG_DIM
    call    rect
    mov     rdi, [rbx+8]                # the shortcut, right-aligned
    call    width_c
    mov     edx, [rip+dd_x]
    add     edx, [rip+dd_w]
    sub     edx, eax
    SP      eax, 14
    sub     edx, eax
    mov     rdi, [rbx+8]
    mov     ecx, r14d
    COL     r8d, C_FG_DIM
    call    text_c
8:  add     r12d, r13d
    add     rbx, MI_SZ
    inc     rbp
    jmp     1b
9:  add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

dim_all:                                # darken the window under a dialog
    mov     rdi, [rip+fb_ptr]
    mov     eax, [rip+fb_w]
    imul    eax, [rip+fb_h]
    mov     ecx, eax
1:  test    ecx, ecx
    jz      2f
    mov     eax, [rdi]
    shr     eax, 1
    and     eax, 0x7f7f7f
    mov     [rdi], eax
    add     rdi, 4
    dec     ecx
    jmp     1b
2:  ret

# draw_dialog - the box, its title and lines, and its buttons
draw_dialog:
    push    rbx
    push    rbp
    push    r12
    push    r13
    push    r14
    push    r15
    sub     rsp, 8
    mov     rbx, [rip+dlg_kind]
    mov     r13d, [rip+ui_lh]           # a line
    SP      eax, 8
    add     r13d, eax
    # size: the shortcut list is wider and taller
    SP      eax, 460
    mov     [rip+dlg_w], rax
    mov     ecx, 2                      # text lines: unsaved changes 2, about 4, keys
    cmp     rbx, D_ABOUT
    jne     11f
    mov     ecx, 4
11: cmp     rbx, D_HELP
    jne     1f
    SP      eax, 640
    mov     [rip+dlg_w], rax
    mov     ecx, HELP_N
1:  mov     eax, ecx
    add     eax, 2                      # + the title (bigger gap)
    imul    eax, r13d
    mov     r14d, eax
    SP      eax, 76                     # + padding and the buttons
    add     eax, r13d
    add     eax, r14d
    mov     [rip+dlg_h], rax
    mov     eax, [rip+fb_w]             # centred, kept on screen
    SP      ecx, 16
    sub     eax, ecx
    sub     eax, ecx
    cmp     rax, [rip+dlg_w]
    jge     2f
    mov     [rip+dlg_w], rax
2:  mov     eax, [rip+fb_w]
    sub     rax, [rip+dlg_w]
    sar     rax, 1
    mov     [rip+dlg_x], rax
    mov     eax, [rip+fb_h]
    sub     rax, [rip+dlg_h]
    sar     rax, 1
    jns     3f
    xor     eax, eax
3:  mov     [rip+dlg_y], rax
    mov     edi, [rip+dlg_x]            # frame
    mov     esi, [rip+dlg_y]
    mov     edx, [rip+dlg_w]
    mov     ecx, [rip+dlg_h]
    COL     r8d, C_ACCENT
    call    rect
    mov     edi, [rip+dlg_x]
    inc     edi
    mov     esi, [rip+dlg_y]
    inc     esi
    mov     edx, [rip+dlg_w]
    sub     edx, 2
    mov     ecx, [rip+dlg_h]
    sub     ecx, 2
    COL     r8d, C_BG_DARK
    call    rect
    mov     edi, [rip+dlg_x]            # clip the text to the box
    mov     esi, [rip+dlg_y]
    mov     edx, [rip+dlg_x]
    add     edx, [rip+dlg_w]
    SP      eax, 16
    sub     edx, eax
    mov     ecx, [rip+dlg_y]
    add     ecx, [rip+dlg_h]
    call    set_clip_px
    SP      r12d, 24
    add     r12d, [rip+dlg_x]           # text x
    SP      r14d, 22
    add     r14d, [rip+dlg_y]
    mov     eax, r13d
    shr     eax, 1
    add     r14d, eax                   # first line's centre
    cmp     rbx, 1
    je      .Ldg_ask
    cmp     rbx, 2
    je      .Ldg_about
    # keyboard shortcuts: keys in the accent colour, then what they do
    lea     rdi, [rip+d_help_t]
    mov     edx, r12d
    mov     ecx, r14d
    COL     r8d, C_FG
    call    text_c
    lea     r14d, [r14+r13*2]
    lea     r15, [rip+help_rows]
    mov     ebp, HELP_N
4:  mov     rdi, [r15]
    mov     edx, r12d
    mov     ecx, r14d
    COL     r8d, C_ACCENT
    call    text_c
    mov     rdi, [r15+8]
    SP      edx, 250
    add     edx, r12d
    mov     ecx, r14d
    COL     r8d, C_FG
    call    text_c
    add     r14d, r13d
    add     r15, 16
    dec     ebp
    jnz     4b
    jmp     .Ldg_buttons
.Ldg_ask:
    lea     rdi, [rip+d_ask_t]
    mov     edx, r12d
    mov     ecx, r14d
    COL     r8d, C_FG
    call    text_c
    lea     r14d, [r14+r13*2]
    mov     qword ptr [rip+sb_len], 0   # "name" has unsaved changes.
    LSTR    "\342\200\234"
    call    sb_add
    call    sb_name
    LSTR    "\342\200\235 "
    call    sb_add
    lea     rdi, [rip+d_ask_1]
    call    sb_cstr
    lea     rdi, [rip+sb]
    mov     rsi, [rip+sb_len]
    mov     edx, r12d
    mov     ecx, r14d
    COL     r8d, C_FG
    call    ui_text
    add     r14d, r13d
    lea     rdi, [rip+d_ask_2]
    mov     edx, r12d
    mov     ecx, r14d
    COL     r8d, C_FG_DIM
    call    text_c
    jmp     .Ldg_buttons
.Ldg_about:
    mov     qword ptr [rip+sb_len], 0
    lea     rdi, [rip+d_about_t]
    call    sb_cstr
    LSTR    " "
    call    sb_add
    lea     rdi, [rip+s_version]
    call    sb_cstr
    lea     rdi, [rip+sb]
    mov     rsi, [rip+sb_len]
    mov     edx, r12d
    mov     ecx, r14d
    COL     r8d, C_FG
    call    ui_text
    lea     r14d, [r14+r13*2]
    lea     r15, [rip+about_lines]
5:  mov     rdi, [r15]
    test    rdi, rdi
    jz      .Ldg_buttons
    mov     edx, r12d
    mov     ecx, r14d
    COL     r8d, C_FG
    call    text_c
    add     r14d, r13d
    add     r15, 8
    jmp     5b
.Ldg_buttons:
    call    reset_clip
    mov     rax, rbx                    # this kind's buttons
    shl     rax, 5
    lea     r15, [rip+dlg_buttons]
    add     r15, rax
    mov     rax, [r15]
    mov     [rip+dlg_nb], rax
    mov     eax, [rip+ui_lh]
    SP      ecx, 14
    add     eax, ecx
    mov     [rip+dlg_bh], rax
    mov     eax, [rip+dlg_y]            # bottom, with padding
    add     rax, [rip+dlg_h]
    sub     rax, [rip+dlg_bh]
    SP      ecx, 18
    sub     rax, rcx
    mov     [rip+dlg_by], rax
    mov     ebp, [rip+dlg_x]            # right to left from the right edge
    add     rbp, [rip+dlg_w]
    SP      eax, 18
    sub     rbp, rax
    mov     r14, [rip+dlg_nb]           # (from the last button)
6:  test    r14, r14
    jz      9f
    dec     r14
    mov     rdi, [r15+8+r14*8]
    call    width_c
    SP      ecx, 36
    add     eax, ecx
    sub     rbp, rax
    lea     rcx, [rip+dlg_bx]
    mov     [rcx+r14*8], rbp
    lea     rcx, [rip+dlg_bw]
    mov     [rcx+r14*8], rax
    mov     edi, ebp
    mov     esi, [rip+dlg_by]
    mov     edx, eax
    mov     ecx, [rip+dlg_bh]
    COL     r8d, C_BG_LIGHT
    COL     r12d, C_FG
    cmp     r14, [rip+dlg_focus]
    jne     7f
    COL     r8d, C_ACCENT
    COL     r12d, C_BG
7:  push    rdx
    sub     rsp, 8
    call    rect
    add     rsp, 8
    pop     rdx
    mov     rdi, [r15+8+r14*8]
    call    width_c
    mov     edx, [rip+dlg_bw+0]         # centred label
    lea     rcx, [rip+dlg_bw]
    mov     edx, [rcx+r14*8]
    sub     edx, eax
    sar     edx, 1
    add     edx, ebp
    mov     ecx, [rip+dlg_bh]
    shr     ecx, 1
    add     ecx, [rip+dlg_by]
    mov     rdi, [r15+8+r14*8]
    mov     r8d, r12d
    call    text_c
    SP      eax, 8
    sub     rbp, rax
    jmp     6b
9:  add     rsp, 8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbp
    pop     rbx
    ret

# update_title - the window's title: "● name — BeeNote" (● when modified)
update_title:
    mov     qword ptr [rip+sb_len], 0
    cmp     qword ptr [rip+dirty_doc], 0
    je      1f
    LSTR    "\342\227\217 "
    call    sb_add
1:  call    sb_name
    lea     rsi, [rip+s_title_tail]
    mov     edx, s_title_tail_e - s_title_tail
    call    sb_add
    lea     rax, [rip+sb]
    mov     rcx, [rip+sb_len]
    mov     byte ptr [rax+rcx], 0
    lea     rdi, [rip+sb]
    lea     rsi, [rip+last_title]
    call    str_eq
    test    eax, eax
    jnz     9f
    lea     rsi, [rip+sb]               # changed: remember it, tell the window
    lea     rdi, [rip+last_title]
    mov     rcx, [rip+sb_len]
    inc     rcx
    cmp     rcx, 255
    jbe     2f
    mov     ecx, 255
    mov     byte ptr [rsi+254], 0
2:  rep     movsb
    lea     rdi, [rip+last_title]
    jmp     set_title
9:  ret

.section .rodata
.align 8
about_lines:    .quad d_about_1, d_about_2, d_about_3, d_about_4, 0

.section .note.GNU-stack,"",@progbits
