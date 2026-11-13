*
* PROGRAM CHAINFIX.CMD DISSASSEMBLED BY DA68Sharp
*
* using control table file CHAINFIX.ctl
*

                   ORG       $0100

* ==============================================================================
* CHAINFIX V1.0 - FLEX09 Disk Chain Diagnostic & Free-Chain Repair Utility
* ==============================================================================
* 
* Key Memory Structures Used by the Program
* 
*  $1000 - $2FFF (L1000): File Allocation Bitmap 
*                (8 KB). Tracks every Track/Sector
*                (T/S) currently claimed by active
*                files in the directory.
*  $3000 - $4FFF (L3000): Free Space Bitmap 
*                (8 KB).Tracks every T/S currently
*                linked in the disk's free-sector
*                chain.
*  $5000         (L5000): Directory File Control Block
*                (FCB). Used for FMS calls #6 Open
*                Directory) and #7 (Get Next Directory
*                Entry).
*  $5140         (L5140): Raw Sector I/O FCB. Used for 
*                FMS calls #9 (Read Single Sector) and
*                #10 (Write Single Sector). At L5180
*                ($5180), the 256-byte sector data uffer
*                begins (Track/Sector forward link is at
*                $5180-$5181).

START              BRA       MAIN                   Jump over copyright header to main entry

                   FCC       'CHAINFIX V1.0 (c) CATERPILLAR SO'
                   FCC       'FTWARE CO.  '


*  ------------------------------------------------------------------------------
*  INITIALIZATION & DRIVE PROMPT
*  ------------------------------------------------------------------------------

MAIN               LEAX      >L1000,PCR             Point X to start of File Bitmap ($1000)
                   LEAX      >16384,X               Add 16KB ($4000) -> X = $5000 (end of bitmaps)
                   STX       >ENDBITMAPADDR         Save end-of-bitmap address ($5000)
                   LEAX      >L1000,PCR             Reset X to start of bitmaps ($1000)
CLR_MAPS           CLR       ,X+                    Zero out 16KB ($1000-$4FFF) for File & Free bitmaps
                   CMPX      >ENDBITMAPADDR         Reached $5000?
                   BNE       CLR_MAPS               No, keep clearing memory
*                                                   *  
                   LEAX      >L1000,PCR             Set active bitmap base pointer ($5286)
                   STX       >BITMAPBASE            to File Bitmap ($1000)
*                                                   *  
ASK_DRV            LEAX      >MSG_DRV,PCR           Prompt: "Drive number to check ? "
                   JSR       >PSTRNG                Print prompt via FLEX
                   JSR       >INBUFF                Read user input into FLEX line buffer
                   JSR       >INDEC                 Parse decimal number into X
                   TFR       X,D                    Move drive number to D (B = low byte)
                   CMPD      #$0004                 Valid FLEX drives are 0 through 3
                   BCS       DRV_OK                 If < 4, valid drive -> continue
                   LEAX      >MSG_RANGE,PCR         Error: "Drive number out of range."
                   JSR       >PSTRNG                Print error
                   BRA       ASK_DRV                Re-prompt user

DRV_OK             STAB      >DIR_DRV_NO,PCR        Store Drive # in Directory FCB ($5000 + 3)
                   STAB      >DRV_NO,PCR            Store Drive # in Raw Sector FCB ($5140 + 3)
                   JSR       >PCRLF                 Print CR/LF
                   LEAX      >MSG_INIT,PCR          Print "Initializing bit maps."
                   JSR       >PSTRNG                
                   JSR       >PCRLF                 

* ------------------------------------------------------------------------------
* READ SYSTEM INFORMATION RECORD (SIR - Track 0, Sector 3) & MASK OUT OF BOUNDS
* ------------------------------------------------------------------------------

                   LDD       #$0003                 Track 0, Sector 3 (FLEX SIR)
                   LBSR      READ_SEC               Read SIR into buffer ($5180)
                   LDD       >SIR_MT_MS,PCR         Get Max Track (A) and Max Sector (B) from SIR
                   STD       >MAX_TS,PCR            Save Max Track ($5288) & Max Sector ($5289)

* Mark non-existent sectors (MaxSector+1 up to 255) on Track 0 as "allocated"

