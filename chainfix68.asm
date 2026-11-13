*
* CHAINFIX V1.0 - FLEX (6800) Disk Chain Diagnostic & Free-Chain Repair
*
* Translated from the 6809 FLEX09 version (chainfix09.asm) to the
* 6800 and FLEX 2.0 (6800).
*
* Translation notes
*
*  - The 6800 has no D, Y or U registers, no PC-relative addressing,
*    no LEAX, no TFR and no long branches. 16-bit Track/Sector (T/S)
*    values are carried in A (track) and B (sector), like the 6809 D
*    register. Pointers that were in Y/U are kept in memory.
*  - All FLEX entry points are the 6800 FLEX addresses ($AD00 DOS,
*    $B400 FMS, $AC00 system variables). These are the 6809 FLEX
*    addresses minus $2000.
*  - The data areas are at the same addresses as in the 6809 version.
*    The program needs RAM up to about $52C0.
*  - Behaviour matches the 6809 binary, with one change: the
*    collision scan branches back to COL_LOOP, not to CHK_COLLISIONS.
*    The original hangs on the first file/free collision
*    (analysis.md section 4.1).
*  - Small side effects of the port: the bitmap scans now also scan
*    the last byte ($FFF8-$FFFF) (analysis.md 4.11), and FS_TAIL_TS
*    is cleared before relink (analysis.md 4.10).
*
* Key Memory Structures
*
*  $1000 - $2FFF (L1000): File Allocation Bitmap (8 KB). One bit per
*                T/S claimed by files (and system/padding).
*  $3000 - $4FFF (L3000): Free Space Bitmap (8 KB). One bit per T/S
*                linked in the free-sector chain.
*  $5000         Directory FCB, used for FMS functions 6 and 7.
*  $5140         Raw sector FCB, used for FMS functions 9 and 10.
*                The 256-byte sector buffer is at $5180 (FCB+64).
*  $5280 -       Program variables.
*

                   ORG       $0100

START              BRA       MAIN                   Jump over copyright header

                   FCC       'CHAINFIX V1.0 (c) CATERPILLAR SO'
                   FCC       'FTWARE CO.  '

* ------------------------------------------------------------------------------
* INITIALIZATION & DRIVE PROMPT
* ------------------------------------------------------------------------------

MAIN               LDX       #L1000                 Clear both bitmaps ($1000-$4FFF)
CLR_MAPS           CLR       0,X
                   INX
                   CPX       #DIR_FCB               Reached $5000?
                   BNE       CLR_MAPS

                   LDX       #L1000                 Active bitmap = File Bitmap
                   STX       BITMAPBASE

ASK_DRV            LDX       #MSG_DRV               "Drive number to check ? "
                   JSR       PSTRNG
                   JSR       INBUFF
                   JSR       INDEC                  Number returned in X
                   STX       DRVTMP
                   LDAA      DRVTMP                 High byte must be 0
                   BNE       BAD_DRV
                   LDAB      DRVTMP+1
                   CMPB      #$04                   Drives 0-3 only
                   BCS       DRV_OK
BAD_DRV            LDX       #MSG_RANGE             "Drive number out of range."
                   JSR       PSTRNG
                   BRA       ASK_DRV

DRV_OK             STAB      DIR_DRV_NO             Drive # into directory FCB
                   STAB      DRV_NO                 Drive # into raw sector FCB
                   JSR       PCRLF
                   LDX       #MSG_INIT              "Initializing bit maps."
                   JSR       PSTRNG
                   JSR       PCRLF

* ------------------------------------------------------------------------------
* READ SIR (T0/S3) AND MARK EVERYTHING OUTSIDE THE DISK GEOMETRY
* ------------------------------------------------------------------------------

                   CLRA                             Track 0, Sector 3 (SIR)
                   LDAB      #$03
                   JSR       READ_SEC
                   LDAA      SIR_MT_MS              Max Track
                   LDAB      SIR_MT_MS+1            Max Sector
                   STAA      MAX_TS
                   STAB      MAX_SCT

* Mark every T/S from (MaxTrack,MaxSector)+1 through $FFFF as used

PAD_TRK0           ADDB      #$01                   16-bit increment of A:B
                   ADCA      #$00
                   BNE       PAD_SET
                   TSTB
                   BEQ       PAD_ALL                Wrapped to $0000 -> done
