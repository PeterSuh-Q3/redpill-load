"""
patch_bmi2.py — Replace BMI2 (SHLX/SHRX/SARX) instructions in Synology
zImage with CALL trampolines so the kernel boots on Ivy Bridge / J4125.

Trampoline area: 0xCC padding at vaddr=0xffffffff818014aa (elf+0xa014aa), ~2MB.
Each BMI2 instruction is replaced by:
  CALL rel32  [+ NOP padding to fill original instruction length]
The trampoline at the target:
  1. Emulates the BMI2 semantics using legacy SHL/SHR/SAR + CL
  2. RET back
"""

import re, struct, sys, shutil, os

# ---------- ELF helpers ----------

def u32(b, o): return struct.unpack_from("<I", b, o)[0]
def u64(b, o): return struct.unpack_from("<Q", b, o)[0]
def s32(b, o): return struct.unpack_from("<i", b, o)[0]

# ---------- x86-64 encoder helpers ----------

REG = dict(RAX=0,RCX=1,RDX=2,RBX=3,RSP=4,RBP=5,RSI=6,RDI=7,
           R8=8,R9=9,R10=10,R11=11,R12=12,R13=13,R14=14,R15=15,
           EAX=0,ECX=1,EDX=2,EBX=3,ESP=4,EBP=5,ESI=6,EDI=7,
           R8D=8,R9D=9,R10D=10,R11D=11,R12D=12,R13D=13,R14D=14,R15D=15)

def push_r(r):
    return bytes([0x41, 0x50 + (r-8)]) if r >= 8 else bytes([0x50 + r])

def pop_r(r):
    return bytes([0x41, 0x58 + (r-8)]) if r >= 8 else bytes([0x58 + r])

def mov_rr(dst, src, W):
    """MOV dst, src  (W=1 → 64-bit, W=0 → 32-bit, zero-extends)"""
    if dst == src:
        return b""
    need_rex = W or dst >= 8 or src >= 8
    rex = 0x40 | (W << 3) | ((src >= 8) << 2) | (dst >= 8)
    modrm = 0xC0 | ((src & 7) << 3) | (dst & 7)
    if need_rex:
        return bytes([rex, 0x89, modrm])
    return bytes([0x89, modrm])

def mov_r_mem(dst, base, mod, disp, W):
    """MOV dst, [base+disp] (mod: 0=no disp, 1=disp8, 2=disp32)"""
    rex_w = W
    rex_r = dst >= 8
    rex_b = base >= 8
    rex = 0x40 | (rex_w << 3) | (rex_r << 2) | rex_b
    modrm = (mod << 6) | ((dst & 7) << 3) | (base & 7)

    buf = bytearray()
    if rex != 0x40 or rex_w:
        buf.append(rex)
    buf.append(0x8B)

    # SIB for base=RSP(4)/R12(12)
    if (base & 7) == 4:
        buf.append(modrm)
        buf.append(0x24)          # SIB: scale=0, index=4(none), base=4
    else:
        buf.append(modrm)

    if mod == 1:
        buf.append(disp & 0xFF)
    elif mod == 2:
        buf += struct.pack("<i", disp)
    return bytes(buf)

def mov_cl_reg(src):
    """MOV CL, src_low_byte  (src is reg index 0-15)"""
    if src == 1:
        return b""  # CL already has value from RCX
    if src < 4:
        # AL/DL/BL accessible without REX
        modrm = 0xC0 | (src << 3) | 1   # reg=src, rm=CL(1)
        return bytes([0x88, modrm])
    elif src < 8:
        # BPL/SPL/SIL/DIL need empty REX=40
        modrm = 0xC0 | (src << 3) | 1
        return bytes([0x40, 0x88, modrm])
    else:
        # R8B-R15B: use 8A r8,r/m8 with REX.B
        # CL=dst(reg=1), srcB=rm  (REX.B extends rm)
        modrm = 0xC0 | (1 << 3) | (src & 7)  # reg=CL, rm=src&7
        return bytes([0x41, 0x8A, modrm])