PAD_TRK0           ADDD      #$0001                 Increment sector number (B)
                   BEQ       PAD_ALL                Wrapped past 255? Done with Track 0 padding
                   LBSR      SET_BIT                Set bit in File Bitmap so they aren't flagged as missed
                   BRA       PAD_TRK0               Loop until B wraps to 0


* Mark all tracks/sectors beyond disk geometry (Track 1..MaxTrack, Sector > MaxSector)

PAD_ALL            LDD       #$0000                 Start at Track 0, Sector 0
PAD_LOOP           LBSR      SET_BIT                Set bit in File Bitmap (masks out Sector 0 & invalid sectors)
                   DECB                             Decrement sector backwards (0 -> 255 -> 254...)
                   CMPB      >MAX_SCT,PCR           Reached valid Max Sector on this track?
                   BNE       PAD_LOOP               No, keep marking out-of-range sectors as used
                   INCA                             Move to next Track
                   CLRB                             Reset Sector to 0 (to mask Sector 0 on next track)
                   CMPA      >MAX_TS,PCR            Exceeded Max Track?
                   BLS       PAD_LOOP               No (A <= MaxTrack), repeat for next track01AB,    67,B,Reserve System Sectors (Track 0, Sectors 1, 2, 3, and 4 - Boot & SIR)

* Reserve System Sectors (Track 0, Sectors 1, 2, 3, and 4 - Boot & SIR)

                   LDD       #$0001                 Track 0, Sector 1 (Boot sector)
                   LBSR      SET_BIT                Mark in File Bitmap
                   LDD       #$0002                 Track 0, Sector 2 (Boot sector)
                   LBSR      SET_BIT                Mark in File Bitmap
                   LDD       #$0003                 Track 0, Sector 3 (SIR)
                   LBSR      SET_BIT                Mark in File Bitmap
                   LDD       #$0004                 Track 0, Sector 4 (Backup SIR / System)
                   LBSR      TRACE_CHAIN            Trace & mark entire chain starting at T0/S4

* ------------------------------------------------------------------------------
* MAIN EXECUTION PIPELINE
* ------------------------------------------------------------------------------

                   BSR       BUILD_FILE_MAP         Step 1: Scan Directory & build File Bitmap ($1000)
                   LBSR      BUILD_FREE_MAP         Step 2: Trace Free Chain & build Free Bitmap ($3000)
                   LBSR      CHK_COLLISIONS         Step 3: Check for Collisions (File & Free overlap)
                   LBSR      CHK_MISSES             Step 4: Check for Misses (Orphaned/unclaimed sectors)
                   LBSR      REPORT_AND_FIX         Step 5: Print summary & optionally relink free chain
                   JMP       >WARMS                 Exit cleanly back to FLEX Warm Start


* ==============================================================================
* SUBROUTINE: BUILD_FILE_MAP ($01D4)
* Scans all active directory entries and traces each file's sector chain.
* ==============================================================================

BUILD_FILE_MAP     LEAX      >MSG_FMAP,PCR          Print "Building the file map."
                   JSR       >PSTRNG                
                   LDD       #$0000                 
                   STD       >INTFILCNT,PCR         Clear counter: Intersected Files ($528A) = 0
*                                                   *  
                   LEAX      >DIR_FCB,PCR           Point X to Directory FCB ($5000)
                   LDAB      #$06                   FMS Function $06: Open Directory
                   STAB      ,X                     
                   JSR       >FMSCALL               Call FLEX File Management System
                   BNE       DIR_ERR                Jump to error handler if open failed
*                                                   *  
NEXT_FILE          JSR       >PCRLF                 
NEXT_ENTRY         LEAX      >DIR_FCB,PCR           Point X to Directory FCB04B6,   100,E, 
                   LDAB      #$07                   FMS Function $07: Get Next Directory Entry
                   STAB      ,X                     
                   JSR       >FMSCALL               
                   BEQ       PROC_ENTRY             Success -> process directory entry
                   LDAB      1,X                    Check FMS error status byte
                   CMPB      #$08                   Error $08 = End of Directory reached?
                   BEQ       DIR_DONE               Yes -> exit subroutine normally
DIR_ERR            JSR       >RPTERR                Otherwise report disk error via FLEX
                   JMP       >WARMS                 Abort to FLEX