PAD_SET            JSR       SET_BIT
                   BRA       PAD_TRK0

* On each track 0..MaxTrack mark sector 0 and sectors MaxSector+1..255

PAD_ALL            CLRA
                   CLRB
PAD_LOOP           JSR       SET_BIT
                   DECB                             0 -> 255 -> 254 ...
                   CMPB      MAX_SCT
                   BNE       PAD_LOOP
                   INCA                             Next track
                   CLRB
                   CMPA      MAX_TS
                   BLS       PAD_LOOP

* Reserve boot sectors and SIR, then trace the chain from T0/S4
* (this marks the directory if S4 links to S5, see analysis.md 4.5)

                   CLRA
                   LDAB      #$01                   T0/S1 boot
                   JSR       SET_BIT
                   LDAB      #$02                   T0/S2 boot
                   JSR       SET_BIT
                   LDAB      #$03                   T0/S3 SIR
                   JSR       SET_BIT
                   LDAB      #$04                   T0/S4 -> directory chain
                   JSR       TRACE_CHAIN

* ------------------------------------------------------------------------------
* MAIN EXECUTION PIPELINE
* ------------------------------------------------------------------------------

                   JSR       BUILD_FILE_MAP         1: directory -> File Bitmap
                   JSR       BUILD_FREE_MAP         2: free chain -> Free Bitmap
                   JSR       CHK_COLLISIONS         3: file AND free
                   JSR       CHK_MISSES             4: NOT (file OR free)
                   JSR       REPORT_AND_FIX         5: totals, optional relink
                   JMP       WARMS

* ==============================================================================
* BUILD_FILE_MAP - scan directory and trace every file's sector chain
* ==============================================================================

BUILD_FILE_MAP     LDX       #MSG_FMAP              "Building the file map."
                   JSR       PSTRNG
                   CLR       INTFILCNT
                   CLR       INTFILCNT+1
                   LDX       #DIR_FCB
                   LDAA      #$06                   FMS: Open Directory
                   STAA      0,X
                   JSR       FMSCALL
                   BNE       DIR_ERR

NEXT_FILE          JSR       PCRLF
NEXT_ENTRY         LDX       #DIR_FCB
                   LDAA      #$07                   FMS: Get Information Record
                   STAA      0,X
                   JSR       FMSCALL
                   BEQ       PROC_ENTRY
                   LDX       #DIR_FCB
                   LDAA      1,X                    Error status
                   CMPA      #$08                   End of directory?
                   BEQ       DIR_DONE
DIR_ERR            LDX       #DIR_FCB
                   JSR       RPTERR
                   JMP       WARMS

PROC_ENTRY         LDAA      DIR_FNAME              First byte of name
                   BEQ       DIR_DONE               $00 = never used -> end
                   BMI       NEXT_ENTRY             Deleted -> skip
                   JSR       PRT_FNAME
                   LDX       STRT_TS                Start T/S
                   BEQ       CHK_END_TS             00/00 = empty file
                   LDAA      #$01                   Collision flag = 1 (clean)
                   STAA      COLLFLG
                   LDAA      STRT_TS
                   LDAB      STRT_TS+1
                   JSR       TRACE_CHAIN
                   TST       COLLFLG
                   BNE       GET_LAST_TS            Still 1 -> no collision
                   INC       INTFILCNT+1            Count intersected file
                   BNE       GET_LAST_TS
                   INC       INTFILCNT
GET_LAST_TS        LDX       LST_TS                 Last T/S the trace read
CHK_END_TS         CPX       END_TS                 Same as directory end T/S?
                   BEQ       NEXT_FILE
                   LDX       #MSG_BADEND            "File end INCORECT ! "
                   JSR       PSTRNG
                   JSR       PCRLF
                   JSR       PRT_FNAME
                   BRA       NEXT_FILE

DIR_DONE           RTS

* ==============================================================================
* BUILD_FREE_MAP - trace the free chain from the SIR into the Free Bitmap
* ==============================================================================

