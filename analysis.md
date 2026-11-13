# CHAINFIX V1.0 (FLEX09) — Analysis of `chainfix09.asm`

Source: `chainfix09.asm`, a DA68Sharp disassembly of `CHAINFIX.CMD`
("CHAINFIX V1.0 (c) CATERPILLAR SOFTWARE CO."), ORG `$0100`.

## 1. What the program does

CHAINFIX checks the sector chains on a FLEX disk and can rebuild the free-sector chain.

1. Asks for a drive number (0–3).
2. Builds a **file map**: one bit for every sector that is used by the system area, the directory, or any file.
3. Builds a **free map**: one bit for every sector on the free chain listed in the SIR.
4. Reports **collisions**: sectors that appear in both maps.
5. Reports **misses**: sectors that appear in neither map (lost sectors).
6. Prints the totals and asks whether to relink the free chain. If you answer **Y**, every sector that is not in the file map is written into a new ascending free chain, and the SIR is updated.

The track/sector pair is treated as a 16-bit index `T*256+S`. That gives 65,536 possible sectors, so each bitmap needs 8 KB.

## 2. Memory map

| Address | Label | Use |
|---|---|---|
| `$0100–$066B` | code/strings | Program |
| `$1000–$2FFF` | `L1000` | File bitmap (8 KB) |
| `$3000–$4FFF` | `L3000` | Free bitmap (8 KB) |
| `$5000` | `DIR_FCB` | Directory FCB (FMS 6/7). `+3` drive, `+4` name/ext, `+17` start T/S (`$5011`), `+19` end T/S (`$5013`) |
| `$5140` | `RAW_FCB` | Sector I/O FCB (FMS 9/10). `+3` drive, `+30` current T/S (`$515E`) |
| `$5180–$527F` | `SCT_BUFF` | Sector buffer (FCB+64). Bytes 0–1 hold the link |
| `$519D/$519F/$51A1` | `SIR_*` | When the SIR is loaded: start of free chain, end of free chain, free count |
| `$51A6/$51A7` | `SIR_MT_MS` | Max track / max sector |
| `$5280` | `ENDBITMAPADDR` | First holds the end of the bitmaps (`$5000`); during relink it is reused as the "previous free T/S" and the new chain head |
| `$5282` | `FS_TAIL_TS` | Tail of the new free chain |
| `$5284` | `TOTFREESECT` | Number of free sectors after relink |
| `$5286` | `BITMAPBASE` | Pointer to the active bitmap (`$1000` or `$3000`) |
| `$5288/$5289` | `MAX_TS`/`MAX_SCT` | Disk geometry from the SIR |
| `$528A` | `INTFILCNT` | Number of files that had an intersection |
| `$528C` | `COLLFLG` | Per-file flag: 1 = clean, 0 = intersection seen |
| `$528D` | `TOTINTCNT` | "Total intersections" (see §4.6) |
| `$528F` | `COLLCNT` | Counts collisions, then is reused to count misses |
| `$5291` | `PRGCNTR` | Progress counter. Prints `+` every 256 sectors |
| `$5292` | `LINWRPCNTR` | Line-wrap counter. Prints 16 T/S values per line |

All these FCB and SIR offsets match the standard FLEX 9.0 layouts (FCB is `$140` bytes and the buffer is at FCB+`$40`).

## 3. Control flow

```
MAIN
 ├─ clear $1000-$4FFF
 ├─ ask drive → DIR_FCB+3, RAW_FCB+3
 ├─ READ_SEC 00/03 (SIR) → MAX_TS
 ├─ PAD_TRK0  : mark (MaxT,MaxS+1) … $FFFF in the file map
 ├─ PAD_ALL   : on tracks 0..MaxT, mark sector 0 and sectors MaxS+1..$FF
 ├─ mark 00/01, 00/02, 00/03
 ├─ TRACE_CHAIN 00/04       (directory chain, see §4.4)
 ├─ BUILD_FILE_MAP          FMS 6, then FMS 7 in a loop, TRACE_CHAIN for each file
 ├─ BUILD_FREE_MAP          BITMAPBASE=$3000, TRACE_CHAIN from SIR free head
 ├─ CHK_COLLISIONS          file AND free
 ├─ CHK_MISSES              NOT (file OR free)
 ├─ REPORT_AND_FIX          print totals, ask Y/N, relink, rewrite SIR
 └─ JMP WARMS
```

