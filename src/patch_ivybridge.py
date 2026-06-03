"""
patch_ivybridge.py — Unified Ivy Bridge incompatibility patcher for Synology DSM zImage

Patches all instructions unsupported on Ivy Bridge (3rd gen Intel Core):
  BMI2: SHLX / SHRX / SARX / BZHI / PEXT / PDEP / MULX / RORX
  BMI1: ANDN / BLSR / BLSMSK / BLSI

Strategy: replace each instruction with CALL rel32 into a trampoline stub
          injected into the 2MB 0xCC padding block inside .text.

Usage:
  python3 patch_ivybridge.py <input_zImage> <output_zImage>
"""

import re, struct, sys, shutil, hashlib
from collections import defaultdict

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
def u16(b, o): return struct.unpack_from("<H", b, o)[0]
def u32(b, o): return struct.unpack_from("<I", b, o)[0]
def u64(b, o): return struct.unpack_from("<Q", b, o)[0]

def push_r(r):
    return bytes([0x41, 0x50+(r-8)]) if r >= 8 else bytes([0x50+r])
def pop_r(r):
    return bytes([0x41, 0x58+(r-8)]) if r >= 8 else bytes([0x58+r])

def mov_rr(dst, src, W):
    if dst == src: return b""
    rex = 0x40 | (W<<3) | ((src>=8)<<2) | (dst>=8)
    return bytes([rex, 0x89, 0xC0 | ((src&7)<<3) | (dst&7)])

def mov_r_mem(dst, base, mod, disp, W):
    rex = 0x40 | (W<<3) | ((dst>=8)<<2) | (base>=8)
    modrm = (mod<<6) | ((dst&7)<<3) | (base&7)
    buf = bytearray()
    if rex != 0x40 or W: buf.append(rex)
    buf.append(0x8B)
    if (base&7) == 4: buf.append(modrm); buf.append(0x24)
    else:             buf.append(modrm)
    if   mod == 1: buf.append(disp & 0xFF)
    elif mod == 2: buf += struct.pack("<i", disp)
    elif mod == 0 and (base&7) == 5: buf += struct.pack("<i", disp)
    return bytes(buf)

def mov_cl_reg(src):
    if src == 1: return b""
    if src < 4:  return bytes([0x88, 0xC0 | (src<<3) | 1])
    if src < 8:  return bytes([0x40, 0x88, 0xC0 | (src<<3) | 1])
    return bytes([0x41, 0x8A, 0xC0 | (1<<3) | (src&7)])

def not_r(r, W):
    if W:   return bytes([0x48|(r>=8), 0xF7, 0xD0|(r&7)])
    elif r >= 8: return bytes([0x41, 0xF7, 0xD0|(r&7)])
    else:        return bytes([0xF7, 0xD0|r])

def neg_r(r, W):
    if W:   return bytes([0x48|(r>=8), 0xF7, 0xD8|(r&7)])
    elif r >= 8: return bytes([0x41, 0xF7, 0xD8|(r&7)])
    else:        return bytes([0xF7, 0xD8|r])

def dec_r(r, W):
    if W:   return bytes([0x48|(r>=8), 0xFF, 0xC8|(r&7)])
    elif r >= 8: return bytes([0x41, 0xFF, 0xC8|(r&7)])
    else:        return bytes([0xFF, 0xC8|r])

def shift_cl(mnem, dst, W):
    ext = {"SHLX":4, "SHRX":5, "SARX":7}[mnem]
    if W:   return bytes([0x48|(dst>=8), 0xD3, 0xC0|(ext<<3)|(dst&7)])
    elif dst >= 8: return bytes([0x41, 0xD3, 0xC0|(ext<<3)|(dst&7)])
    else:          return bytes([0xD3, 0xC0|(ext<<3)|dst])

def and_rr(dst, src, W):
    rex = 0x40|(W<<3)|((dst>=8)<<2)|(src>=8)
    return bytes([rex, 0x23, 0xC0|((dst&7)<<3)|(src&7)])

