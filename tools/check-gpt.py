#!/usr/bin/env python3
import argparse, binascii, os, struct, sys, uuid

SECTOR=512; ENTRY_SIZE=128; ENTRY_COUNT=128; ENTRY_BYTES=ENTRY_SIZE*ENTRY_COUNT
ESP=uuid.UUID('C12A7328-F81F-11D2-BA4B-00A0C93EC93B')
SWAP=uuid.UUID('0657FD6D-A4AB-43C4-84E5-0933C84B4F4F')
ROOT=uuid.UUID('0FC63DAF-8483-4772-8E79-3D69D8477DE4')

def crc(data): return binascii.crc32(data) & 0xffffffff

def parse_header(f,lba):
    f.seek(lba*SECTOR); raw=f.read(SECTOR)
    if len(raw)!=SECTOR or raw[:8]!=b'EFI PART': raise ValueError(f'no GPT header at LBA {lba}')
    rev,size,hcrc,reserved,current,backup,first,last=struct.unpack_from('<IIIIQQQQ',raw,8)
    if rev != 0x00010000 or not (92 <= size <= SECTOR): raise ValueError('bad GPT header revision/size')
    temp=bytearray(raw[:size]); struct.pack_into('<I',temp,16,0)
    if crc(temp)!=hcrc: raise ValueError(f'bad GPT header CRC at LBA {lba}')
    disk_guid=uuid.UUID(bytes_le=raw[56:72])
    entries_lba,count,esize,ecrc=struct.unpack_from('<QIII',raw,72)
    if count!=ENTRY_COUNT or esize!=ENTRY_SIZE: raise ValueError('unexpected GPT entry geometry')
    f.seek(entries_lba*SECTOR); entries=f.read(count*esize)
    if len(entries)!=count*esize or crc(entries)!=ecrc: raise ValueError('bad GPT partition-array CRC')
    return dict(current=current,backup=backup,first=first,last=last,guid=disk_guid,
                entries_lba=entries_lba,entries=entries,ecrc=ecrc)

def parse_entries(raw):
    out=[]
    for i in range(ENTRY_COUNT):
        e=raw[i*ENTRY_SIZE:(i+1)*ENTRY_SIZE]
        if e[:16]==b'\0'*16: continue
        typ=uuid.UUID(bytes_le=e[:16]); uniq=uuid.UUID(bytes_le=e[16:32])
        first,last,attrs=struct.unpack_from('<QQQ',e,32)
        name=e[56:128].decode('utf-16le').rstrip('\0')
        out.append((i+1,typ,uniq,first,last,attrs,name))
    return out

def check(path, expected_swap=None):
    sectors=os.path.getsize(path)//SECTOR
    if sectors < 4096: raise ValueError('image too small')
    with open(path,'rb') as f:
        mbr=f.read(SECTOR)
        if mbr[510:512]!=b'\x55\xaa' or mbr[450]!=0xEE: raise ValueError('protective MBR is missing')
        p=parse_header(f,1); b=parse_header(f,sectors-1)
        if p['current']!=1 or p['backup']!=sectors-1: raise ValueError('primary header LBA pointers are wrong')
        if b['current']!=sectors-1 or b['backup']!=1: raise ValueError('backup header LBA pointers are wrong')
        if p['guid']!=b['guid'] or p['ecrc']!=b['ecrc'] or p['entries']!=b['entries']: raise ValueError('primary/backup GPT disagree')
        entries=parse_entries(p['entries'])
        types=[x[1] for x in entries]
        want=[ESP,ROOT] if expected_swap==0 else ([ESP,SWAP,ROOT] if expected_swap else None)
        if want and types!=want: raise ValueError(f'partition types are {types}, expected {want}')
        if not entries or entries[0][3]!=2048: raise ValueError('ESP is not 1 MiB aligned')
        prev=0
        for n,typ,uniq,first,last,attrs,name in entries:
            if first>last or first<=prev: raise ValueError('overlapping/out-of-order partitions')
            if first % 2048: raise ValueError(f'partition {n} is not 1 MiB aligned')
            prev=last
        if entries[-1][4] > p['last']: raise ValueError('root extends past last usable LBA')
    return entries

def main():
    ap=argparse.ArgumentParser(); ap.add_argument('image'); ap.add_argument('--swap',type=int,choices=[0,1])
    ns=ap.parse_args()
    try: entries=check(ns.image,ns.swap)
    except Exception as e:
        print(f'GPT check failed: {e}',file=sys.stderr); return 1
    for e in entries: print(f'{e[0]} {e[1]} {e[3]}..{e[4]} {e[6]}')
    print('GPT: OK')
    return 0
if __name__=='__main__': raise SystemExit(main())
