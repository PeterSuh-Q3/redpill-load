"""
patch_andn.py — Patch BMI1 ANDN instructions (C4 E2 xx F2 /r) in entire EXEC segment.
Input : /tmp/p3b/zImage-dsm  (already has BMI2 3176 patches, MD5: 8070725d...)
Output: /tmp/zImage-andnpatched

ANDN dst, src1, src2  →  dst = (~src1) & src2
  VEX3: C4 [R~X~B~ 00010] [W ~vvvv~ L 00] F2 ModRM [SIB] [disp]
  dst  = ModRM.reg (+ R)
  src1 = vvvv (inverted)
  src2 = ModRM.r/m (+ B)
  W=1 → 64-bit, W=0 → 32-bit
"""

import re, struct, sys, shutil, os, hashlib

def u32(b, o): return struct.unpack_from("<I", b, o)[0]
def u64(b, o): return struct.unpack_from("<Q", b, o)[0]

# ---- register helpers (same as patch_bmi2_full.py) ----
def push_r(r):
    return bytes([0x41, 0x50+(r-8)]) if r>=8 else bytes([0x50+r])
def pop_r(r):
    return bytes([0x41, 0x58+(r-8)]) if r>=8 else bytes([0x58+r])

def mov_rr(dst, src, W):
    if dst == src: return b""
    rex = 0x40 | (W<<3) | ((src>=8)<<2) | (dst>=8)
    modrm = 0xC0 | ((src&7)<<3) | (dst&7)
    return bytes([rex, 0x89, modrm])

def not_r(r, W):
    """NOT r  (single register)"""
    if W:
        rex = 0x48 | (r >= 8)
        return bytes([rex, 0xF7, 0xD0 | (r & 7)])
    else:
        if r >= 8:
            return bytes([0x41, 0xF7, 0xD0 | (r & 7)])
        else:
            return bytes([0xF7, 0xD0 | r])

def and_rr(dst, src, W):
    """AND dst, src"""
    rex = 0x40 | (W<<3) | ((dst>=8)<<2) | (src>=8)
    modrm = 0xC0 | ((dst&7)<<3) | (src&7)
    return bytes([rex, 0x23, modrm])

def and_r_mem(dst, base, mod, disp, W):
    """AND dst, [base+disp]  (0x23 /r)"""
    rex = 0x40 | (W<<3) | ((dst>=8)<<2) | (base>=8)
    modrm = (mod<<6) | ((dst&7)<<3) | (base&7)
    buf = bytearray()
    if rex != 0x40 or W: buf.append(rex)
    buf.append(0x23)
    if (base&7) == 4: buf.append(modrm); buf.append(0x24)
    else:             buf.append(modrm)
    if   mod == 1: buf.append(disp & 0xFF)
    elif mod == 2: buf += struct.pack("<i", disp)
    elif mod == 0 and (base&7) == 5: buf += struct.pack("<i", disp)
    return bytes(buf)

def decode_andn(buf):
    """Decode ANDN VEX instruction, return dict or None."""
    if buf[0] != 0xC4: return None
    b1, b2, op = buf[1], buf[2], buf[3]
    if op != 0xF2: return None
    mmap = b1 & 0x1f
    if mmap != 2: return None          # must be 0F38 map
    pp = b2 & 3
    if pp != 0: return None            # ANDN: no prefix (pp=00)
    R = 1 - ((b1>>7)&1)
    B = 1 - ((b1>>5)&1)
    W = (b2>>7)&1
    vvvv = (~b2>>3) & 0xf              # src1 register
    modrm = buf[4]
    mod = modrm >> 6
    reg  = ((modrm>>3)&7) | (R<<3)    # dst
    rm   = (modrm&7)      | (B<<3)    # src2 base / reg
    length = 5
    mem_mod = mem_disp = 0
    src2_is_mem = False
    if mod == 3:
        src2_is_mem = False
        src2_idx = rm
    else:
        src2_is_mem = True
        src2_idx = rm
        if (rm&7) == 4: length += 1   # SIB byte
        if   mod == 1: mem_disp = struct.unpack_from("b", buf, length)[0]; length += 1
        elif mod == 2: mem_disp = struct.unpack_from("<i", buf, length)[0]; length += 4
        elif mod == 0 and (rm&7) == 5: mem_disp = struct.unpack_from("<i", buf, length)[0]; length += 4
        mem_mod = mod
    return dict(W=W, dst=reg, src1=vvvv,
                src2_is_mem=src2_is_mem, src2=src2_idx,
                mem_mod=mem_mod, mem_disp=mem_disp, length=length)