### Key routines

- **`SET_BIT`** converts the T/S in D to a byte (`D>>3`) and a bit mask (`1<<(D&7)`) in the active map. It sets the bit and returns **Z=1 if the bit was clear before**. All registers except CC are preserved. This works correctly.
- **`TRACE_CHAIN`** follows the links from the T/S in D until it reaches link `00/00`. It marks each sector as it goes. If a sector is already marked, it prints `Intersection at - TTSS`, clears `COLLFLG`, **and keeps following the chain**. After it returns, `RAW_FCB+30` (`LST_TS`) holds the last sector it read. `BUILD_FILE_MAP` compares this value with the end T/S in the directory, which is a neat trick.
- **`PRT_BITS`** prints a T/S for each set bit in A. The base T/S is in X. It also counts each printed value in `COLLCNT` and wraps the line every 16 values. Its stack use (`,S` = mask, `1,S` = counter) is correct, and it preserves Y and U for the scan loops that call it.
- **Relink** walks the T/S space from `MAX_TS` down to `$0001`. Each sector that is not in the file map is zero-filled, its link is set to the sector found before it (the next higher free sector), and it is written to disk. The result is an ascending chain. The head (the lowest sector) and the tail (the highest sector) go into the SIR. This matches FLEX conventions.

## 4. Bugs and problems (most severe first)

### 4.1 CRITICAL — `CHK_COLLISIONS` branches back to its own entry point (line 219)

```asm
                   LBSR      PRT_BITS
                   BRA       CHK_COLLISIONS         ; binary: 20 CC
```

I checked the byte offset. The `BRA` is at `$02A5` and the next instruction is at `$02A7`. Offset `$CC` (−52) jumps to `$0273`, which is `CHK_COLLISIONS`. `COL_LOOP` is at `$0295`, which would need offset `$EE`. So the disassembly matches the binary. The binary itself is wrong.

**Effect:** when the first file/free collision is found, the routine starts over. It prints the heading again, resets `COLLCNT`, resets U/Y/X, finds the same collision again, and repeats forever. Any disk that actually has a file/free overlap hangs the program before the report, so you can never use the relink that would fix it. The same routine in `CHK_MISSES` correctly uses `BRA MISS_LOOP`.

`$EE` becoming `$CC` is two flipped bits (bit 5 and bit 1). That looks like a corrupted copy of the binary rather than the original author's intent.

**Fix:** `BRA COL_LOOP`.

### 4.2 HIGH — A looped chain makes `TRACE_CHAIN` run forever

When `TRACE_CHAIN` finds an intersection, it reports it and then follows the link anyway. That is fine for a cross-link (file B joining the tail of file A), because the trace ends when A ends. But if any chain loops back on itself, through a file or through the free chain, the program prints `Intersection at` forever. A looped chain is a common kind of damage, and catching it is exactly what this tool is for.

**Fix:** stop the trace when a collision is found (set `LST_TS` or a flag and `RTS`). Another option is to stop after a sector count limit.

### 4.3 HIGH — A bad link stops the whole program

`READ_SEC` and `WRITE_SEC` call `RPTERR` and then `JMP WARMS` on any FMS error. Damaged links will cause such errors, for example a track above `MaxTrack`, sector 0, or a sector above `MaxSector`:

- In the **file map**, those sectors are already marked by the padding. The bad link is first reported as an "Intersection", and then the read fails and the program exits.
- In the **free map**, there is no padding, so the program just exits with a disk error.

In both cases you get no report and no chance to relink.

**Fix:** check each link against `MAX_TS` before reading it. If it is out of range, report "bad link" and end that chain.

### 4.4 HIGH — A full disk (empty free chain) stops the program