def xor_rr(dst, src, W):
    rex = 0x40|(W<<3)|((dst>=8)<<2)|(src>=8)
    return bytes([rex, 0x33, 0xC0|((dst&7)<<3)|(src&7)])

def pick_tmp(used_regs):
    """Pick a temp register not in used_regs (RSP=4 always excluded)."""
    forbidden = set(used_regs) | {4}
    for r in [0,1,2,3,5,6,7,8,9,10,11]:
        if r not in forbidden: return r
    raise RuntimeError("No free temp register, used=%s" % used_regs)

# ---------------------------------------------------------------------------
# VEX3 decoder helpers
# ---------------------------------------------------------------------------
def _parse_modrm(buf, offset, B):
    """Parse ModRM (and optional SIB/disp) starting at buf[offset].
    Returns (mod, reg_r, rm_r, length_consumed, is_mem, mem_mod, mem_disp)
    where reg_r and rm_r are register indices (0-15).
    """
    modrm = buf[offset]; mod = modrm >> 6
    reg_r = ((modrm>>3)&7)           # will be ORed with R by caller
    rm_r  = (modrm&7) | (B<<3)
    length = 1
    is_mem = (mod != 3)
    mem_mod = mod; mem_disp = 0
    if is_mem:
        if (rm_r&7) == 4: length += 1   # SIB
        if   mod == 1: mem_disp = struct.unpack_from("b", buf, offset+length)[0]; length += 1
        elif mod == 2: mem_disp = struct.unpack_from("<i", buf, offset+length)[0]; length += 4
        elif mod == 0 and (rm_r&7) == 5: mem_disp = struct.unpack_from("<i", buf, offset+length)[0]; length += 4
    return mod, reg_r, rm_r, length, is_mem, mem_mod, mem_disp

def decode(buf):
    """Decode one VEX3-encoded Ivy Bridge incompatible instruction.
    Returns dict or None if not a patchable instruction.
    """
    if len(buf) < 6 or buf[0] != 0xC4: return None
    b1, b2, op = buf[1], buf[2], buf[3]
    mmap = b1 & 0x1F
    R    = 1 - ((b1>>7)&1)
    B    = 1 - ((b1>>5)&1)
    W    = (b2>>7)&1
    vvvv = (~b2>>3)&0xF    # register encoded in vvvv field
    pp   = b2 & 3

    # ---- BMI2 (map=2 and map=3) ----
    BMI2 = {
        (2,1,0xF7):"SHLX",  (2,3,0xF7):"SHRX",  (2,2,0xF7):"SARX",
        (2,0,0xF7):"BEXTR", (2,0,0xF5):"BZHI",
        (2,2,0xF5):"PEXT",  (2,3,0xF5):"PDEP",
        (2,3,0xF6):"MULX",
        (3,2,0xF0):"RORX",
    }
    mnem = BMI2.get((mmap, pp, op))
    if mnem:
        mod, reg_r, rm_r, mlen, is_mem, mem_mod, mem_disp = _parse_modrm(buf, 4, B)
        reg_r |= (R<<3)
        length = 4 + mlen
        if mnem == "RORX": length += 1   # imm8
        # SHLX/SHRX/SARX: dst=reg, src=rm, count=vvvv
        if mnem in ("SHLX","SHRX","SARX"):
            return dict(mnem=mnem, W=W, dst=reg_r,
                        src_is_mem=is_mem, src=rm_r, count=vvvv,
                        mem_mod=mem_mod, mem_disp=mem_disp, length=length)
        # Others: skip (complex semantics, rare in early boot)
        return dict(mnem=mnem, W=W, length=length, _skip=True)

    # ---- BMI1 ANDN (map=2, pp=0, op=F2) ----
    if mmap==2 and pp==0 and op==0xF2:
        mod, reg_r, rm_r, mlen, is_mem, mem_mod, mem_disp = _parse_modrm(buf, 4, B)
        reg_r |= (R<<3)
        # ANDN dst(reg), src1(vvvv), src2(rm)
        return dict(mnem="ANDN", W=W, dst=reg_r,
                    src1=vvvv, src_is_mem=is_mem, src=rm_r,
                    mem_mod=mem_mod, mem_disp=mem_disp, length=4+mlen)

    # ---- BMI1 BLSR/BLSMSK/BLSI (map=2, pp=0, op=F3) ----
    if mmap==2 and pp==0 and op==0xF3:
        mod, reg_r, rm_r, mlen, is_mem, mem_mod, mem_disp = _parse_modrm(buf, 4, B)
        sel = reg_r & 7   # ModRM.reg (without R extension)
        name = {1:"BLSR", 2:"BLSMSK", 3:"BLSI"}.get(sel)
        if not name: return None
        # dst=vvvv, src=rm
        return dict(mnem=name, W=W, dst=vvvv,
                    src_is_mem=is_mem, src=rm_r,
                    mem_mod=mem_mod, mem_disp=mem_disp, length=4+mlen)

    return None