def make_andn_trampoline(info):
    """
    ANDN dst, src1, src2  →  dst = (~src1) & src2

    Strategy: pick a temp register != dst, src1, src2(if reg)
      push tmp
      mov  tmp, src1
      not  tmp
      and  tmp, src2   (src2 may be mem)
      mov  dst, tmp
      pop  tmp
      ret

    Special case: dst == tmp (impossible since we pick tmp != dst)
    Special case: src1 == tmp handled by mov_rr before NOT
    """
    W    = info["W"]
    dst  = info["dst"]
    src1 = info["src1"]
    src2_is_mem = info["src2_is_mem"]
    src2 = info["src2"]
    mem_mod  = info.get("mem_mod", 0)
    mem_disp = info.get("mem_disp", 0)

    # Pick temp register: avoid dst, src1, and src2(if reg)
    used_regs = {dst, src1}
    if not src2_is_mem:
        used_regs.add(src2)
    # RSP(4) is off-limits
    used_regs.add(4)
    tmp = None
    for r in [0, 1, 2, 3, 5, 6, 7, 8, 9, 10, 11]:
        if r not in used_regs:
            tmp = r
            break
    if tmp is None:
        raise RuntimeError("No free register for ANDN trampoline: used=%s" % used_regs)

    code = bytearray()
    code += push_r(tmp)
    code += mov_rr(tmp, src1, W)   # tmp = src1
    code += not_r(tmp, W)           # tmp = ~src1
    if not src2_is_mem:
        code += and_rr(tmp, src2, W)    # tmp &= src2
    else:
        code += and_r_mem(tmp, src2, mem_mod, mem_disp, W)  # tmp &= [mem]
    code += mov_rr(dst, tmp, W)    # dst = tmp
    code += pop_r(tmp)
    code += bytes([0xC3])
    return bytes(code)

# ---- main ----
IN  = "/tmp/p3b/zImage-dsm"    # full-patched (BMI2 3176 done)
OUT = "/tmp/zImage-andnpatched"
shutil.copy2(IN, OUT)
data = bytearray(open(OUT, "rb").read())

setup_sects   = data[0x1f1]
kernel_offset = (setup_sects+1)*512
payload_off   = u32(data, 0x248)
elf_base      = kernel_offset + payload_off

elf = memoryview(data)[elf_base:]
e_phoff = u64(elf, 0x20)
e_phnum = struct.unpack_from("<H", elf, 0x38)[0]

text_vaddr = text_foff_elf = text_fsz = None
for i in range(e_phnum):
    b = e_phoff + i*56
    if u32(elf, b)==1 and u32(elf, b+4)&1:
        text_vaddr   = u64(elf, b+16)
        text_foff_elf= u64(elf, b+8)
        text_fsz     = u64(elf, b+32)
        break
text_foff_z = elf_base + text_foff_elf
print("text: vaddr=0x%016x  size=0x%08x" % (text_vaddr, text_fsz))

# Trampoline area (reuse same 2MB 0xCC block)
TRAMP_VADDR  = 0xffffffff818014aa
TRAMP_FOFF_Z = elf_base + 0x00a014aa
TRAMP_MAX    = 2091862

# Resume after previous patches (28812 bytes used)
TRAMP_USED_PREV = 28812
tramp_ptr  = TRAMP_FOFF_Z + TRAMP_USED_PREV
tramp_vptr = TRAMP_VADDR  + TRAMP_USED_PREV

# Verify trampoline boundary
assert data[tramp_ptr] == 0xCC, "Trampoline not clear at expected position: 0x%02x" % data[tramp_ptr]
print("Trampoline resume at foff=0x%x, vaddr=0x%016x" % (tramp_ptr, tramp_vptr))

# Scan full segment for ANDN (C4 E2 xx F2)
region = bytes(data[text_foff_z:text_foff_z+text_fsz])
pat = re.compile(b"\xc4\xe2[\x00-\xff]\xf2")
hits = list(pat.finditer(region))
print("ANDN candidates found: %d" % len(hits))

ok = fail = skip = 0
for m in hits:
    rel_off = m.start()
    z_off   = text_foff_z + rel_off
    site_va = text_vaddr  + rel_off
    buf     = region[rel_off:rel_off+16]
    info    = decode_andn(buf)
    if not info:
        skip += 1
        continue
    insn_len = info["length"]
    if insn_len < 5:
        print("  SKIP short insn at 0x%016x len=%d" % (site_va, insn_len))
        skip += 1
        continue
    try:
        tb = make_andn_trampoline(info)
    except Exception as e:
        print("  SKIP trampoline error at 0x%016x: %s" % (site_va, e))
        skip += 1
        continue
    if tramp_ptr + len(tb) > TRAMP_FOFF_Z + TRAMP_MAX:
        print("ERROR: trampoline area full at 0x%016x" % site_va)
        sys.exit(1)
    data[tramp_ptr:tramp_ptr+len(tb)] = tb
    rel32 = struct.unpack("<i", struct.pack("<I", (tramp_vptr-(site_va+5))&0xFFFFFFFF))[0]
    patch = bytearray([0xE8]) + struct.pack("<i", rel32) + bytes([0x90])*(insn_len-5)
    data[z_off:z_off+insn_len] = patch
    tramp_ptr  += len(tb)
    tramp_vptr += len(tb)
    ok += 1

with open(OUT, "wb") as f: f.write(data)

# Verify
verify = open(OUT, "rb").read()
seg = verify[text_foff_z:text_foff_z+text_fsz]
remaining = len(list(pat.finditer(seg)))

print("\n=== RESULT ===")
print("Patched ANDN  : %d" % ok)
print("Skipped       : %d" % skip)
print("Trampoline used total: %d bytes" % (tramp_ptr - TRAMP_FOFF_Z))
print("ANDN remaining in segment: %d (should be 0)" % remaining)
print("Output MD5:", hashlib.md5(open(OUT,"rb").read()).hexdigest())
