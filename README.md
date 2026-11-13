# chainfix
<<<<<<< HEAD

chainfix checks the sector chains on FLEX disk images under Linux and can rebuild the free-sector chain. It is a C version of **CHAINFIX V1.0** (Caterpillar Software Co.), a FLEX09 utility for the 6809. The original program had bugs that could hang it or damage a disk. This version fixes them.

## What it does

A FLEX disk links its sectors together in chains. Each file is one chain, the directory is a chain, and all the unused sectors form the *free chain*. The disk's system information record (SIR, track 0 sector 3) records where the free chain starts and ends and how many sectors it holds.

chainfix makes two maps of the disk:

1. **File map.** This covers the system sectors (00/01–00/04), the directory chain (from 00/05), and the chain of every file in the directory.
2. **Free map.** This covers every sector on the free chain listed in the SIR.

It then reports:

| Check | Meaning |
|---|---|
| **Intersections** | A file chain runs into another file, the directory or the system area (a *cross-link*), or loops back on itself |
| **Bad links** | A link points to a sector that does not exist (track beyond the last one, sector 0, or sector beyond the last one) |
| **Bad end / count** | The last sector or the sector count in the directory entry does not match the file's chain |
| **Free chain problems** | The free chain's end or count does not match the SIR, or the free chain loops or has a bad link |
| **Collisions** | A sector is in a file *and* in the free chain |
| **Misses** | A sector is in neither map. Space has been lost. |

Optionally, it **relinks the free chain**. Every valid sector that is not in the file map becomes part of a new free chain in ascending order, and the SIR is updated. This fixes collisions (the file keeps the sector) and recovers lost sectors.

## Building

Any C99 compiler works. The program has no dependencies.

```sh
make            # or: cc -O2 -Wall -o chainfix chainfix.c
```

## Usage

```
chainfix [options] image.dsk
  -n          report only, never relink
  -y          relink without asking
  -F          allow relink even if file chains are damaged
  -o FILE     write the relinked image to FILE (default: in place)
  -z          zero-fill free sectors when relinking (as original)
  -0 N        track 0 has N sectors (default: auto)
  -q          quiet: only print problems and totals
  -s          strict FLEX directory: stop at first never-used entry
```

Examples:

```sh
./chainfix -n hdflex2.dsk                 # check only
./chainfix hdflex2.dsk                    # check, then ask "Relink the free chain (Y/N)"
./chainfix -y -o fixed.dsk damaged.dsk    # relink to a new image, no prompt
./chainfix -q -n *.dsk                    # quick check, problems and totals only
```

### Exit status

| Code | Meaning |
|---|---|
| 0 | Disk is consistent |
| 1 | Problems were found (also returned after a successful relink) |
| 2 | Error: unreadable file, unknown geometry, out of memory, write failure |

### Example output

```
CHAINFIX (Linux) - damaged.dsk
Volume HDFLEX2 #1, tracks 0-254, sectors 1-255

Building the file map.
  directory: 251 sectors
  (directory end marker at 0006 entry 0)
  ED.CMD       0818-086B    84 sectors
  ABASIC.CMD   0101-0124    36 sectors
  ABASIC.CMD: chain loops back to 0102 (from 0105)
  ...
Building the free map.
  free chain: 62878 sectors
Checking for collisions.
Checking for misses.
0106 0107 0108 0109 010A 010B 010C 010D 010E 010F 0110 0111 0112 0113 0114 0115
0116 0117 0118 0119 011A 011B 011C 011D 011E 011F 0120 0121 0122 0123 0124

Files                          - 66
Free sectors (chain)           - 62878
Total number files intersected - 1
  cross-linked / looped        - 0 / 1
Files with bad links           - 0
Files with bad end / count     - 0 / 0
Free chain problems            - 0
File/free collisions (sectors) - 0
Total number of missed sectors - 31
```

This example is a copy of `hdflex2.dsk` in which one sector of `ABASIC.CMD` was changed to link back into the same file. The 31 sectors after the loop are no longer reachable, so they are reported as missed. The output ends with a warning about the 56 directory entries that come after the end marker.

