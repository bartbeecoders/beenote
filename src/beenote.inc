# =============================================================================
#  BeeNote - constants and macros shared by its own modules
# =============================================================================

# ---- document ---------------------------------------------------------------
.equ TEXT_MAX,      16777216            # 16 MiB document
.equ UNDO_MAX,      16777216            # per history (undo, redo)
.equ FNAME_MAX,     4096
.equ MSG_MAX,       512
.equ PROMPT_MAX,    1024
.equ TABW,          4                   # tab stop (a power of two)
.equ RECENT_N,      10                  # recent files in the File menu
.equ U_INS,         1                   # undo record kinds
.equ U_DEL,         2

# ---- colours: th_col + C_* (the Omarchy theme's palette) --------------------
.equ C_BG,          0                   # background
.equ C_FG,          4                   # foreground
.equ C_ACCENT,      8
.equ C_SEL,         12                  # selection
.equ C_MUTED,       16
.equ C_BG_DARK,     20                  # dark_background (bars)
.equ C_BG_LIGHT,    24                  # lighter_background
.equ C_FG_DIM,      28                  # dark_foreground
.equ C_FG_LIGHT,    32                  # light_foreground
.equ C_RED,         36
.equ C_YELLOW,      40
.equ C_GREEN,       44
.equ C_CURLINE,     48                  # (derived) the cursor's line
.equ C_N,           13

# ---- editor key codes (after translation from evdev) -------------------------
.equ K_LEFT,        1000                # 1000..1011 move the cursor
.equ K_RIGHT,       1001
.equ K_UP,          1002
.equ K_DOWN,        1003
.equ K_HOME,        1004
.equ K_END,         1005
.equ K_PGUP,        1006
.equ K_PGDN,        1007
.equ K_WLEFT,       1008
.equ K_WRIGHT,      1009
.equ K_DOCHOME,     1010
.equ K_DOCEND,      1011
.equ K_DEL,         1012
.equ K_BS,          1013
.equ K_ENTER,       1014
.equ K_TAB,         1015
.equ K_WBS,         1016                # Ctrl+Backspace: the word before
.equ K_WDEL,        1017                # Ctrl+Delete: the word after
.equ K_SHIFT,       0x10000
.equ K_CHAR,        0x200000            # | a code point: type it

# ---- prompt bar modes and dialogs -------------------------------------------
.equ P_FIND,        1
.equ P_GOTO,        2
.equ P_OPEN,        3
.equ P_SAVEAS,      4
.equ D_ASK,         1                   # unsaved changes: Save / Don't Save / Cancel
.equ D_ABOUT,       2
.equ D_HELP,        3
.equ NMENUS,        5                   # File Edit Search View Help

# ---- commands (menus, shortcuts) ----------------------------------------------
.equ CMD_NEW,       1
.equ CMD_OPEN,      2
.equ CMD_SAVE,      3
.equ CMD_SAVEAS,    4
.equ CMD_QUIT,      5
.equ CMD_UNDO,      6
.equ CMD_REDO,      7
.equ CMD_CUT,       8
.equ CMD_COPY,      9
.equ CMD_PASTE,     10
.equ CMD_DELETE,    11
.equ CMD_SELALL,    12
.equ CMD_FIND,      13
.equ CMD_NEXT,      14
.equ CMD_PREV,      15
.equ CMD_GOTO,      16
.equ CMD_ZOOMIN,    17
.equ CMD_ZOOMOUT,   18
.equ CMD_ZOOM0,     19
.equ CMD_LNUM,      20
.equ CMD_HELP,      21
.equ CMD_ABOUT,     22
.equ CMD_RECENT,    23                  # 23 .. 32: open the nth recent file
.equ CMD_RCLEAR,    CMD_RECENT+RECENT_N

# ---- input events (queued while the compositor's messages are parsed) -------
.equ EV_KEY,        1                   # a = evdev code, b = symbol, c = mods | layout code << 16
.equ EV_MOTION,     2                   # a = x, b = y (logical)
.equ EV_BUTTON,     3                   # a = button, b = state, c = time (ms)
.equ EV_AXIS,       4                   # a = axis, b = value (24.8), c = mods
.equ EV_CLOSE,      5
.equ EV_DROP,       6                   # (the path is in drop_req)
.equ EV_LEAVE,      7

# ---- evdev key codes the editor reads (const.inc has the letters) -----------
.equ EK_BACKSPACE,  14
.equ EK_TAB,        15
.equ EK_ENTER,      28
.equ EK_KPENTER,    96
.equ EK_MINUS,      12
.equ EK_EQUAL,      13
.equ EK_0,          11
.equ EK_KPMINUS,    74
.equ EK_KPPLUS,     78
.equ EK_UP,         103
.equ EK_LEFT,       105
.equ EK_RIGHT,      106
.equ EK_END,        107
.equ EK_DOWN,       108
.equ EK_INSERT,     110
.equ EK_F3,         61
.equ EK_F10,        68

# ---- cursor shapes (cursor-shape-v1) ----------------------------------------
.equ SHAPE_DEFAULT, 1
.equ SHAPE_POINTER, 4
.equ SHAPE_TEXT,    9

# ---- macros -----------------------------------------------------------------
# a menu item: label, shortcut (asciz), command, mnemonic (the label's byte
#   underlined), flags (1: the Line Numbers check box)
.equ MI_SZ,         32
.macro ITEM label, short, cmd, mn, flags=0
    .pushsection .rodata.str
1:  .asciz "\label"
2:  .asciz "\short"
    .popsection
    .quad 1b, 2b
    .long \cmd, \mn, \flags, 0
.endm
.macro SEP
    .quad 0, 0
    .long 0, 0, 0, 0
.endm
# LSTR "text" -> rsi = address, rdx = length (the string goes to .rodata)
.macro LSTR s:vararg
    .pushsection .rodata
9997: .ascii \s
9998:
    .popsection
    lea     rsi, [rip+9997b]
    mov     edx, 9998b - 9997b
.endm
.macro SETMSG s:vararg                  # the status bar's message
    LSTR \s
    call    set_msg
.endm
.macro ERRMSG s:vararg                  # ... shown as an error
    LSTR \s
    call    set_err
.endm
.macro MSGADD s:vararg
    LSTR \s
    call    msg_add
.endm
# colour(r8d <- theme colour \c)
.macro COL reg, c
    mov     \reg, [rip+th_col+\c]
.endm

# SP reg, n - reg = n logical px in physical px (to_px); rax and rdi are
#   kept unless reg is eax
.macro SP reg, n
    push    rdi
.ifnc \reg,eax
    push    rax
.endif
    mov     edi, \n
    call    to_px
.ifnc \reg,eax
    mov     \reg, eax
    pop     rax
.endif
    pop     rdi
.endm