`BUILD_FREE_MAP` passes the SIR free-chain head straight to `TRACE_CHAIN`. If the disk has no free sectors, the head is `00/00`. `TRACE_CHAIN` does not test for zero on entry, so it calls `READ_SEC 00/00`. That sector does not exist, so FLEX reports an error and the program exits. (`BUILD_FILE_MAP` avoids this for empty files with its `BEQ CHK_END_TS` test.)

**Fix:** in `BUILD_FREE_MAP`, skip the trace when D = 0. Better still, add the zero test at the top of `TRACE_CHAIN`.

### 4.5 HIGH (data safety) — The directory is found by assuming sector 00/04 links to 00/05

Lines 110–111 call `TRACE_CHAIN` from `00/04`. In FLEX, the directory starts at `00/05`, and sector 4 is normally unused. This code only marks the directory if sector 4's link field points to `00/05`. NEWDISK usually leaves it that way, because it links every sector on the disk in order. The comment "Backup SIR / System" is misleading: this call actually traces the **directory chain**.

If sector 4's link is `00/00` or anything else, none of the directory sectors get marked. They then show up as misses, and **a Y relink puts the directory sectors on the free chain. The next file written destroys the directory.**

**Fix:** mark `00/04` on its own and call `TRACE_CHAIN` from `00/05`.

### 4.6 MEDIUM — Track 0 geometry on double-density disks

The padding uses one `MaxSector` value for every track. On DD disks where track 0 is formatted single density (fewer sectors), the track 0 sectors that do not exist are not marked. They are reported as misses, and relink tries to write them. That write fails, and the program exits partway through the relink (see §4.7).

### 4.7 MEDIUM — Relink is not atomic

Relink writes the free sectors from the highest down, and **only then** rewrites the SIR. If it stops partway (a write error, reset, or power loss), the old SIR still points into sectors whose links have been rewritten. The free chain is then inconsistent and can be worse than before. Relink also zero-fills every free and lost sector, so any data in lost sectors is gone for good. There is no "recover lost chains to a file" option.

### 4.8 MEDIUM — Relink is offered even when files are cross-linked

Relink uses only the file map. That fixes free/file collisions (the sector stays with the file) and recovers misses. But file/file cross-links are left as they are. Also, a file whose chain was cut short by a premature `00/00` has its orphaned tail freed. The prompt gives no warning about this.

### 4.9 LOW — "Total number of intersections" mixes units (line 223)

```asm
COL_DONE  LDD  COLLCNT     ; file/free collisions (number of sectors)
          ADDD INTFILCNT   ; number of FILES that had an intersection
```

The comment says "intra-file collisions", but `INTFILCNT` counts files, not sectors. The number of sectors in file/file (or file/system) intersections is never counted, so this total adds two different things together.

### 4.10 LOW — `FS_TAIL_TS` is never initialised

`$5282` is outside the cleared area (`$1000–$4FFF`). If relink finds no free sectors, `SIR_END_FC` gets whatever value was left in memory. The start and count are correctly 0.

**Fix:** clear it next to `TOTFREESECT`.

### 4.11 LOW — The bitmap scans skip the last byte

The `COL_LOOP` and `MISS_LOOP` loops stop when X = `$FFF8`, before processing the byte for `$FFF8–$FFFF`. They therefore scan only 8191 of the 8192 bytes. In practice this does not matter, because those sectors are padding unless MaxTrack = MaxSector = `$FF`.

### 4.12 LOW — No check of the drive number input

The carry flag returned by `INDEC` is ignored. An empty or non-numeric entry is taken as drive 0, and there is no confirmation before the program writes to the disk.

### 4.13 LOW — Checks the program does not do

- The trace's last sector is not compared with `SIR_END_FC`, and the trace length is not compared with `SIR_FS_CNT`. These checks would be easy to add, in the same way the file end check is done.
- The sector count in each directory entry (FCB+21) is not checked.
- Only drives 0–3 are allowed.

## 5. Problems with the source and assembler

