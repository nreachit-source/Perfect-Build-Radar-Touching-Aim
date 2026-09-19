from pathlib import Path
import struct

data = Path(r"C:\Users\GAME\Desktop\BUILD\iphone_ue4_monitor\build_codex\radar_overlay.dylib").read_bytes()

# Find Mach-O 64 load commands
magic = struct.unpack_from("<I", data, 0)[0]
ncmds = struct.unpack_from("<I", data, 16)[0]
sizeofcmds = struct.unpack_from("<I", data, 20)[0]
offset = 32

symtab_offset = 0
symtab_num = 0
strtab_offset = 0

for _ in range(ncmds):
    cmd, size = struct.unpack_from("<II", data, offset)
    if cmd == 2: # LC_SYMTAB
        symtab_offset, symtab_num, strtab_offset, strtab_size = struct.unpack_from("<IIII", data, offset + 8)
    offset += size

print(f"symtab_num: {symtab_num}")
strtab = data[strtab_offset:strtab_offset+strtab_size]

for i in range(symtab_num):
    str_idx, n_type, n_sect, n_desc, n_value = struct.unpack_from("<IBBHQ", data, symtab_offset + i * 16)
    name = strtab[str_idx:strtab.find(b'\0', str_idx)].decode(errors='ignore')
    if "sincos" in name:
        print(f"Symbol: {name}, value: {hex(n_value)}, sect: {n_sect}, type: {n_type}")