BUILD_FREE_MAP     LDX       #MSG_FRMAP             "Building the free map."
                   JSR       PSTRNG
                   JSR       PCRLF
                   LDX       #L3000                 Active bitmap = Free Bitmap
                   STX       BITMAPBASE
                   CLRA                             Re-read SIR
                   LDAB      #$03
                   JSR       READ_SEC
                   LDAA      SIR_STRT_FC            Free chain head
                   LDAB      SIR_STRT_FC+1
                   JSR       TRACE_CHAIN
                   RTS

* ==============================================================================
* CHK_COLLISIONS - sectors claimed by both a file and the free chain
* ==============================================================================

CHK_COLLISIONS     LDX       #MSG_COLL              "Checking for collisions."
                   JSR       PSTRNG
                   JSR       PCRLF
                   CLR       COLLCNT
                   CLR       COLLCNT+1
                   LDAA      #$10                   16 entries per line
                   STAA      LINWRPCNTR
                   JSR       SCAN_INIT

COL_LOOP           LDX       FPTR
                   CPX       #L3000                 End of File Bitmap?
                   BEQ       COL_DONE
                   LDAA      0,X                    File Bitmap byte
                   INX
                   STX       FPTR
                   LDX       RPTR
                   ANDA      0,X                    AND Free Bitmap byte
                   INX
                   STX       RPTR
                   TSTA
                   BEQ       COL_NXT
                   JSR       PRT_BITS
COL_NXT            JSR       SCAN_NEXT
                   BRA       COL_LOOP               (6809 binary: BRA CHK_COLLISIONS)

COL_DONE           LDAA      COLLCNT+1              TOTINTCNT = COLLCNT + INTFILCNT
                   ADDA      INTFILCNT+1
                   STAA      TOTINTCNT+1
                   LDAA      COLLCNT
                   ADCA      INTFILCNT
                   STAA      TOTINTCNT
                   RTS

* ==============================================================================
* CHK_MISSES - sectors in neither map (lost sectors)
* ==============================================================================

CHK_MISSES         LDX       #MSG_MISS              "Checking for misses."
                   JSR       PSTRNG
                   JSR       PCRLF
                   CLR       COLLCNT                Now counts missed sectors
                   CLR       COLLCNT+1
                   LDAA      #$10
                   STAA      LINWRPCNTR
                   JSR       SCAN_INIT

MISS_LOOP          LDX       FPTR
                   CPX       #L3000
                   BEQ       MISS_DONE
                   LDAA      0,X                    File Bitmap byte
                   INX
                   STX       FPTR
                   LDX       RPTR
                   ORAA      0,X                    OR Free Bitmap byte
                   INX
                   STX       RPTR
                   COMA                             1 = in neither map
                   BEQ       MISS_NXT
                   JSR       PRT_BITS
MISS_NXT           JSR       SCAN_NEXT
                   BRA       MISS_LOOP

MISS_DONE          RTS

* ------------------------------------------------------------------------------
* SCAN_INIT / SCAN_NEXT - bitmap scan pointers and T/S counter
* ------------------------------------------------------------------------------

SCAN_INIT          LDX       #L1000
                   STX       FPTR                   File Bitmap pointer (was U)
                   LDX       #L3000
                   STX       RPTR                   Free Bitmap pointer (was Y)
                   CLR       SCANTS                 T/S of bit 0 (was X)
                   CLR       SCANTS+1
                   RTS

SCAN_NEXT          LDAB      SCANTS+1               SCANTS += 8
                   ADDB      #$08
                   STAB      SCANTS+1
                   BCC       SN_RTS
                   INC       SCANTS
SN_RTS             RTS

* ==============================================================================
* REPORT_AND_FIX - print totals, optionally rebuild the free chain
* ==============================================================================

REPORT_AND_FIX     JSR       PCRLF
                   LDX       #MSG_INTF              "Total number files intersected - "
                   JSR       PSTRNG
                   LDX       #INTFILCNT
                   JSR       OUTADR
                   LDX       #MSG_INTT              "Total number of intersections - "
                   JSR       PSTRNG
                   LDX       #TOTINTCNT
                   JSR       OUTADR
                   LDX       #MSG_MISST             "Total number of missed sectors - "
                   JSR       PSTRNG
                   LDX       #COLLCNT
                   JSR       OUTADR
                   LDX       #MSG_ASKFIX            "Relink the free chain (Y/N) "
                   JSR       PSTRNG
                   JSR       INBUFF
                   JSR       NXTCH
                   ANDA      #$5F                   Upper case
                   CMPA      #$59                   'Y'?
                   BEQ       DO_FIX
                   RTS