PROC_ENTRY         TST       >DIR_FNAME,PCR         Test first byte of filename in DIR entry
                   BEQ       DIR_DONE               $00 = Never-used directory entry (end of active DIR)
                   BMI       NEXT_ENTRY             Bit 7 set ($FF) = Deleted file -> skip to next entry
                   LBSR      PRT_FNAME              Print filename.ext (8.3 format) to console
                   LDD       >STRT_TS,PCR           Get file's Start Track/Sector from DIR entry ($5011)
                   BEQ       CHK_END_TS             If T/S is 00/00 (empty file), skip chain trace
                   CLR       >COLLFLG,PCR           Clear collision flag for this specific file ($528C)
                   INC       >COLLFLG,PCR           Set flag = 1 (will be cleared if collision occurs)
                   LBSR      TRACE_CHAIN            Trace entire file chain, marking File Bitmap
                   TST       >COLLFLG,PCR           Did a collision occur during this file?
                   BNE       GET_LAST_TS            Still 1 -> no collision in this file
                   LDD       >INTFILCNT,PCR         Load Intersected File count ($528A)
                   ADDD      #$0001                 Increment count of damaged/intersected files
                   STD       >INTFILCNT,PCR         
GET_LAST_TS        LDD       >LST_TS,PCR            Get last Track/Sector reached by chain trace
CHK_END_TS         CMPD      >END_TS,PCR            Compare against End Track/Sector recorded in DIR ($5013)
                   BEQ       NEXT_FILE              Match! File chain integrity is good -> next file
                   LEAX      >MSG_BADEND,PCR        Print "File end INCORECT ! "
                   JSR       >PSTRNG                
                   JSR       >PCRLF                 
                   LBSR      PRT_FNAME              Reprint filename for clarity
                   BRA       NEXT_FILE              Continue to next directory entry

DIR_DONE           RTS                              


* ==============================================================================
* SUBROUTINE: BUILD_FREE_MAP ($0253)
* Traces the disk's free-sector chain starting from the SIR head pointer.
* ==============================================================================

BUILD_FREE_MAP     LEAX      >MSG_FRMAP,PCR         Print "Building the free map."
                   JSR       >PSTRNG                
                   JSR       >PCRLF                 
                   LEAX      >L3000,PCR             Switch active bitmap base pointer ($5286)
                   STX       >BITMAPBASE,PCR          to Free Space Bitmap ($3000)
                   LDD       #$0003                 Track 0, Sector 3 (SIR)
                   LBSR      READ_SEC               Re-read SIR into buffer ($5180)
                   LDD       >SIR_STRT_FC,PCR       Get Start of Free Chain T/S from SIR ($519D)
                   LBSR      TRACE_CHAIN            Trace free chain & mark bits in Free Bitmap ($3000)
                   RTS                              


* ==============================================================================
* SUBROUTINE: CHK_COLLISIONS ($0273)
* Finds sectors claimed by BOTH a file and the free chain.
* ==============================================================================

CHK_COLLISIONS     LEAX      >MSG_COLL,PCR          Print "Checking for collisions."
                   JSR       >PSTRNG                
                   JSR       >PCRLF                 
                   LDD       #$0000                 
                   STD       >COLLCNT,PCR           Reset collision counter ($528F) = 0
                   LDAA      #$10                   16 T/S entries per printed line
                   STAA      >LINWRPCNTR,PCR        Initialize line wrap counter ($5292)
                   LEAU      >L1000,PCR             U = File Bitmap ($1000)
                   LEAY      >L3000,PCR             Y = Free Bitmap ($3000)
                   LDX       #$FFF8                 X = Track/Sector counter (starts at -8 so first +8 = 0)
*                                                   *  
COL_LOOP           LEAX      8,X                    Advance T/S counter by 8 sectors (1 byte = 8 bits)
                   CMPX      #$FFF8                 Wrapped around full 65,536 T/S space?
                   BEQ       COL_DONE               Yes -> finished scanning bitmaps
                   LDAA      ,U+                    Load byte from File Bitmap
                   ANDA      ,Y+                    Bitwise AND with Free Bitmap (1 = claimed by BOTH!)
                   BEQ       COL_LOOP               Zero = no overlap in these 8 sectors -> continue
                   LBSR      PRT_BITS               Print all colliding T/S addresses in this byte
                   BRA       CHK_COLLISIONS         [Original binary byte $CC = BRA $0273; logic target is COL_LOOP]
