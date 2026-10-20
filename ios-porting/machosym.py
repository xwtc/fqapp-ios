"""Read the symbols out of a Mach-O image or a classic ar archive.

Why this exists: the runner's `nm` cannot read Rust 1.99.1 objects (LLVM 23
DWARF vs Xcode's LLVM 17 reader), and `grep -a` on a 94 MB archive conflates
"absent" with "unreadable". Both failure modes look like a clean zero.

This parser only uses bytes.count and struct.unpack_from on the documented
Mach-O / ar layouts, so a zero is a real zero.

Exit codes:
    0  ran to completion (and, with --require-frb, found an frb* symbol)
    2  --require-frb was given and no frb* symbol exists
"""

import struct
import sys

MAGIC64 = 0xfeedfacf
MAGIC32 = 0xfeedface
FAT_BE = (0xcafebabe, 0xcafebabf)
LC_SYMTAB = 0x2
AR_MAGIC = b'!<arch>\n'


def macho_syms(buf, base=0):
    """Return externally visible, defined symbol names of one Mach-O image."""
    if len(buf) - base < 28:
        return None
    magic = struct.unpack_from('<I', buf, base)[0]
    if magic == MAGIC64:
        is64, hdr = True, 32
    elif magic == MAGIC32:
        is64, hdr = False, 28
    else:
        return None
    ncmds = struct.unpack_from('<I', buf, base + 16)[0]
    off = base + hdr
    out = []
    for _ in range(ncmds):
        if off + 8 > len(buf):
            break
        cmd, cmdsize = struct.unpack_from('<II', buf, off)
        if cmdsize < 8:
            break
        if cmd == LC_SYMTAB and off + 24 <= len(buf):
            symoff, nsyms, stroff, _strsize = struct.unpack_from('<IIII', buf, off + 8)
            entsz = 16 if is64 else 12
            for i in range(nsyms):
                p = base + symoff + i * entsz
                if p + entsz > len(buf):
                    break
                if is64:
                    strx, ntype, _nsect, _ndesc, _nval = struct.unpack_from('<IBBhQ', buf, p)
                else:
                    strx, ntype, _nsect, _ndesc, _nval = struct.unpack_from('<IBBhI', buf, p)
                # N_STAB debug entries (0xe0 mask) are not linkable symbols;
                # N_EXT must be set; N_UNDF means the symbol is imported, not
                # defined here. Only external defined symbols matter to us.
                if ntype & 0xe0:
                    continue
                if not ntype & 0x01:
                    continue
                if (ntype & 0x0e) == 0x00:
                    continue
                s = base + stroff + strx
                if s >= len(buf):
                    continue
                e = buf.find(b'\x00', s)
                if e < 0:
                    continue
                out.append(buf[s:e].decode('utf-8', 'replace'))
        off += cmdsize
    return out


def ar_members(data):
    """Return [(name, body_offset, size)] for a classic ar archive."""
    if not data.startswith(AR_MAGIC):
        return None
    pos, out = 8, []
    while pos + 60 <= len(data):
        hdr = data[pos:pos + 60]
        if hdr[58:60] != b'`\n':
            break
        name = hdr[0:16].decode('ascii', 'replace').strip()
        try:
            size = int(hdr[48:58].decode('ascii').strip())
        except ValueError:
            break
        body = pos + 60
        if name.startswith('#1/'):
            try:
                nlen = int(name[3:])
            except ValueError:
                nlen = 0
            name = data[body:body + nlen].decode('utf-8', 'replace').rstrip('\x00')
            body += nlen
            size -= nlen
        out.append((name, body, size))
        pos = body + size
        if size % 2:
            pos += 1
    return out


def symdef_names(buf):
    """Parse a ranlib __.SYMDEF table: repeated (uint32 len, name bytes)."""
    names = []
    pos = 0
    while pos + 4 <= len(buf):
        (n,) = struct.unpack_from('<I', buf, pos)
        pos += 4
        if n == 0 or n > 4096 or pos + n > len(buf):
            break
        names.append(buf[pos:pos + n].rstrip(b'\x00').decode('utf-8', 'replace'))
        pos += n
    return names


