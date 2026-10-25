# =============================================================================
#  BeeNote - a notepad for Wayland, written in x86-64 assembly (GNU as,
#  Intel syntax). No libc, no libwayland, no toolkit: the kernel through
#  syscalls, the compositor through the Wayland wire protocol.
#
#  main.s: start-up, the command line and the event loop (pump).
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "beenote.inc"
.include "version.inc"

.globl _start
.globl pump

.section .bss
.align 8
pollfds:        .skip 8*3               # Wayland, key repeat, theme check
argv_files:     .skip 8                 # the next file named on the command line

.section .rodata
s_opt_version:  .asciz "--version"
s_opt_help:     .asciz "--help"
s_help:         .ascii "Usage: beenote [file...]\n"
                .ascii "A notepad for Wayland in pure x86-64 assembly. Its colours and font\n"
                .ascii "follow the current Omarchy theme. F1 in the window lists the keys.\n"
                .ascii "BEENOTE_FONT=/path/to/font.ttf picks another font.\n"
s_help_end:
s_name:         .ascii "BeeNote "
s_name_end:
s_nl:           .ascii "\n"
e_nowl:         .asciz "beenote: needs a Wayland session (WAYLAND_DISPLAY is not set)\n"
s_wd:           .asciz "WAYLAND_DISPLAY="

.text

_start:
    mov     rax, [rsp]                  # argc
    lea     rcx, [rsp+rax*8+16]         # envp = argv + argc + 1
    mov     [rip+envp], rcx
    mov     rbx, [rsp+16]               # argv[1] (0 if absent)
    lea     rax, [rsp+16]               # (the files: argv[1...])
    mov     [rip+argv_files], rax
    and     rsp, -16
    test    rbx, rbx
    jz      .Lnoarg
    mov     rdi, rbx
    lea     rsi, [rip+s_opt_version]
    call    str_eq
    test    eax, eax
    jz      1f
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
    lea     rsi, [rip+s_nl]
    mov     edx, 1
    call    write_all
    jmp     .Lexit
1:  mov     rdi, rbx
    lea     rsi, [rip+s_opt_help]
    call    str_eq
    test    eax, eax
    jz      .Lnoarg
    mov     edi, 1
    lea     rsi, [rip+s_help]
    mov     edx, s_help_end - s_help
    call    write_all
    jmp     .Lexit
.Lnoarg:
    lea     rdi, [rip+s_wd]
    call    getenv
    test    rax, rax
    jnz     5f
    lea     rdi, [rip+e_nowl]
    call    fatal
5:  call    theme_init                  # Omarchy's colours, our configuration
    call    ui_init                     # the font
    call    doc_reset
    call    recent_init                 # the File menu's recent files
3:  mov     rax, [rip+argv_files]       # beenote file...: each opens (or starts)
    mov     rsi, [rax]                  #   in a tab of its own
    test    rsi, rsi
    jz      4f
    add     qword ptr [rip+argv_files], 8
    call    tab_open
    jmp     3b
4:  cmp     qword ptr [rip+tab_n], 1    # several: the first one is shown
    jbe     6f
    xor     edi, edi
    call    tab_switch
    cmp     qword ptr [rip+msg_err], 0
    jne     6f
    mov     qword ptr [rip+msg_len], 0
6:  call    wl_connect
    call    alloc_id                    # wl_display.get_registry
    mov     [rip+id_registry], eax
    mov     edx, eax
    mov     edi, 1
    mov     esi, WL_DISPLAY_GET_REGISTRY
    call    msg1
    call    wl_roundtrip                # globals arrive -> bound on the fly
    cmp     dword ptr [rip+id_compositor], 0
    je      .Lmissing
    cmp     dword ptr [rip+id_shm], 0
    je      .Lmissing
    cmp     dword ptr [rip+id_wm_base], 0
    je      .Lmissing
    call    create_window
    call    clip_init
    call    kb_timer_init
    mov     dword ptr [rip+dirty], 1
.Lloop:
    call    pump
    cmp     dword ptr [rip+quit_flag], 0
    je      .Lloop
.Lexit:
    xor     edi, edi
    mov     eax, SYS_EXIT_GROUP
    syscall
.Lmissing:
    lea     rdi, [rip+e_globals]
    call    fatal

# pump - one turn of the event loop: queued input, a frame when one is due,
#   then sleep until the compositor, the key repeat or the theme timer wakes
#   us. Dialogs and the prompt bar call it in their own loops.
pump:
    push    rbx
    call    process_events
    cmp     dword ptr [rip+quit_flag], 0
    jne     9f
    cmp     dword ptr [rip+dirty], 0
    je      1f
    call    render
1:  mov     edi, -1
    call    wl_flush
    lea     rbx, [rip+pollfds]
    mov     eax, [rip+sock_fd]
    mov     [rbx], eax
    mov     dword ptr [rbx+4], POLLIN
    mov     eax, [rip+rep_fd]
    mov     [rbx+8], eax
    mov     dword ptr [rbx+12], POLLIN
    mov     eax, [rip+th_fd]
    mov     [rbx+16], eax
    mov     dword ptr [rbx+20], POLLIN
    mov     rdi, rbx
    mov     esi, 3
    mov     edx, -1
    mov     eax, SYS_POLL
    syscall
    cmp     rax, -4                     # EINTR
    je      9f
    test    word ptr [rbx+6], POLLIN|POLLERR|POLLHUP
    jz      2f
    call    wl_read_dispatch
2:  test    word ptr [rbx+14], POLLIN
    jz      3f
    call    kb_on_timer
3:  test    word ptr [rbx+22], POLLIN
    jz      4f
    call    theme_check
    test    eax, 2
    jz      31f
    call    ui_config_changed
31: test    eax, eax
    jz      4f
    mov     dword ptr [rip+dirty], 1
4:  call    process_events
9:  pop     rbx
    ret

.section .note.GNU-stack,"",@progbits