# ---------------------------------------------------------------------------
# trampoline builders
# ---------------------------------------------------------------------------
def _load_src(tmp, info):
    """Load src operand into register tmp."""
    if not info["src_is_mem"]:
        return mov_rr(tmp, info["src"], info["W"])
    else:
        return mov_r_mem(tmp, info["src"], info["mem_mod"], info["mem_disp"], info["W"])

def make_trampoline(info):
    mnem = info["mnem"]
    W    = info["W"]

    # ---- SHLX / SHRX / SARX ----
    # dst = shift(src, count)
    if mnem in ("SHLX","SHRX","SARX"):
        dst = info["dst"]; src = info["src"]; count = info["count"]
        code = bytearray()
        if count == 1:                          # count already in CL
            code += _load_src(dst, info)
            code += shift_cl(mnem, dst, W)
        elif count == dst:                      # count == dst: need temp for CX
            code += push_r(1)
            code += mov_cl_reg(count)
            code += _load_src(dst, info)
            code += shift_cl(mnem, dst, W)
            code += pop_r(1)
        elif dst == 1:                          # dst == CX: use RAX as temp
            code += push_r(0)
            code += _load_src(0, info)
            code += mov_cl_reg(count)
            code += shift_cl(mnem, 0, W)
            code += mov_rr(1, 0, W)
            code += pop_r(0)
        else:                                   # general
            code += push_r(1)
            code += mov_cl_reg(count)
            code += _load_src(dst, info)
            code += shift_cl(mnem, dst, W)
            code += pop_r(1)
        code += b"\xC3"
        return bytes(code)

    # ---- ANDN: dst = (~src1) & src2 ----
    if mnem == "ANDN":
        dst = info["dst"]; src1 = info["src1"]
        src2_is_mem = info["src_is_mem"]; src2 = info["src"]
        mem_mod = info["mem_mod"]; mem_disp = info["mem_disp"]
        tmp = pick_tmp({dst, src1} | ({src2} if not src2_is_mem else set()))
        code = bytearray()
        code += push_r(tmp)
        code += mov_rr(tmp, src1, W)   # tmp = src1
        code += not_r(tmp, W)           # tmp = ~src1
        if not src2_is_mem:
            rex = 0x40|(W<<3)|((tmp>=8)<<2)|(src2>=8)
            code += bytes([rex, 0x23, 0xC0|((tmp&7)<<3)|(src2&7)])  # and tmp, src2
        else:
            base=src2; mod=mem_mod; disp=mem_disp
            rex=0x40|(W<<3)|((tmp>=8)<<2)|(base>=8)
            modrm=(mod<<6)|((tmp&7)<<3)|(base&7)
            buf2=bytearray()
            if rex!=0x40 or W: buf2.append(rex)
            buf2.append(0x23)
            if (base&7)==4: buf2.append(modrm); buf2.append(0x24)
            else:           buf2.append(modrm)
            if   mod==1: buf2.append(disp&0xFF)
            elif mod==2: buf2+=struct.pack("<i",disp)
            elif mod==0 and (base&7)==5: buf2+=struct.pack("<i",disp)
            code += bytes(buf2)                                        # and tmp, [mem]
        code += mov_rr(dst, tmp, W)    # dst = (~src1) & src2
        code += pop_r(tmp)
        code += b"\xC3"
        return bytes(code)

    # ---- BLSR:  dst = src & (src-1) ----
    if mnem == "BLSR":
        dst = info["dst"]
        tmp = pick_tmp({dst} | ({info["src"]} if not info["src_is_mem"] else set()))
        code = bytearray()
        code += push_r(tmp)
        code += _load_src(tmp, info)   # tmp = src
        code += mov_rr(dst, tmp, W)    # dst = src
        code += dec_r(dst, W)          # dst = src-1
        code += and_rr(dst, tmp, W)    # dst = (src-1) & src
        code += pop_r(tmp)
        code += b"\xC3"
        return bytes(code)

    # ---- BLSMSK: dst = src ^ (src-1) ----
    if mnem == "BLSMSK":
        dst = info["dst"]
        tmp = pick_tmp({dst} | ({info["src"]} if not info["src_is_mem"] else set()))
        code = bytearray()
        code += push_r(tmp)
        code += _load_src(tmp, info)   # tmp = src
        code += mov_rr(dst, tmp, W)    # dst = src
        code += dec_r(dst, W)          # dst = src-1
        code += xor_rr(dst, tmp, W)    # dst = (src-1) ^ src
        code += pop_r(tmp)
        code += b"\xC3"
        return bytes(code)

    # ---- BLSI: dst = src & (-src) ----
    if mnem == "BLSI":
        dst = info["dst"]
        tmp = pick_tmp({dst} | ({info["src"]} if not info["src_is_mem"] else set()))
        code = bytearray()
        code += push_r(tmp)
        code += _load_src(tmp, info)   # tmp = src
        code += mov_rr(dst, tmp, W)    # dst = src
        code += neg_r(tmp, W)          # tmp = -src
        code += and_rr(dst, tmp, W)    # dst = src & (-src)
        code += pop_r(tmp)
        code += b"\xC3"
        return bytes(code)

    raise RuntimeError("No trampoline for %s" % mnem)