*                                                   *  

COL_DONE           LDD       >COLLCNT,PCR           Get collisions found between File & Free maps
                   ADDD      >INTFILCNT,PCR         Add intra-file collisions found earlier
                   STD       >TOTINTCNT,PCR         Save Total Intersections count ($528D)
                   RTS                              


* ==============================================================================
* SUBROUTINE: CHK_MISSES ($02B4)
* Finds sectors marked '0' in BOTH File Map and Free Map (lost sectors).
* ==============================================================================

CHK_MISSES         LEAX      >MSG_MISS,PCR          Print "Checking for misses."
                   JSR       >PSTRNG                
                   JSR       >PCRLF                 
                   LDD       #$0000                 
                   STD       >COLLCNT,PCR           Reset missed-sector counter ($528F) = 0
                   LDAA      #$10                   
                   STAA      >LINWRPCNTR,PCR        Reset line wrap counter = 16
                   LEAU      >L1000,PCR             U = File Bitmap ($1000)
                   LEAY      >L3000,PCR             Y = Free Bitmap ($3000)
                   LDX       #$FFF8                 X = T/S counter (-8)
*                                                   *  
MISS_LOOP          LEAX      8,X                    Advance T/S counter by 8 sectors
                   CMPX      #$FFF8                 Wrapped around full T/S space?
                   BEQ       MISS_DONE              Yes -> done
                   LDAA      ,U+                    Load byte from File Bitmap
                   ORAA      ,Y+                    Bitwise OR with Free Bitmap (0 = in NEITHER map)
                   COMA                             Invert bits so '1' indicates a missed/orphaned sector
                   BEQ       MISS_LOOP              Zero = all 8 sectors accounted for -> keep scanning
                   LBSR      PRT_BITS               Print all missed T/S addresses & increment SEC_TALLY
                   BRA       MISS_LOOP              Continue scan

MISS_DONE          RTS                              


* ==============================================================================
* SUBROUTINE: REPORT_AND_FIX ($02EA)
* Displays diagnostic totals and optionally rebuilds the disk's free chain.
* ==============================================================================

REPORT_AND_FIX     JSR       >PCRLF                 
                   LEAX      >MSG_INTF,PCR          Print "Total number files intersected - "
                   JSR       >PSTRNG                
                   LEAX      >INTFILCNT,PCR         Print hex value at $528A
                   JSR       >OUTADR                
                   LEAX      >MSG_INTT,PCR          Print "Total number of intersections - "
                   JSR       >PSTRNG                
                   LEAX      >TOTINTCNT,PCR         Print hex value at $528D
                   JSR       >OUTADR                
                   LEAX      >MSG_MISST,PCR         Print "Total number of missed sectors - "
                   JSR       >PSTRNG                
                   LEAX      >COLLCNT,PCR           Print hex value at $528F
                   JSR       >OUTADR                
                   LEAX      >MSG_ASKFIX,PCR        Prompt: "Relink the free chain (Y/N) "
                   JSR       >PSTRNG                
                   JSR       >INBUFF                Read user input
                   JSR       >NXTCH                 Get next character from input buffer
                   ANDA      #$5F                   Convert lowercase to uppercase
                   CMPA      #$59                   Is it 'Y'?
                   LBNE      FIX_EXIT               Anything other than 'Y' -> exit without modifying disk

* --- Rebuild Free Chain ---

                   LEAX      >MSG_RELINK,PCR        Print "Relinking the free chain."
                   JSR       >PSTRNG                
                   LEAX      >SCT_BUFF,PCR          Point X to 256-byte sector buffer ($5180)
                   LDD       #$0000                 
                   STD       >TOTFREESECT,PCR       Reset Total Free Sectors counter ($5284) = 0
CLR_SBUF           STAA      ,X+                    Zero out all 256 bytes of sector buffer ($5180-$527F)
                   DECB                             
                   BNE       CLR_SBUF               
                   CLR       >PRGCNTR,PCR           Clear progress-dot counter ($5291)
                   LEAX      >L1000,PCR             Set bitmap pointer ($5286) back to File Bitmap ($1000)
                   STX       >BITMAPBASE,PCR        
                   LDD       #$0000                 
                   STD       >ENDBITMAPADDR,PCR     Clear Previous Free T/S link ($5280) = 00/00