Track/sector addresses are printed in hex as `TTSS`, 16 to a line, as in the original. Counts are printed in decimal.

## Disk image format

chainfix reads **raw** images: a plain dump of 256-byte sectors with no header. Track 0 comes first, and each track's sectors are numbered from 1. This is the usual `.dsk` format for FLEX emulators.

- The disk size is read from the SIR (max track at offset `$26`, max sector at offset `$27`).
- If the image has fewer sectors than the SIR describes, chainfix assumes track 0 has fewer sectors than the other tracks (as on double-density disks with a single-density track 0) and works out the count from the file size. You can also give it with `-0 N`.
- Extra data after the last sector is ignored, with a warning.

Images with a header, such as FLEXemu `.FLX`, are not supported. Remove the header first.

## Safety

The image is only written when you relink, and you are asked first unless you give `-y`.

- **Atomic write.** The relink is done in memory and saved to a temporary file in the same directory, which then replaces the image (or the `-o` file). If chainfix is interrupted or a write fails, the original image is left as it was.
- **Relink is refused when file chains are damaged.** If any file has a bad link or an intersection, or the directory chain is damaged, part of a file may be missing from the file map. Relinking would then free sectors that still hold that file's data. Repair or delete the files first, or use `-F` if you accept that risk.
- **No prompt without a terminal.** If standard input is not a terminal, chainfix will not relink unless you give `-y`.
- **Lost data is not recovered.** Relinking puts missed sectors back on the free chain. By default only the link bytes and the record number bytes (bytes 0–3) of each free sector are rewritten. With `-z`, the whole sector is zeroed, as in the original.
- **Gaps in the directory.** FLEX treats the first never-used directory entry as the end of the directory. On damaged disks there can be live entries after it. chainfix scans the whole directory chain and prints a warning, so those files' sectors are never freed. Use `-s` for the strict FLEX behaviour.

Keep a backup of any image you care about before relinking.

## Differences from the original CHAINFIX

The 6809 original is in `chainfix09.asm`, a disassembly of `t/CHAINFIX.CMD`. See [`analysis.md`](analysis.md) for the full review. This version fixes the following:

| Original behaviour | chainfix |
|---|---|
| Collision check branches back to its own start (`BRA $0273`), so it hangs on the first file/free collision | Scans once |
| A looping chain is followed forever | Stops at the first sector already seen and reports it |
| A bad link causes a disk error and exits to FLEX | Reported, and that chain ends there |
| An empty free chain (full disk) reads sector 00/00 and exits | Handled |
| The directory is found through sector 00/04's link, which is `00/00` on `hdflex2.dsk` | Traced directly from 00/05 |
| Stops at the first never-used directory entry | Scans the whole directory and warns |
| End of the new free chain is left uninitialised when there are no free sectors | Set to 00/00 |
| The last 8 sectors of the 64K sector range are not scanned | Every sector is scanned |
| Relink writes sector by sector, then the SIR | Written all at once (see Safety) |
| "Total intersections" adds a sector count to a file count | Each count is reported separately |
| Drives 0–3 only | Any image file |

These checks are new:
- each file's sector count against its directory entry;
- the free chain's end and count against the SIR;
- names of the files involved in each intersection and collision;
- refusal to relink a disk with damaged file chains.

## Files

| File | Description |
|---|---|
| `chainfix.c` | Linux source |
| `Makefile` | Build |
| `analysis.md` | Analysis of the original 6809 program |
| `chainfix09.asm` | Commented disassembly of the original |
| `t/` | Original `CHAINFIX.CMD`, `CHAINFIX.DOC`, and the disassembler's input and output files |
| `hdflex2.dsk` | Sample hard-disk image (255 tracks × 255 sectors) |
=======
Fixes Flex file system chain link issues on disk image under Linux
>>>>>>> 423164014d1f019cf6fcc04c6d9e4946894c04d6