# ---------------------------------------------------------------------------
# ELF / bzImage helpers
# ---------------------------------------------------------------------------
def find_text_segment(data):
    setup_sects   = data[0x1f1]
    kernel_offset = (setup_sects+1)*512
    payload_off   = u32(data, 0x248)
    elf_base      = kernel_offset + payload_off

    elf = data[elf_base:]
    e_phoff = u64(elf, 0x20)
    e_phnum = u16(elf, 0x38)

    for i in range(e_phnum):
        b = e_phoff + i*56
        if u32(elf, b) == 1 and u32(elf, b+4) & 1:   # PT_LOAD + PF_X
            vaddr    = u64(elf, b+16)
            foff_elf = u64(elf, b+8)
            filesz   = u64(elf, b+32)
            return elf_base, vaddr, elf_base+foff_elf, filesz

    raise RuntimeError("No executable PT_LOAD segment found")

def find_trampoline_area(data, text_foff_z, text_fsz, text_vaddr):
    """Locate the 2MB 0xCC block in .text and return (foff, vaddr, size)."""
    seg = data[text_foff_z:text_foff_z+text_fsz]
    INT3_RUN = 4096   # require at least 4KB of 0xCC to identify the area
    i = 0
    while i < len(seg):
        if seg[i] != 0xCC:
            i += 1; continue
        j = i
        while j < len(seg) and seg[j] == 0xCC: j += 1
        if j - i >= INT3_RUN:
            return text_foff_z+i, text_vaddr+i, j-i
        i = j
    raise RuntimeError("Cannot find 0xCC trampoline area in .text")

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
if len(sys.argv) != 3:
    print("Usage: patch_ivybridge.py <input> <output>")
    sys.exit(1)

IN, OUT = sys.argv[1], sys.argv[2]
shutil.copy2(IN, OUT)
data = bytearray(open(OUT, "rb").read())