*                                                   *  
                   LDD       >MAX_TS,PCR            Start at highest valid T/S (MaxTrack, MaxSector)
RELINK_LP          LBSR      SET_BIT                Test bit in File Bitmap (and set it)
                   BNE       RELINK_NXT             If bit was ALREADY 1 (used by file or out-of-bounds), skip!

* Found an unused sector (D = current T/S). Link it backwards into the free chain:

                   LDX       >ENDBITMAPADDR,PCR     X = Next Free T/S (previously processed free sector)
                   BNE       SAVE_LINK              If X != 00/00, skip saving end-of-chain
                   STD       >FS_TAIL_TS,PCR        First free sector found becomes End of Free Chain ($5282)
SAVE_LINK          STX       >SCT_BUFF,PCR          ; Write forward link pointer into bytes 0-1 of sector buffer
                   STD       >ENDBITMAPADDR,PCR     Save current T/S as link target for the next free sector
                   LBSR      WRITE_SEC              Write linked sector to disk (FMS Write Sector)
                   LDD       >TOTFREESECT,PCR       Increment total free sector count ($5284)
                   ADDD      #$0001                 
                   STD       >TOTFREESECT,PCR       
                   LDD       >ENDBITMAPADDR,PCR     Restore current T/S into D
*                                                   *  
RELINK_NXT         INC       >PRGCNTR,PCR           ; Increment progress counter
                   BNE       DEC_TS                 Every 256 sectors checked...
                   PSHS      A,B                    
                   LDAA      #$2B                   ...print '+' as progress indicator
                   JSR       >PUTCHR                
                   PULS      A,B                    
DEC_TS             SUBD      #$0001                 Decrement T/S backwards down toward Track 0, Sector 0
                   BNE       RELINK_LP              Loop until D reaches $0000
*                                                   * 

* Update System Information Record (SIR - Track 0, Sector 3) with new free chain metadata

                   LDD       #$0003                 Track 0, Sector 3 (SIR)
                   LBSR      READ_SEC               Read SIR into buffer
                   LDX       >ENDBITMAPADDR,PCR     Get Head of Free Chain T/S
                   STX       >SIR_STRT_FC,PCR       Update SIR Start of Free Chain ($519D)
                   LDX       >FS_TAIL_TS,PCR        Get Tail of Free Chain T/S
                   STX       >SIR_END_FC,PCR        Update SIR End of Free Chain ($519F)
                   LDX       >TOTFREESECT,PCR       Get Total Free Sector Count
                   STX       >SIR_FS_CNT,PCR        Update SIR Free Sector Count ($51A1)
                   LBSR      WRITE_SEC              Write updated SIR back to Track 0, Sector 3
*                                                   *  
                   LEAX      >MSG_DONE,PCR          Print "Chain fix program complete."
                   JSR       >PSTRNG                
FIX_EXIT           RTS                              


* ==============================================================================
* SUBROUTINE: PRT_BITS ($03C0)
* Print Track/Sector for each set bit in A (base T/S in X).
* ==============================================================================

PRT_BITS           LDAB      #$09                   Loop counter = 9 (8 bits + 1 pre-decrement)
                   PSHS      A,B,X,Y,U              Save registers (,S = A bitmask, 1,S = B counter)
                   LEAX      -1,X                   Adjust T/S base back by 1 before loop increment
PBIT_LP            DEC       1,S                    Decrement bit counter
                   BEQ       PBIT_DONE              All 8 bits checked -> restore registers & return
                   LEAX      1,X                    Increment Track/Sector number
                   LSR       ,S                     Shift lowest bit of bitmask into Carry flag
                   BCC       PBIT_LP                Bit was 0 -> skip printing, test next bit
