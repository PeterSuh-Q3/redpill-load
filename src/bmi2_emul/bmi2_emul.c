// SPDX-License-Identifier: GPL-2.0
/*
 * bmi2_emul.c - BMI2 instruction software emulator for Ivy Bridge / J4125
 *
 * Synology DSM kernels are compiled with -march=haswell which emits BMI2
 * instructions (MULX, PDEP, PEXT, BZHI, SARX, SHRX, SHLX, RORX).
 * These cause #UD (invalid opcode, int 6) on CPUs without BMI2 support.
 *
 * This module installs a die_notifier that catches #UD traps in kernel
 * mode, decodes 3-byte VEX-encoded BMI2 instructions, emulates them in
 * software and resumes execution — transparent to the rest of the system.
 *
 * Build against the Synology toolkit kernel headers so struct layouts match
 * the binary modules.
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/notifier.h>
#include <linux/string.h>
#include <linux/atomic.h>
#include <asm/kdebug.h>
#include <asm/ptrace.h>
#include <asm/traps.h>
#include <linux/uaccess.h>

MODULE_LICENSE("GPL");
MODULE_AUTHOR("tcrp-modules");
MODULE_DESCRIPTION("BMI2 software emulator (MULX PDEP PEXT BZHI SARX SHRX SHLX RORX)");
MODULE_VERSION("1.0");

/* ------------------------------------------------------------------ */
/* Statistics                                                           */
/* ------------------------------------------------------------------ */
static atomic64_t bmi2_emul_count = ATOMIC64_INIT(0);

/* ------------------------------------------------------------------ */
/* VEX-3 prefix decoder                                                 */
/*                                                                      */
/* 3-byte VEX layout:                                                   */
/*   Byte 0: C4                                                         */
/*   Byte 1: ~R ~X ~B  map[4:0]                                        */
/*   Byte 2:  W ~vvvv  L  pp                                           */
/* ------------------------------------------------------------------ */
struct vex3 {
    int r, x, b;  /* REX extension bits (already un-inverted) */
    int map;      /* opcode map: 1=0F 2=0F38 3=0F3A */
    int w;        /* operand size: 0=32-bit  1=64-bit */
    int vvvv;     /* second source register index (un-inverted) */
    int l;        /* vector length: 0=scalar/128  1=256 */
    int pp;       /* implied prefix: 0=none 1=66 2=F2 3=F3 */
};

static int decode_vex3(const u8 *ip, struct vex3 *v)
{
    if (ip[0] != 0xc4)
        return 0;
    v->r    = !(ip[1] >> 7 & 1);
    v->x    = !(ip[1] >> 6 & 1);
    v->b    = !(ip[1] >> 5 & 1);
    v->map  =   ip[1] & 0x1f;
    v->w    =   ip[2] >> 7 & 1;
    v->vvvv = ~(ip[2] >> 3) & 0xf;
    v->l    =   ip[2] >> 2 & 1;
    v->pp   =   ip[2] & 0x3;
    return 1;
}

/* ------------------------------------------------------------------ */
/* Register file access via pt_regs                                     */
/* ------------------------------------------------------------------ */
static const int reg_offsets[16] = {
    offsetof(struct pt_regs, ax),   /* 0 = rax */
    offsetof(struct pt_regs, cx),   /* 1 = rcx */
    offsetof(struct pt_regs, dx),   /* 2 = rdx */
    offsetof(struct pt_regs, bx),   /* 3 = rbx */
    offsetof(struct pt_regs, sp),   /* 4 = rsp */
    offsetof(struct pt_regs, bp),   /* 5 = rbp */
    offsetof(struct pt_regs, si),   /* 6 = rsi */
    offsetof(struct pt_regs, di),   /* 7 = rdi */
    offsetof(struct pt_regs, r8),   /* 8 = r8  */
    offsetof(struct pt_regs, r9),   /* 9 = r9  */
    offsetof(struct pt_regs, r10),  /* 10 = r10 */
    offsetof(struct pt_regs, r11),  /* 11 = r11 */
    offsetof(struct pt_regs, r12),  /* 12 = r12 */
    offsetof(struct pt_regs, r13),  /* 13 = r13 */
    offsetof(struct pt_regs, r14),  /* 14 = r14 */
    offsetof(struct pt_regs, r15),  /* 15 = r15 */
};

static inline u64 get_reg(struct pt_regs *regs, int r)
{
    return *(u64 *)((char *)regs + reg_offsets[r & 0xf]);
}

static inline void set_reg(struct pt_regs *regs, int r, u64 val)
{
    *(u64 *)((char *)regs + reg_offsets[r & 0xf]) = val;
}

/* ------------------------------------------------------------------ */
/* ModRM + SIB + displacement decoder                                   */
/*                                                                      */
/* p[0] = ModRM byte (ip points HERE, after VEX + opcode)              */
/* Returns bytes consumed.  Sets *is_mem and *out.                      */
/*   is_mem=0: *out = full register index (with REX.B extension)       */
/*   is_mem=1: *out = resolved linear address                          */
/* ------------------------------------------------------------------ */
#define RIP_REL_FLAG (1ULL << 63)

