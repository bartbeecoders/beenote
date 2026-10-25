# =============================================================================
#  BeeNote - the platform layer, Linux version: what the shared modules ask
#  of the system. plat_win.s answers the same calls on Windows.
# =============================================================================
.intel_syntax noprefix

.globl plat_sys
.globl plat_path_in

.text

# plat_sys - a Linux system call: rax = its number, the arguments in rdi,
#   rsi, rdx, r10, r8, r9; rax = the result or -errno; rcx and r11 are lost
plat_sys:
    syscall
    ret

# plat_path_in(rdi=path, rsi=its length (qword), edx=room) - a typed path
#   in the form the file calls take: Linux paths already are
plat_path_in:
    ret

.section .note.GNU-stack,"",@progbits