def shift_cl(mnem, dst, W):
    """SHL/SHR/SAR dst, CL"""
    ext = {"SHLX": 4, "SHRX": 5, "SARX": 7}[mnem]
    if W:
        rex = 0x48 | (dst >= 8)
        modrm = 0xC0 | (ext << 3) | (dst & 7)
        return bytes([rex, 0xD3, modrm])
    else:
        if dst >= 8:
            modrm = 0xC0 | (ext << 3) | (dst & 7)
            return bytes([0x41, 0xD3, modrm])
        else:
            modrm = 0xC0 | (ext << 3) | dst
            return bytes([0xD3, modrm])

def make_trampoline(info):
    """
    Build trampoline bytes for one BMI2 instruction.
    info = {mnem, W, dst_idx, src_is_mem, src_idx, count_idx,
            mem_mod, mem_disp}
    Semantics: dst = src <shift_by> (count & mask)
    """
    mnem     = info["mnem"]
    W        = info["W"]
    dst      = info["dst_idx"]
    src_mem  = info["src_is_mem"]
    src      = info["src_idx"]      # ignored if src_mem
    count    = info["count_idx"]
    mem_mod  = info.get("mem_mod", 0)
    mem_disp = info.get("mem_disp", 0)

    code = bytearray()

    # CASE A: count register IS CX (CL already correct)
    if count == 1:
        # Load src → dst, then shift dst, CL
        if not src_mem:
            code += mov_rr(dst, src, W)
        else:
            code += mov_r_mem(dst, src, mem_mod, mem_disp, W)
        code += shift_cl(mnem, dst, W)

    # CASE B: count register IS dst (dst == count, count != CX)
    elif count == dst and not src_mem:
        # e.g. SHLX RAX, RBX, RAX  or  SHLX RAX, RAX, RAX
        # CL must hold count BEFORE overwriting dst
        code += push_r(1)              # PUSH RCX (save)
        code += mov_cl_reg(count)      # MOV CL, count_low (from original dst)
        if src != dst:
            code += mov_rr(dst, src, W)   # dst = src
        code += shift_cl(mnem, dst, W)
        code += pop_r(1)               # POP RCX (restore)

    elif count == dst and src_mem:
        # e.g. SHLX EAX, [RDI+8], EAX
        code += push_r(1)
        code += mov_cl_reg(count)
        code += mov_r_mem(dst, src, mem_mod, mem_disp, W)
        code += shift_cl(mnem, dst, W)
        code += pop_r(1)

    # CASE C: dst == CX (1), count != CX
    elif dst == 1 and count != 1:
        # Can't use PUSH/POP RCX (it IS our destination)
        # Use RAX(0) as scratch
        code += push_r(0)              # PUSH RAX
        if not src_mem:
            code += mov_rr(0, src, W)  # MOV RAX, src
        else:
            code += mov_r_mem(0, src, mem_mod, mem_disp, W)
        code += mov_cl_reg(count)      # MOV CL, count_low (CL = part of RCX = our dst)
        code += shift_cl(mnem, 0, W)   # SHL RAX, CL
        code += mov_rr(1, 0, W)        # MOV RCX, RAX
        code += pop_r(0)               # POP RAX

    # CASE D: general case (dst != CX, count != CX, count != dst)
    else:
        # Save RCX, set CL = count, load src → dst, shift, restore RCX
        code += push_r(1)              # PUSH RCX
        code += mov_cl_reg(count)      # MOV CL, count_low
        if not src_mem:
            code += mov_rr(dst, src, W)
        else:
            code += mov_r_mem(dst, src, mem_mod, mem_disp, W)
        code += shift_cl(mnem, dst, W)
        code += pop_r(1)               # POP RCX

    code += bytes([0xC3])              # RET
    return bytes(code)