* --- Rebuild Free Chain ---

DO_FIX             LDX       #MSG_RELINK            "Relinking the free chain."
                   JSR       PSTRNG
                   CLR       TOTFREESECT
                   CLR       TOTFREESECT+1
                   LDX       #SCT_BUFF              Zero the sector buffer
CLR_SBUF           CLR       0,X
                   INX
                   CPX       #SCT_BUFF+256
                   BNE       CLR_SBUF
                   CLR       PRGCNTR
                   LDX       #L1000                 Active bitmap = File Bitmap
                   STX       BITMAPBASE
                   CLR       PREV_TS                Previous free T/S = 00/00
                   CLR       PREV_TS+1
                   CLR       FS_TAIL_TS
                   CLR       FS_TAIL_TS+1

                   LDAA      MAX_TS                 Start at (MaxTrack,MaxSector)
                   LDAB      MAX_SCT
RELINK_LP          JSR       SET_BIT                Test and set in File Bitmap
                   BNE       RELINK_NXT             Already used -> skip

* Unused sector in A:B. Link it in front of the previous one.

                   LDX       PREV_TS
                   BNE       SAVE_LINK
                   STAA      FS_TAIL_TS             First one found = chain end
                   STAB      FS_TAIL_TS+1
SAVE_LINK          STX       SCT_BUFF               Forward link in bytes 0-1
                   STAA      PREV_TS
                   STAB      PREV_TS+1
                   JSR       WRITE_SEC
                   INC       TOTFREESECT+1          Count free sector
                   BNE       RELINK_NXT
                   INC       TOTFREESECT

RELINK_NXT         INC       PRGCNTR                '+' every 256 sectors
                   BNE       DEC_TS
                   PSHA
                   PSHB
                   LDAA      #$2B
                   JSR       PUTCHR
                   PULB
                   PULA
DEC_TS             SUBB      #$01                   16-bit decrement of A:B
                   SBCA      #$00
                   BNE       RELINK_LP
                   TSTB
                   BNE       RELINK_LP              Until A:B = $0000

* Update the SIR with the new free chain

                   CLRA                             Read SIR (T0/S3)
                   LDAB      #$03
                   JSR       READ_SEC
                   LDX       PREV_TS                Head of free chain
                   STX       SIR_STRT_FC
                   LDX       FS_TAIL_TS             Tail of free chain
                   STX       SIR_END_FC
                   LDX       TOTFREESECT            Free sector count
                   STX       SIR_FS_CNT
                   JSR       WRITE_SEC              A:B still = 00/03

                   LDX       #MSG_DONE              "Chain fix program complete."
                   JSR       PSTRNG
                   RTS

* ==============================================================================
* PRT_BITS - print T/S for each set bit in A. Bit 0 = T/S in SCANTS.
* Counts each one in COLLCNT and wraps the line after 16 entries.
* ==============================================================================

PRT_BITS           STAA      PBMASK
                   LDAA      SCANTS
                   STAA      PBTS
                   LDAA      SCANTS+1
                   STAA      PBTS+1
                   LDAA      #$08
                   STAA      PBCNT
PBIT_LP            LSR       PBMASK                 Next bit -> carry
                   BCC       PBIT_NXT
                   LDX       #PBTS
                   JSR       OUTADR                 Print 4-digit hex T/S
                   INC       COLLCNT+1
                   BNE       PBIT_WRP
                   INC       COLLCNT
PBIT_WRP           DEC       LINWRPCNTR
                   BNE       PBIT_SPC
                   LDAA      #$10
                   STAA      LINWRPCNTR
                   JSR       PCRLF
                   BRA       PBIT_NXT
PBIT_SPC           LDAA      #$20
                   JSR       PUTCHR
PBIT_NXT           INC       PBTS+1                 Next T/S (stays in group of 8)
                   DEC       PBCNT
                   BNE       PBIT_LP
                   RTS

* ==============================================================================
* PRT_FNAME - print 8.3 file name from the directory FCB
* ==============================================================================

PRT_FNAME          LDX       #DIR_FNAME
                   LDAB      #$0B                   11 characters
                   STAB      PFCNT
