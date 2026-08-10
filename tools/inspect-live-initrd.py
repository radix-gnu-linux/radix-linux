#!/usr/bin/env python3
import pathlib,sys
p=pathlib.Path(sys.argv[1]); b=p.read_bytes(); off=0; archives=0; names=[]
def align(n): return (4-(n%4))%4
while off+110 <= len(b):
    if b[off:off+6] != b'070701':

        if b[off] == 0: off += 1; continue
        raise SystemExit(f'bad newc magic at {off}')
    h=b[off:off+110]; off+=110
    vals=[int(h[6+i*8:14+i*8],16) for i in range(13)]
    mode=vals[1]; size=vals[6]; namesz=vals[11]
    raw=b[off:off+namesz]; off+=namesz; off+=align(110+namesz)
    name=raw[:-1].decode('utf-8','strict')
    data=b[off:off+size]; off+=size; off+=align(size)
    if name=='TRAILER!!!': archives+=1; continue
    if name.startswith('/') or '/..' in '/'+name or name=='..': raise SystemExit('unsafe path: '+name)
    names.append(name.lstrip('./'))
required=['init','radix-live/core/installer/setup-radix.lua','radix-live/sbin/setup-radix','radix-live/bin/radix','radix-live/packages/ports/catalog.toml','root/.profile','radix-live/boot/BOOTX64.EFI']
missing=[x for x in required if x not in names]
if missing: raise SystemExit('live initrd missing: '+', '.join(missing))
if archives < 2: raise SystemExit('expected Radix base archive + live overlay')
print(f'live initrd: {archives} cpio archives, {len(names)} records: OK')