# ---------- VEX-3 BMI2 decoder ----------

def decode_bmi2(buf):
    """Return dict with decoded BMI2 info, or None."""
    if buf[0] != 0xC4:
        return None
    b1, b2, op = buf[1], buf[2], buf[3]
    R    = 1 - ((b1 >> 7) & 1)
    X    = 1 - ((b1 >> 6) & 1)
    B    = 1 - ((b1 >> 5) & 1)
    mmap = b1 & 0x1f
    W    = (b2 >> 7) & 1
    vvvv = (~b2 >> 3) & 0xf
    L    = (b2 >> 2) & 1
    pp   = b2 & 3

    BMI2 = {(2,2,0xF7):"SARX",(2,3,0xF7):"SHRX",(2,1,0xF7):"SHLX",
            (2,0,0xF7):"BZHI",(2,2,0xF5):"PEXT",(2,3,0xF5):"PDEP",
            (2,2,0xF6):"MULX",(3,2,0xF0):"RORX"}
    mnem = BMI2.get((mmap, pp, op))
    if not mnem:
        return None

    modrm = buf[4]
    mod   = modrm >> 6
    reg   = ((modrm >> 3) & 7) | (R << 3)
    rm    = (modrm & 7) | (B << 3)

    # Operands: dst=reg, count=vvvv, src=rm
    # (for SHRX/SHLX/SARX; MULX/PDEP/PEXT differ but not in our data)
    length = 5
    mem_mod = mem_disp = 0
    src_is_mem = False

    if mod == 3:
        src_is_mem = False
        src_idx = rm
    else:
        src_is_mem = True
        src_idx = rm  # base register
        if (rm & 7) == 4:  # SIB byte
            length += 1
        if mod == 1:
            mem_disp = struct.unpack_from("b", buf, length)[0]
            length += 1
        elif mod == 2:
            mem_disp = struct.unpack_from("<i", buf, length)[0]
            length += 4
        elif mod == 0 and (rm & 7) == 5:  # RIP-relative
            mem_disp = struct.unpack_from("<i", buf, length)[0]
            length += 4
        mem_mod = mod

    if mnem == "RORX":
        length += 1  # imm8

    return dict(mnem=mnem, W=W, dst_idx=reg, src_is_mem=src_is_mem,
                src_idx=src_idx, count_idx=vvvv,
                mem_mod=mem_mod, mem_disp=mem_disp,
                length=length)

# ---------- Main patcher ----------

IN  = "/tmp/p1/zImage"
OUT = "/tmp/zImage-patched"

shutil.copy2(IN, OUT)
data = bytearray(open(OUT, "rb").read())

# Locate ELF payload
setup_sects     = data[0x1f1]
kernel_offset   = (setup_sects + 1) * 512
payload_off_rel = u32(data, 0x248)
payload_start   = kernel_offset + payload_off_rel

elf_base = payload_start  # offset of ELF within zImage file

# Parse ELF
elf = memoryview(data)[elf_base:]
e_phoff = u64(elf, 0x20)
e_phnum = struct.unpack_from("<H", elf, 0x38)[0]

# Find segments
segs = []
for i in range(e_phnum):
    b = e_phoff + i*56
    pt    = u32(elf, b)
    pflg  = u32(elf, b+4)
    poff  = u64(elf, b+8)
    pvaddr= u64(elf, b+16)
    pfsz  = u64(elf, b+32)
    if pt == 1:
        segs.append((pvaddr, poff, pfsz, pflg))

# EXEC segment (.text)
exec_seg = next(s for s in segs if s[3] & 1)
text_vaddr, text_foff_elf, text_fsz, _ = exec_seg
text_foff_z = elf_base + text_foff_elf   # offset within zImage file

print("text: vaddr=0x%016x  zImage_offset=0x%08x  size=0x%08x" % (
      text_vaddr, text_foff_z, text_fsz))