PFN_LP             LDAA      0,X
                   BNE       PFN_CHR
                   LDAA      #$20                   Null -> space
PFN_CHR            INX
                   STX       PFPTR
                   JSR       PUTCHR
                   LDX       PFPTR
                   DEC       PFCNT
                   BEQ       PFN_END
                   LDAB      PFCNT
                   CMPB      #$03                   3 left -> print '.'
                   BNE       PFN_LP
                   LDAA      #$2E
                   JSR       PUTCHR
                   LDX       PFPTR
                   BRA       PFN_LP

PFN_END            LDAA      #$20                   Trailing space
                   JSR       PUTCHR
                   RTS

* ==============================================================================
* TRACE_CHAIN - follow a sector chain, marking each T/S in the active bitmap
* Entry: A = track, B = sector of first sector
* ==============================================================================

TRACE_CHAIN        CLR       PRGCNTR
TC_LOOP            JSR       SET_BIT
                   BEQ       TC_READ                Bit was clear -> normal

* Already marked: intersection

                   CLR       COLLFLG
                   STAA      TCTS
                   STAB      TCTS+1
                   LDX       #MSG_INTER             "Intersection at - "
                   JSR       PSTRNG
                   LDX       #TCTS
                   JSR       OUTADR
                   LDAA      TCTS
                   LDAB      TCTS+1
TC_READ            JSR       READ_SEC
                   INC       PRGCNTR                '+' every 256 sectors
                   BNE       TC_NEXT
                   LDAA      #$2B
                   JSR       PUTCHR
TC_NEXT            LDX       SCT_BUFF               Link in bytes 0-1
                   BEQ       TC_DONE                00/00 = end of chain
                   LDAA      SCT_BUFF
                   LDAB      SCT_BUFF+1
                   BRA       TC_LOOP
TC_DONE            RTS

* ==============================================================================
* SET_BIT - set the bit for T/S A:B in the active bitmap (BITMAPBASE)
* Exit: Z = 1 if the bit was clear before, Z = 0 if it was already set.
*       A, B and X preserved.
* ==============================================================================

SET_BIT            STX       SBSAVX
                   STAA      SBTS
                   STAB      SBTS+1
                   LSRA                             A:B >> 3 = byte offset
                   RORB
                   LSRA
                   RORB
                   LSRA
                   RORB
                   ADDB      BITMAPBASE+1           + bitmap base
                   ADCA      BITMAPBASE
                   STAA      SBPTR
                   STAB      SBPTR+1
                   LDX       SBPTR                  X = byte address
                   LDAA      #$01                   Mask = 1 << (sector & 7)
                   LDAB      SBTS+1
                   ANDB      #$07
SB_SHIFT           BEQ       SB_GO
                   ASLA
                   DECB
                   BRA       SB_SHIFT
SB_GO              TAB                              B = mask
                   ANDA      0,X                    A = old state of bit
                   ORAB      0,X
                   STAB      0,X                    Set bit
                   STAA      SBOLD
                   LDX       SBSAVX
                   LDAA      SBTS
                   LDAB      SBTS+1
                   TST       SBOLD                  Z from old state
                   RTS

* ==============================================================================
* READ_SEC / WRITE_SEC - single sector I/O on the raw FCB
* Entry: A = track, B = sector. A, B and X preserved. Abort on error.
* ==============================================================================

READ_SEC           STAA      RSTS
                   LDAA      #$09                   FMS: Read Single Sector
                   BRA       SEC_IO

WRITE_SEC          STAA      RSTS
                   LDAA      #$0A                   FMS: Write Single Sector

SEC_IO             STX       RSSAVX
                   LDX       #RAW_FCB
                   STAA      0,X                    Function code
                   LDAA      RSTS
                   STAA      30,X                   Track
                   STAB      31,X                   Sector
                   STAB      RSTS+1
                   JSR       FMSCALL
                   BNE       SIO_ERR
                   LDX       RSSAVX
                   LDAA      RSTS
                   LDAB      RSTS+1
                   RTS

SIO_ERR            LDX       #RAW_FCB
                   JSR       RPTERR
                   JMP       WARMS

* ==============================================================================
* MESSAGES
* ==============================================================================

MSG_DRV            FCB       $0D,$0A
                   FCC       'Drive number to check ? '
                   FCB       $04