*                                                   *  
                   PSHS      X                      Push current T/S onto stack
                   TFR       S,X                    Point X to T/S word on stack
                   JSR       >OUTADR                Print 4-digit hex Track/Sector via FLEX
                   LDD       >COLLCNT,PCR           Increment total reported sector count ($528F)
                   ADDD      #$0001                 
                   STD       >COLLCNT,PCR           
                   DEC       >LINWRPCNTR,PCR        Decrement items-per-line counter
                   BNE       PBIT_SPC               Not 16 yet -> print space separator
                   LDAA      #$10                   Reset items-per-line counter to 16
                   STAA      >LINWRPCNTR,PCR        
                   JSR       >PCRLF                 Print newline
                   BRA       PBIT_POP               

PBIT_SPC           LDAA      #$20                   Print space (' ') between T/S values
                   JSR       >PUTCHR                
PBIT_POP           PULS      X                      Pop T/S off stack
                   BRA       PBIT_LP                Test next bit

PBIT_DONE          PULS      A,B,X,Y,U,PCR          Restore registers and return

* ==============================================================================
* SUBROUTINE: PRT_FNAME ($03FE)
* Reads 11-byte filename from Directory FCB ($5004) and inserts '.' at char 8.
* ==============================================================================

PRT_FNAME          PSHS      A,B,X                  
                   LDAB      #$0B                   11 characters total (8 name + 3 extension)
                   LEAX      >DIR_FNAME,PCR         Point X to filename field in DIR FCB ($5004)
PFN_LP             LDAA      ,X+                    Fetch next character
                   BNE       PFN_CHR                Non-null -> print character
                   LDAA      #$20                   Replace null padding with space (' ')
PFN_CHR            JSR       >PUTCHR                Output character
                   DECB                             Decrement remaining char count
                   BEQ       PFN_END                All 11 chars printed -> finish
                   CMPB      #$03                   Are 3 characters (extension) remaining?
                   BNE       PFN_LP                 No -> continue loop
                   LDAA      #$2E                   Yes -> print '.' separator
                   JSR       >PUTCHR                
                   BRA       PFN_LP                 Print the 3 extension characters

PFN_END            LDAA      #$20                   Print trailing space
                   JSR       >PUTCHR                
                   PULS      A,B,X,PCR              

* ==============================================================================
* SUBROUTINE: TRACE_CHAIN ($0424)
* Entry: D = Starting Track (A) and Sector (B) of chain
* ==============================================================================

TRACE_CHAIN        CLR       >PRGCNTR,PCR           Clear progress indicator counter
TC_LOOP            BSR       SET_BIT                Test & set bit for T/S in D in active bitmap
                   BEQ       TC_READ                Bit was 0 (not yet visited) -> continue normally

* Collision detected! This sector was already visited in this map:

                   CLR       >COLLFLG,PCR           Clear single-file clean flag ($528C = 0)
                   PSHS      A,B                    Push colliding T/S onto stack
                   LEAX      >MSG_INTER,PCR         Print "............Intersection at - "
                   JSR       >PSTRNG                
                   LEAX      ,S                     Point X to T/S on stack
                   JSR       >OUTADR                Print hex Track/Sector of intersection
                   PULS      A,B                    Restore T/S into D,0,E,
TC_READ            BSR       READ_SEC               Read sector T/S (in D) into buffer ($5180)
                   INC       >PRGCNTR,PCR           Increment sector progress counter
                   BNE       TC_NEXT                Every 256 sectors...
                   LDAA      #$2B                   ...print '+' progress indicator
                   JSR       >PUTCHR                
TC_NEXT            LDD       >SCT_BUFF,PCR          Load next Track/Sector link from bytes 0-1 of sector
                   BNE       TC_LOOP                If link != 00/00, follow chain to next sector
                   RTS                              End of chain ($0000) reached


* ==============================================================================
* SUBROUTINE: SET_BIT ($0454)
* Entry: D = Track/Sector (16-bit index 0..65535), MAP_BASE = Bitmap base address
* Exit:  Z flag = 1 if bit was previously 0; Z flag = 0 if bit was already 1
* ==============================================================================

SET_BIT            PSHS      A,B,X                  
                   BSR       CALC_BIT               Convert D into X = byte offset (D/8) and A = bitmask
                   PSHS      A                      Save bitmask on stack
                   LDD       >BITMAPBASE,PCR        Get active bitmap base ($1000 or $3000)
                   LEAX      D,X                    X = exact memory address of byte in bitmap
                   PULS      A                      Restore bitmask into A
                   TFR       A,B                    Copy bitmask to B
                   ANDA      ,X                     Test if bit is already set (sets CPU Z flag)
                   ORAB      ,X                     Set the bit in B
                   STAB      ,X                     Write updated byte back to bitmap
                   TSTA                             Set Z flag based on prior state of the bit
                   PULS      A,B,X,PCR              