static int decode_modrm(const u8 *p, struct pt_regs *regs,
                        const struct vex3 *v,
                        int *is_mem, u64 *out)
{
    u8 modrm = p[0];
    int mod = modrm >> 6;
    int rm  = modrm & 7;
    int len = 1;

    if (mod == 3) {
        *is_mem = 0;
        *out = (u64)(rm | (v->b << 3));
        return len;
    }

    *is_mem = 1;
    u64 addr = 0;

    if (rm == 4) { /* SIB */
        u8 sib  = p[len++];
        int sc  = 1 << (sib >> 6);
        int idx = (sib >> 3) & 7;
        int bas = sib & 7;

        if (bas == 5 && mod == 0) {
            s32 d; memcpy(&d, p + len, 4); len += 4;
            addr = (u64)(s64)d;
        } else {
            addr = get_reg(regs, bas | (v->b << 3));
        }
        if (idx != 4)
            addr += get_reg(regs, idx | (v->x << 3)) * sc;
    } else if (rm == 5 && mod == 0) {
        /* RIP-relative: store raw disp, flag it; caller adds RIP */
        s32 d; memcpy(&d, p + len, 4); len += 4;
        *out = (u64)(u32)(s32)d | RIP_REL_FLAG;
        return len;
    } else {
        addr = get_reg(regs, rm | (v->b << 3));
    }

    if (mod == 1) { s8  d = (s8)p[len++]; addr += (s64)d; }
    else if (mod == 2) { s32 d; memcpy(&d, p + len, 4); len += 4; addr += (s64)d; }

    *out = addr;
    return len;
}

static u64 read_mem_or_reg(struct pt_regs *regs, int is_mem, u64 val, int w)
{
    if (!is_mem)
        return get_reg(regs, (int)val) & (w ? ~0ULL : 0xffffffffULL);
    return w ? *(u64 *)val : (u64)*(u32 *)val;
}

/* ------------------------------------------------------------------ */
/* PDEP / PEXT bit-manipulation helpers                                  */
/* ------------------------------------------------------------------ */
static u64 emu_pdep(u64 src, u64 mask)
{
    u64 res = 0;
    int k = 0;
    for (int m = 0; m < 64; m++) {
        if (mask & (1ULL << m)) {
            if (src & (1ULL << k))
                res |= 1ULL << m;
            k++;
        }
    }
    return res;
}

static u64 emu_pext(u64 src, u64 mask)
{
    u64 res = 0;
    int k = 0;
    for (int m = 0; m < 64; m++) {
        if (mask & (1ULL << m)) {
            if (src & (1ULL << m))
                res |= 1ULL << k;
            k++;
        }
    }
    return res;
}