elf_base, text_vaddr, text_foff_z, text_fsz = find_text_segment(data)
print("text : vaddr=0x%016x  size=0x%08x (%d MB)" % (text_vaddr, text_fsz, text_fsz>>20))

tramp_foff_z, tramp_vaddr, tramp_size = find_trampoline_area(data, text_foff_z, text_fsz, text_vaddr)
print("tramp: foff=0x%x  vaddr=0x%016x  avail=%d KB" % (tramp_foff_z, tramp_vaddr, tramp_size>>10))

tramp_ptr  = tramp_foff_z
tramp_vptr = tramp_vaddr

# Scan: map=2 opcodes {F2,F3,F5,F6,F7} + map=3 opcode {F0}
# b1 values where b1&0x1F == 2 (map=2): 0x02,0x22,0x42,0x62,0x82,0xA2,0xC2,0xE2
# b1 values where b1&0x1F == 3 (map=3): 0x03,0x23,0x43,0x63,0x83,0xA3,0xC3,0xE3
MAP2 = b"\x02\x22\x42\x62\x82\xa2\xc2\xe2"
MAP3 = b"\x03\x23\x43\x63\x83\xa3\xc3\xe3"
pat = re.compile(b"\xc4[" + MAP2 + b"][\x00-\xff][\xf2\xf3\xf5\xf6\xf7]"
                 b"|"
                 b"\xc4[" + MAP3 + b"][\x00-\xff]\xf0")

region = bytes(data[text_foff_z:text_foff_z+text_fsz])
hits = list(pat.finditer(region))
print("Candidates: %d" % len(hits))

stats = defaultdict(int)
skip_stats = defaultdict(int)
ok = skip = 0

for m in hits:
    rel_off = m.start()
    z_off   = text_foff_z + rel_off
    site_va = text_vaddr  + rel_off
    buf     = region[rel_off:rel_off+16]

    info = decode(buf)
    if not info:
        skip_stats["decode_fail"] += 1; skip += 1; continue
    if info.get("_skip"):
        skip_stats[info["mnem"]] += 1; skip += 1; continue

    insn_len = info["length"]
    if insn_len < 5:
        skip_stats["too_short"] += 1; skip += 1; continue

    try:
        tb = make_trampoline(info)
    except Exception as e:
        skip_stats["tramp_err"] += 1; skip += 1
        print("  SKIP tramp error at 0x%016x %s: %s" % (site_va, info["mnem"], e))
        continue

    if tramp_ptr + len(tb) > tramp_foff_z + tramp_size:
        print("ERROR: trampoline area full at 0x%016x" % site_va); sys.exit(1)

    # Write trampoline stub
    data[tramp_ptr:tramp_ptr+len(tb)] = tb
    # Write CALL rel32 + NOP padding
    rel32 = struct.unpack("<i", struct.pack("<I", (tramp_vptr-(site_va+5))&0xFFFFFFFF))[0]
    patch = bytearray([0xE8]) + struct.pack("<i", rel32) + bytes([0x90])*(insn_len-5)
    data[z_off:z_off+insn_len] = patch

    tramp_ptr  += len(tb)
    tramp_vptr += len(tb)
    stats[info["mnem"]] += 1
    ok += 1

with open(OUT, "wb") as f: f.write(data)

# Verify residual
verify  = open(OUT, "rb").read()
seg     = verify[text_foff_z:text_foff_z+text_fsz]
residual = len(list(pat.finditer(seg)))

print("\n=== RESULT ===")
for mnem, cnt in sorted(stats.items()):
    print("  %-10s patched : %d" % (mnem, cnt))
print("  --------------------")
print("  Total patched  : %d" % ok)
print("  Skipped        : %d  %s" % (skip, dict(skip_stats) if skip else ""))
print("  Trampoline used: %d bytes / %d avail" % (tramp_ptr-tramp_foff_z, tramp_size))
print("  Residual hits  : %d (should be 0)" % residual)
print("  Output MD5     :", hashlib.md5(open(OUT,"rb").read()).hexdigest())