def report_archive(data, members, want):
    print('  format: ar archive, %d member(s)' % len(members))
    print('  first members: %s' % ', '.join(m[0] for m in members[:4]))

    # The ranlib index is the archive's own declaration of what it exports.
    # The linker resolves against exactly this, so it is the most decisive
    # artifact here and is independent of any nm/LLVM version mismatch.
    index = [m for m in members if 'SYMDEF' in m[0]]
    index_names = []
    if index:
        name, body, size = index[0]
        index_names = symdef_names(data[body:body + size])
        frb_index = sorted(n for n in index_names if 'frb' in n)
        print('  ranlib index "%s": %d entries, %d mention frb'
              % (name, len(index_names), len(frb_index)))
        for n in frb_index:
            print('    %s' % n)
        # A stripped index is empty; showing real entries separates
        # "stripped" from "my parser is wrong".
        print('  index sample: %s'
              % (', '.join(index_names[:8]) if index_names else '(empty)'))
    else:
        print('  ranlib index: ABSENT (archive has no __.SYMDEF)')

    hits, macho = {}, 0
    not_macho = []
    for name, body, size in members:
        syms = macho_syms(data[body:body + size])
        if syms is None:
            if size >= 4:
                not_macho.append((name, data[body:body + 4].hex()))
            continue
        macho += 1
        for s in syms:
            if 'frb' in s:
                hits.setdefault(s, []).append(name)
    print('  Mach-O object members: %d of %d' % (macho, len(members)))
    if not_macho:
        # Not Mach-O means LTO emitted LLVM bitcode, or the member is an index.
        # 'bc c0 de' is bitcode; a Mach-O header starts 0xcffaedfe (LE cffaedfe
        # reads as cffaedfe bytes) so anything else here is worth naming.
        print('  non-Mach-O members: %d (first 5: %s)'
              % (len(not_macho),
                 ', '.join('%s[%s]' % (n[:28], h) for n, h in not_macho[:5])))
    print('  distinct frb* symbols in object symbol tables: %d' % len(hits))
    for s in sorted(hits):
        print('    %s  (%d member(s), e.g. %s)' % (s, len(hits[s]), hits[s][0]))
    for w in want:
        print('  objects contain %-30s -> %d' % (w, len(hits.get(w, []))))

    # Dump the head of the crate's own object: the single fastest way to tell
    # a Mach-O object (fe ed fa cf) from LTO bitcode (de c0 17 0b) from a
    # stripped-to-nothing member.
    for name, body, size in members:
        if 'fqapi_core' in name and size > 32:
            print('  crate object "%s" head: %s'
                  % (name, data[body:body + 32].hex()))
            break
    return bool(hits)


def report_macho(data):
    syms = macho_syms(data)
    if syms is None:
        print('  format: neither Mach-O nor ar')
        return False
    frb = sorted(s for s in syms if 'frb' in s)
    print('  format: Mach-O image')
    print('  external defined symbols: %d' % len(syms))
    print('  external defined frb*: %d' % len(frb))
    for s in frb:
        print('    %s' % s)
    return bool(frb)


def report_fat(data, n):
    print('  format: fat binary, %d slice(s)' % n)
    found = False
    for i in range(n):
        o = 8 + i * 20
        if o + 20 > len(data):
            break
        cpu, _cpusub, off, size, _align = struct.unpack_from('>iiIII', data, o)
        syms = macho_syms(data, off) or []
        frb = sorted(s for s in syms if 'frb' in s)
        print('  slice %d cputype=%d off=%d size=%d -> %d frb* symbol(s)'
              % (i, cpu, off, size, len(frb)))
        for s in frb:
            print('    %s' % s)
        found = found or bool(frb)
    return found


def scan(path, want):
    try:
        data = open(path, 'rb').read()
    except OSError as exc:
        print('SKIP %s (%s)' % (path, exc))
        return False
    print('')
    print('=== %s ===' % path)
    print('  bytes: %d' % len(data))
    for probe in want:
        print('  raw substring %-32s -> %d' % (probe, data.count(probe.encode())))
    # A mangled Rust symbol proves the symbol table survived whatever ran.
    # If _ZN is present but no frb_ is, the frb_ functions are genuinely
    # absent rather than unreadable.
    print('  raw substring %-32s -> %d' % ('_ZN (mangled)', data.count(b'_ZN')))
    if len(data) >= 8 and struct.unpack_from('>I', data, 0)[0] in FAT_BE:
        return report_fat(data, struct.unpack_from('>I', data, 4)[0])
    members = ar_members(data)
    if members is not None:
        return report_archive(data, members, want)
    return report_macho(data)


def main(argv):
    want = [a[len('--want='):] for a in argv if a.startswith('--want=')]
    require = '--require-frb' in argv
    paths = [a for a in argv if not a.startswith('--')]
    if not paths:
        print('usage: machosym.py [--require-frb] [--want=SYM]... PATH...')
        return 1
    found = False
    for p in paths:
        if scan(p, want):
            found = True
    print('')
    if require and not found:
        print('VERDICT: FAIL - no frb* symbol in any scanned artifact')
        return 2
    print('VERDICT: %s' % ('frb* symbols found' if found else 'none found'))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