* ==============================================================================
* SUBROUTINE: CALC_BIT ($046D)
* Entry: D = 16-bit value (Track:Sector)
* Exit:  X = D >> 3 (byte offset 0..8191), A = 1 << (D & 7) (bitmask)
* ==============================================================================

CALC_BIT           PSHS      B                      Save low byte (Sector)
                   LSRA                             Divide 16-bit D by 2
                   RORB                             
                   LSRA                             Divide by 4
                   RORB                             
                   LSRA                             Divide by 8
                   RORB                             
                   TFR       D,X                    X = byte offset into 8KB bitmap
                   PULS      B                      Restore low byte
                   LDAA      #$01                   Start bitmask at bit 0 ($01)
                   ANDB      #$07                   Isolate lower 3 bits (bit index 0..7)
CB_SHIFT           BEQ       CB_DONE                Shift complete
                   ASLA                             Shift bitmask left by 1
                   DECB                             
                   BRA       CB_SHIFT               

CB_DONE            RTS                              


* ==============================================================================
* SUBROUTINE: READ_SEC ($0484)
* Entry: D = Track (A) and Sector (B)
* ==============================================================================

READ_SEC           PSHS      A,B,X                  
                   LEAX      >RAW_FCB,PCR           Point X to Raw Sector FCB ($5140)
                   STD       30,X                   Store Track/Sector at FCB+30 ($515E)
                   LDAA      #$09                   FMS Function $09: Read Single Sector
                   STAA      ,X                     
                   JSR       >FMSCALL               Execute read into FCB buffer ($5180)
                   BEQ       RS_OK                  No error -> return
                   JSR       >RPTERR                Report disk read error
                   JMP       >WARMS                 Abort to FLEX

RS_OK              PULS      A,B,X,PCR              

* ==============================================================================
* SUBROUTINE: WRITE_SEC ($049E)
* Entry: D = Track (A) and Sector (B)
* ==============================================================================

WRITE_SEC          PSHS      A,B,X                  
                   LEAX      >RAW_FCB,PCR           Point X to Raw Sector FCB ($5140)
                   STD       30,X                   Store Track/Sector at FCB+30 ($515E)
                   LDAA      #$0A                   FMS Function $0A: Write Single Sector
                   STAA      ,X                     
                   JSR       >FMSCALL               Write buffer ($5180) to disk
                   BEQ       WS_OK                  No error -> return
                   JSR       >RPTERR                Report disk write error
                   JMP       >WARMS                 Abort to FLEX

WS_OK              PULS      A,B,X,PCR              

* ==============================================================================
* MESSAGES & STRINGS ($04B8 - $066B)
* ==============================================================================

MSG_DRV            FCB       $0D
                   FCB       $0A
                   FCC       'Drive number to check ? '
                   FCB       $04
MSG_RANGE          FCB       $0D
                   FCB       $0A
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
MSG_INTF           FCC       'Total number files intersected -'
                   FCC       ' '
                   FCB       $04
MSG_INTT           FCB       $0D
                   FCC       'Total number of intersections  -'
                   FCC       ' '
                   FCB       $04
MSG_MISST          FCB       $0D
                   FCC       'Total number of missed sectors -'
                   FCC       ' '
                   FCB       $04
MSG_ASKFIX         FCB       $0A
                   FCB       $0D
                   FCC       'Relink the free chain (Y/N) '
                   FCB       $04
MSG_RELINK         FCB       $0A
                   FCB       $0D
                   FCC       'Relinking the free chain.'
                   FCB       $0A
                   FCB       $0D
                   FCB       $04
MSG_DONE           FCB       $0A
                   FCB       $0D
                   FCC       'Chain fix program complete.'
                   FCB       $0A
                   FCB       $0D
                   FCB       $0A
                   FCB       $0D
                   FCB       $04