| Line(s) | Problem |
|---|---|
| 100, 142, 418 | Leftover control-table text in the comments (`track01AB,    67,B,…`, `04B6,   100,E,`, `,0,E,`). Remove it. |
| 375, 399, 446, 488, 505 | `PULS …,PCR` — many 6809 assemblers only accept `PC` in a register list. |
| throughout | 6800-style mnemonics (`LDAA`, `STAB`, `ORAB`, `ANDA` …). These need an assembler with 6800 compatibility. Otherwise use `LDA`/`STB`/`ORB`. |
| 46, 49, 53 | Extended addressing (`>ENDBITMAPADDR`, `>BITMAPBASE`), while every other access uses `,PCR`. This works at ORG `$0100`. If the code were moved, these three would point at the absolute address while everything else moved with the code. Check against the binary and make them consistent. |
| 82–87 | The comment says "Track 0". In fact `PAD_TRK0` starts at (MaxTrack, MaxSector+1) and carries on through `$FFFF`, which marks **everything past the end of the disk**. It stops when the 16-bit value wraps to `$0000`. |
| 110 | "Backup SIR / System". See §4.5. This is the start of the directory chain. |
| 223 | The comment is wrong. See §4.9. |
| 251 | `SEC_TALLY` does not exist. The counter is `COLLCNT`. |
| 297, 305, 309, 330 | `ENDBITMAPADDR` is reused as "previous free T/S / chain head". Give it a second EQU name (for example `PREV_TS EQU $5280`) to make this clear. |
| 30 | Typo: "uffer". |
| 520 | `INCORECT` is the original program's spelling. Keep it if you want a byte-identical rebuild. |

## 6. Recommended minimal patch set

```asm
* 4.1 collision loop
                   BRA       COL_LOOP

* 4.4 / 4.2 / 4.3  safer TRACE_CHAIN
TRACE_CHAIN        CLR       >PRGCNTR,PCR
TC_LOOP            CMPD      #$0000
                   BEQ       TC_RTS                 empty chain
                   CMPA      >MAX_TS,PCR
                   BHI       TC_BAD                 track out of range
                   TSTB
                   BEQ       TC_BAD                 sector 0
                   CMPB      >MAX_SCT,PCR
                   BHI       TC_BAD                 sector out of range
                   BSR       SET_BIT
                   BEQ       TC_READ
                   ...report intersection...
                   BRA       TC_RTS                 stop: avoids loops
TC_READ            ...
TC_RTS             RTS
TC_BAD             ...report bad link, CLR COLLFLG...
                   RTS

* 4.5 directory
                   LDD       #$0004
                   LBSR      SET_BIT
                   LDD       #$0005
                   LBSR      TRACE_CHAIN

* 4.10
                   STD       >FS_TAIL_TS,PCR        (with TOTFREESECT clear)
```

When the trace stops at an intersection, `LST_TS` is the colliding sector rather than the end of the chain. So the "File end INCORECT" message will also appear for files with intersections. That is acceptable, and arguably more informative.

If you need a byte-identical rebuild of the original `.CMD`, keep line 219 as it is. Apply these fixes only to a V1.1.

## 7. Summary

The overall design (two 64K-bit maps, AND for collisions, NOR for misses, and a relink built from the file map) is sound, and most of the helper code is correct. As shipped, though, the program **hangs on the exact problem it reports** (file/free collisions, §4.1). It also **hangs on looped chains** (§4.2), **exits on bad links or a full disk** (§4.3, §4.4), and **can free the directory** if sector 00/04 is not linked to 00/05 (§4.5). Fix §4.1–§4.5 before running relink on a disk you care about.

## 8. Findings from `hdflex2.dsk`

Running the C port (`chainfix.c`) on this image confirmed two of the risks described above:

- **Sector 00/04 has link `00/00`.** The original program would therefore not mark the 251-sector directory chain at all (§4.5). Every directory sector would be counted as a miss, and a Y relink would put the directory on the free chain.
- **Sector 00/06, entry 0, is a never-used entry, and 56 live files come after it.** The original stops at the first never-used entry (`PROC_ENTRY: BEQ DIR_DONE`), so it would see only 10 of the 66 files. The other 56 files' sectors would be reported as misses, and relink would **free them**.

Apart from that, the image is consistent: 62,878 free sectors, no collisions and no misses.
