# =============================================================================
#  BeeNote - small helpers: memory moves, numbers, writing files, and the
#  status bar's message.
# =============================================================================
.intel_syntax noprefix
.include "const.inc"
.include "beenote.inc"

.globl memmove
.globl write_all
.globl utoa
.globl prefix
.globl set_msg
.globl set_err
.globl msg_add
.globl msg_num
.globl msg
.globl msg_len
.globl msg_err
.globl th_map

.section .bss
.align 8
msg_len:        .skip 8
msg_err:        .skip 8                 # 1: the message is an error (red)
numbuf:         .skip 32
msg:            .skip MSG_MAX

.text

# memmove(rdi=dst, rsi=src, rdx=n) - overlapping regions are fine
memmove:
    mov     rcx, rdx
    cmp     rdi, rsi
    jbe     1f
    lea     rax, [rsi+rcx]
    cmp     rdi, rax
    jae     1f
    lea     rsi, [rsi+rcx-1]            # overlapping, dst above src: backwards
    lea     rdi, [rdi+rcx-1]
    std
    rep     movsb
    cld
    ret
1:  rep     movsb
    ret

# write_all(rdi=fd, rsi=buf, rdx=n) -> rax = 0, or -errno
write_all:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r12, rsi
    mov     r13, rdx
1:  test    r13, r13
    jz      2f
    mov     eax, SYS_WRITE
    mov     rdi, rbx
    mov     rsi, r12
    mov     rdx, r13
    call    plat_sys
    cmp     rax, -4                     # EINTR
    je      1b
    cmp     rax, -11                    # EAGAIN
    je      1b
    test    rax, rax
    js      3f
    jz      4f
    add     r12, rax
    sub     r13, rax
    jmp     1b
4:  mov     rax, -5                     # (no progress: EIO)
    jmp     3f
2:  xor     eax, eax
3:  pop     r13
    pop     r12
    pop     rbx
    ret

# utoa(rdi=n) -> rsi = digits, rdx = length
utoa:
    mov     rax, rdi
    lea     rsi, [rip+numbuf+32]
    mov     ecx, 10
    xor     r8d, r8d
1:  xor     edx, edx
    div     rcx
    add     dl, '0'
    dec     rsi
    mov     [rsi], dl
    inc     r8
    test    rax, rax
    jnz     1b
    mov     rdx, r8
    ret

# prefix(rdi=string, rsi=prefix) -> eax = 1 when the string starts with it
prefix:
    xor     ecx, ecx
1:  mov     al, [rsi+rcx]
    test    al, al
    jz      2f
    cmp     al, [rdi+rcx]
    jne     3f
    inc     ecx
    jmp     1b
2:  mov     eax, 1
    ret
3:  xor     eax, eax
    ret

# set_msg / set_err (rsi=text, rdx=length) - a new message; msg_add appends
set_err:
    mov     qword ptr [rip+msg_err], 1
    jmp     1f
set_msg:
    mov     qword ptr [rip+msg_err], 0
1:  mov     qword ptr [rip+msg_len], 0
msg_add:
    mov     rax, [rip+msg_len]
    mov     rcx, MSG_MAX
    sub     rcx, rax
    cmp     rdx, rcx
    jbe     2f
    mov     rdx, rcx
2:  lea     rdi, [rip+msg]
    add     rdi, rax
    mov     rcx, rdx
    rep     movsb
    add     [rip+msg_len], rdx
    mov     dword ptr [rip+dirty], 1
    ret

# msg_num(rdi=n) - append a number
msg_num:
    call    utoa
    jmp     msg_add

# th_map(r8d=colour) - BeeModel's drawing code asks the theme to map its
#   colours; BeeNote draws the Omarchy palette's colours as they are
th_map:
    ret

.section .note.GNU-stack,"",@progbits