/* ------------------------------------------------------------------ */
/* Main emulation dispatcher                                            */
/*                                                                      */
/* ip  = pointer to start of instruction (C4 ...)                      */
/* Returns instruction byte length on success, 0 if not handled.       */
/* ------------------------------------------------------------------ */
static int emulate_bmi2(const u8 *ip, struct pt_regs *regs)
{
    struct vex3 v;
    if (!decode_vex3(ip, &v))
        return 0;

    /* BMI2 only uses map 2 (0F38) or 3 (0F3A), and L=0 */
    if ((v.map != 2 && v.map != 3) || v.l)
        return 0;

    u8  opcode   = ip[3];
    int dst_reg  = ((ip[4] >> 3) & 7) | (v.r << 3);
    int is_mem;
    u64 rm_out;
    int mr_len   = decode_modrm(ip + 4, regs, &v, &is_mem, &rm_out);
    int extra    = 0;   /* immediate bytes */

    /* Fix up RIP-relative address */
    if (is_mem && (rm_out & RIP_REL_FLAG)) {
        /* total prefix = 3 (VEX) + 1 (opcode) + mr_len */
        unsigned long next_ip = regs->ip + 3 + 1 + mr_len;
        rm_out = next_ip + (s32)(rm_out & 0xffffffffULL);
    }

    u64 src_rm  = read_mem_or_reg(regs, is_mem, rm_out, v.w); /* r/m */
    u64 src_vvv = get_reg(regs, v.vvvv);
    if (!v.w) src_vvv &= 0xffffffff;

    u64 result  = 0;
    bool ok     = true;

    if (v.map == 2) {
        switch (opcode) {

        case 0xf5: /* BZHI/PEXT/PDEP */
            if (v.pp == 0) {
                /* BZHI dst, r/m, vvvv — zero high bits above index */
                u64 idx = src_vvv & (v.w ? 63 : 31);
                u64 mask = (idx == (v.w ? 64 : 32)) ? ~0ULL
                         : (1ULL << idx) - 1;
                result = src_rm & mask;
                /* CF = (index >= opsize) — we intentionally don't set flags
                 * since DSM usage of BZHI typically ignores them */
            } else if (v.pp == 2) {
                /* PEXT dst, r/m, vvvv */
                result = emu_pext(src_rm, src_vvv);
            } else if (v.pp == 3) {
                /* PDEP dst, vvvv, r/m  (note: vvvv=src, r/m=mask) */
                result = emu_pdep(src_vvv, src_rm);
            } else ok = false;
            break;

        case 0xf6: /* MULX / ADCX / ADOX */
            if (v.pp == 2) {
                /* MULX dst_hi(dst_reg), dst_lo(vvvv), r/m
                 * Unsigned multiply: RDX * r/m → dst_hi:dst_lo
                 * Does NOT modify flags.                          */
                u64 rdx = get_reg(regs, 2 /* rdx */);
                if (!v.w) rdx &= 0xffffffff;
                if (v.w) {
                    unsigned __int128 p =
                        (unsigned __int128)rdx * (unsigned __int128)src_rm;
                    result = (u64)(p >> 64);
                    set_reg(regs, v.vvvv, (u64)p);
                } else {
                    u64 p = (u64)(u32)rdx * (u64)(u32)src_rm;
                    result = p >> 32;
                    set_reg(regs, v.vvvv, (u32)p);
                }
            } else ok = false; /* ADCX/ADOX: not BMI2, ignore */
            break;

        case 0xf7: /* SARX / SHRX / SHLX */
            {
                u64 cnt = src_vvv & (v.w ? 63 : 31);
                if (v.pp == 0) {        /* SARX — arithmetic right */
                    result = v.w ? (u64)((s64)src_rm >> cnt)
                                 : (u64)((s32)(u32)src_rm >> (int)cnt);
                } else if (v.pp == 2) { /* SHRX — logical right */
                    result = v.w ? src_rm >> cnt : (u32)src_rm >> cnt;
                } else if (v.pp == 1) { /* SHLX — logical left */
                    result = v.w ? src_rm << cnt : (u32)(src_rm << cnt);
                } else ok = false;
            }
            break;

        default: ok = false; break;
        }

    } else { /* map == 3 */
        if (opcode == 0xf0 && v.pp == 2) {
            /* RORX dst, r/m, imm8 — rotate right, no flags */
            u8 imm = ip[4 + mr_len];
            extra = 1;
            u64 cnt = imm & (v.w ? 63 : 31);
            if (v.w) {
                result = (src_rm >> cnt) | (src_rm << (64 - cnt));
            } else {
                u32 s = (u32)src_rm;
                result = (s >> cnt) | (s << (32 - cnt));
            }
        } else ok = false;
    }

    if (!ok)
        return 0;

    /* Zero-extend 32-bit result to 64 bits (x86-64 ABI) */
    if (!v.w) result &= 0xffffffff;
    set_reg(regs, dst_reg, result);

    return 3 + 1 + mr_len + extra; /* VEX(3) + opcode(1) + ModRM... + imm */
}

/* ------------------------------------------------------------------ */
/* #UD notifier                                                          */
/* ------------------------------------------------------------------ */
static int bmi2_ud_notifier(struct notifier_block *nb,
                            unsigned long action, void *data)
{
    struct die_args *args = (struct die_args *)data;

    if (action != DIE_TRAP || args->trapnr != X86_TRAP_UD)
        return NOTIFY_DONE;

    /* Only emulate kernel-mode faults */
    if (user_mode(args->regs))
        return NOTIFY_DONE;

    u8 insn[15];
    if (copy_from_kernel_nofault(insn, (void *)args->regs->ip, sizeof(insn)))
        return NOTIFY_DONE;

    if (insn[0] != 0xc4) /* quick pre-filter: must be 3-byte VEX */
        return NOTIFY_DONE;

    int len = emulate_bmi2(insn, args->regs);
    if (len <= 0)
        return NOTIFY_DONE;

    args->regs->ip += len;
    atomic64_inc(&bmi2_emul_count);

    pr_debug_ratelimited("bmi2_emul: emulated @ %pS\n",
                         (void *)(args->regs->ip - len));
    return NOTIFY_STOP; /* consumed — do not propagate to default handler */
}

static struct notifier_block bmi2_nb = {
    .notifier_call = bmi2_ud_notifier,
    .priority      = 1000, /* run before default do_invalid_op */
};

/* ------------------------------------------------------------------ */
/* Module init / exit                                                    */
/* ------------------------------------------------------------------ */
static int __init bmi2_emul_init(void)
{
    register_die_notifier(&bmi2_nb);
    pr_info("bmi2_emul: loaded — BMI2 software emulation active\n");
    pr_info("bmi2_emul: handles MULX PDEP PEXT BZHI SARX SHRX SHLX RORX\n");
    return 0;
}

static void __exit bmi2_emul_exit(void)
{
    unregister_die_notifier(&bmi2_nb);
    pr_info("bmi2_emul: unloaded (emulated %lld instructions total)\n",
            atomic64_read(&bmi2_emul_count));
}

module_init(bmi2_emul_init);
module_exit(bmi2_emul_exit);