# Trampoline area: large int3 block
TRAMP_VADDR  = 0xffffffff818014aa
TRAMP_FOFF_Z = elf_base + 0x00a014aa   # elf+0xa014aa → within first PT_LOAD
TRAMP_MAX    = 2091862

print("trampoline area: vaddr=0x%016x  zImage_offset=0x%08x  max=%d bytes" % (
      TRAMP_VADDR, TRAMP_FOFF_Z, TRAMP_MAX))

# Scan first 64KB of .text for BMI2
bmi2_pat = re.compile(b"\xc4[\xe2\xe3][\x00-\xff][\xf0\xf5\xf6\xf7]")
region = bytes(data[text_foff_z:text_foff_z + 65536])
hits = list(bmi2_pat.finditer(region))
print("BMI2 hits in first 64KB: %d\n" % len(hits))

tramp_ptr = TRAMP_FOFF_Z   # current write pointer in trampoline area (zImage file offset)
tramp_vptr = TRAMP_VADDR

patch_log = []

for m in hits:
    rel_off  = m.start()                    # offset within scanned region
    z_off    = text_foff_z + rel_off        # offset within zImage file
    site_va  = text_vaddr + rel_off         # virtual address of the instruction

    buf = region[rel_off:rel_off+16]
    info = decode_bmi2(buf)
    if not info:
        print("SKIP (decode failed) at 0x%016x" % site_va)
        continue

    insn_len = info["length"]

    # Build trampoline
    try:
        tramp_bytes = make_trampoline(info)
    except Exception as e:
        print("SKIP (trampoline failed) at 0x%016x: %s" % (site_va, e))
        continue

    # Check trampoline fits in area
    if tramp_ptr + len(tramp_bytes) > TRAMP_FOFF_Z + TRAMP_MAX:
        print("ERROR: trampoline area full at 0x%016x" % site_va)
        sys.exit(1)

    # Write trampoline
    data[tramp_ptr:tramp_ptr + len(tramp_bytes)] = tramp_bytes

    # CALL rel32 = E8 + (tramp_vptr - (site_va + 5)) as int32
    rel32 = (tramp_vptr - (site_va + 5)) & 0xFFFFFFFF
    # Verify it fits in int32
    rel32_signed = struct.unpack("<i", struct.pack("<I", rel32))[0]

    call_bytes = bytearray([0xE8]) + struct.pack("<i", rel32_signed)
    # Pad remainder with NOPs
    nops = bytes([0x90]) * (insn_len - 5)
    patch = call_bytes + nops

    data[z_off:z_off + insn_len] = patch

    patch_log.append((site_va, insn_len, info["mnem"],
                      tramp_vptr, len(tramp_bytes),
                      region[rel_off:rel_off+insn_len].hex(),
                      patch.hex()))

    print("PATCHED 0x%016x  %-5s  insn=%dB  tramp_at=0x%016x  tramp=%dB" % (
          site_va, info["mnem"], insn_len, tramp_vptr, len(tramp_bytes)))
    print("  orig: %-20s → call+nop: %s" % (
          region[rel_off:rel_off+insn_len].hex(), patch.hex()))

    tramp_ptr  += len(tramp_bytes)
    tramp_vptr += len(tramp_bytes)

# Write output
with open(OUT, "wb") as f:
    f.write(data)

print("\n=== SUMMARY ===")
print("Patched %d instructions" % len(patch_log))
print("Trampoline bytes used: %d / %d" % (tramp_ptr - TRAMP_FOFF_Z, TRAMP_MAX))
print("Output: %s" % OUT)

# Verify patches
verify = open(OUT, "rb").read()
for va, ln, mn, tva, tsz, orig_hex, patch_hex in patch_log:
    z = text_foff_z + (va - text_vaddr)
    actual = verify[z:z+ln].hex()
    ok = actual == patch_hex
    print("  [%s] 0x%016x  %-5s  %s" % ("OK" if ok else "FAIL", va, mn, actual))