*
* External References
*
L0000              EQU      $0000
L0001              EQU      $0001
L0002              EQU      $0002
L0003              EQU      $0003
L0004              EQU      $0004
L1000              EQU      $1000
L3000              EQU      $3000
DIR_FCB            EQU      $5000
DIR_DRV_NO         EQU      $5003
DIR_FNAME          EQU      $5004
STRT_TS            EQU      $5011
END_TS             EQU      $5013
RAW_FCB            EQU      $5140
DRV_NO             EQU      $5143
LST_TS             EQU      $515E
SCT_BUFF           EQU      $5180
SIR_STRT_FC        EQU      $519D
SIR_END_FC         EQU      $519F
SIR_FS_CNT         EQU      $51A1
SIR_MT_MS          EQU      $51A6
ENDBITMAPADDR      EQU      $5280
FS_TAIL_TS         EQU      $5282
TOTFREESECT        EQU      $5284
BITMAPBASE         EQU      $5286
MAX_TS             EQU      $5288
MAX_SCT            EQU      $5289
INTFILCNT          EQU      $528A
COLLFLG            EQU      $528C
TOTINTCNT          EQU      $528D
COLLCNT            EQU      $528F
PRGCNTR            EQU      $5291
LINWRPCNTR         EQU      $5292
LINBUF             EQU      $C080
SYSFCB             EQU      $C840
TTYBS              EQU      $CC00
TTYDEL             EQU      $CC01
TTYEOL             EQU      $CC02
TTYDP              EQU      $CC03
TTYWD              EQU      $CC04
TTYNL              EQU      $CC05
TTYTB              EQU      $CC06
TTYBE              EQU      $CC07
TTYEJ              EQU      $CC08
TTYPS              EQU      $CC09
TTYESC             EQU      $CC0A
SYSDRV             EQU      $CC0B
WRKDRV             EQU      $CC0C
SYSMTH             EQU      $CC0E
SYSDAY             EQU      $CC0F
SYSYR              EQU      $CC10
LSTTRM             EQU      $CC11
UCMDTB             EQU      $CC12
LINPTR             EQU      $CC14
ESCRET             EQU      $CC16
CURCHR             EQU      $CC18
PRVCHR             EQU      $CC19
CURLIN             EQU      $CC1A
LDROFF             EQU      $CC1B
XFERFG             EQU      $CC1D
XFERAD             EQU      $CC1E
ERRTYP             EQU      $CC20
SPECIO             EQU      $CC21
OUTSW              EQU      $CC22
INSW               EQU      $CC23
OUTFIL             EQU      $CC24
INFIL              EQU      $CC26
CMDFLG             EQU      $CC28
CURCLM             EQU      $CC29
MEMEND             EQU      $CC2B
ERRVEC             EQU      $CC2D
FILEKO             EQU      $CC2F
CPUTYP             EQU      $CC33
PRTADR             EQU      $CC35
PRTLNG             EQU      $CC37
PRTDVC             EQU      $CC39
PINIT              EQU      $CCC0
PCHK               EQU      $CCD8
POUT               EQU      $CCE4
COLDS              EQU      $CD00
WARMS              EQU      $CD03
RENTER             EQU      $CD06
INCH               EQU      $CD09
INCH2              EQU      $CD0C
OUTCH              EQU      $CD0F
OUTCH2             EQU      $CD12
GETCHR             EQU      $CD15
PUTCHR             EQU      $CD18
INBUFF             EQU      $CD1B
PSTRNG             EQU      $CD1E
CLASS              EQU      $CD21
PCRLF              EQU      $CD24
NXTCH              EQU      $CD27
RSTRIO             EQU      $CD2A
GETFIL             EQU      $CD2D
LOAD               EQU      $CD30
SETEXT             EQU      $CD33
ADDBX              EQU      $CD36
OUTDEC             EQU      $CD39
OUTHEX             EQU      $CD3C
RPTERR             EQU      $CD3F
GETHEX             EQU      $CD42
OUTADR             EQU      $CD45
INDEC              EQU      $CD48
DOCMND             EQU      $CD4B
STAT               EQU      $CD4E
FMSINT             EQU      $D400
FMSCLS             EQU      $D403
FMSCALL            EQU      $D406
ACCIA              EQU      $E004
LFFF8              EQU      $FFF8

                   END      START