MSG_RANGE          FCB       $0D,$0A
                   FCC       'Drive number out of range.'
                   FCB       $04
MSG_BADEND         FCB       $07
                   FCC       '............File end INCORECT ! '
                   FCB       $04
MSG_INTER          FCB       $07
                   FCC       '............Intersection at - '
                   FCB       $04
MSG_INIT           FCC       'Initializing bit maps.'
                   FCB       $04
MSG_FMAP           FCC       'Building the file map.'
                   FCB       $04
MSG_FRMAP          FCC       'Building the free map.'
                   FCB       $04
MSG_COLL           FCC       'Checking for collisions.'
                   FCB       $04
MSG_MISS           FCC       'Checking for misses.'
                   FCB       $04
MSG_INTF           FCC       'Total number files intersected - '
                   FCB       $04
MSG_INTT           FCB       $0D
                   FCC       'Total number of intersections  - '
                   FCB       $04
MSG_MISST          FCB       $0D
                   FCC       'Total number of missed sectors - '
                   FCB       $04
MSG_ASKFIX         FCB       $0A,$0D
                   FCC       'Relink the free chain (Y/N) '
                   FCB       $04
MSG_RELINK         FCB       $0A,$0D
                   FCC       'Relinking the free chain.'
                   FCB       $0A,$0D,$04
MSG_DONE           FCB       $0A,$0D
                   FCC       'Chain fix program complete.'
                   FCB       $0A,$0D,$0A,$0D,$04

* ==============================================================================
* DATA AREAS (fixed addresses, same as the 6809 version)
* ==============================================================================

L1000              EQU       $1000                  File Bitmap
L3000              EQU       $3000                  Free Bitmap
DIR_FCB            EQU       $5000                  Directory FCB
DIR_DRV_NO         EQU       $5003
DIR_FNAME          EQU       $5004
STRT_TS            EQU       $5011
END_TS             EQU       $5013
RAW_FCB            EQU       $5140                  Raw sector FCB
DRV_NO             EQU       $5143
LST_TS             EQU       $515E                  FCB+30: current T/S
SCT_BUFF           EQU       $5180                  FCB+64: sector buffer
SIR_STRT_FC        EQU       $519D
SIR_END_FC         EQU       $519F
SIR_FS_CNT         EQU       $51A1
SIR_MT_MS          EQU       $51A6

* Variables used by the 6809 version

PREV_TS            EQU       $5280                  Previous free T/S / chain head
FS_TAIL_TS         EQU       $5282
TOTFREESECT        EQU       $5284
BITMAPBASE         EQU       $5286
MAX_TS             EQU       $5288
MAX_SCT            EQU       $5289
INTFILCNT          EQU       $528A
COLLFLG            EQU       $528C
TOTINTCNT          EQU       $528D
COLLCNT            EQU       $528F
PRGCNTR            EQU       $5291
LINWRPCNTR         EQU       $5292

* Extra variables for the 6800 (replace D, Y, U and stack use)

DRVTMP             EQU       $5293                  2 INDEC result
FPTR               EQU       $5295                  2 File Bitmap scan pointer
RPTR               EQU       $5297                  2 Free Bitmap scan pointer
SCANTS             EQU       $5299                  2 T/S of current scan byte
PBMASK             EQU       $529B                  1
PBCNT              EQU       $529C                  1
PBTS               EQU       $529D                  2
SBSAVX             EQU       $529F                  2
SBTS               EQU       $52A1                  2
SBPTR              EQU       $52A3                  2
SBOLD              EQU       $52A5                  1
RSSAVX             EQU       $52A6                  2
RSTS               EQU       $52A8                  2
TCTS               EQU       $52AA                  2
PFPTR              EQU       $52AC                  2
PFCNT              EQU       $52AE                  1

* ==============================================================================
* FLEX 2.0 (6800) ENTRY POINTS
* ==============================================================================

WARMS              EQU       $AD03
PUTCHR             EQU       $AD18
INBUFF             EQU       $AD1B
PSTRNG             EQU       $AD1E
PCRLF              EQU       $AD24
NXTCH              EQU       $AD27
RPTERR             EQU       $AD3F
OUTADR             EQU       $AD45
INDEC              EQU       $AD48
FMSCALL            EQU       $B406

                   END       START
