;-----------------------------------------------------------------------
; TNFSD.COM v0.3 -- a TNFS server for CP/M 2.2, through FujiNet.
;
;       TNFSD                   serve the current drive, current user
;
; Another CP/M machine (or anything with a FujiNet) reaches this one's
; files with FUJIGET, FUJIPUT and FUJIDIR:
;
;       FUJIDIR N1:TNFS://<this machine's FujiNet IP>/
;       FUJIGET N1:TNFS://<ip>/NAME.EXT NAME.EXT
;       FUJIPUT NAME.EXT N1:TNFS://<ip>/NAME.EXT
;
; ONE DRIVE, NO FOLDERS: the TNFS root "/" is the drive TNFSD was
; started on, in the current user area. TNFSD uses BDOS file calls
; only. BDOS has no safe way to find which other drives exist (a
; missing drive gives "BDOS ERR ON x: SELECT" and a warm boot), and
; BIOS calls differ between the many home-made BIOSes.
;
; README.md, beside this file, lists the limits and how it was tested.
;
; TRANSPORT: TCP. FujiNet's TNFS client tries TCP on port 16384 first
; (fujinet-firmware lib/TNFSlib/tnfslib.cpp, _tnfs_send). UDP does not
; keep datagram boundaries on the RS232 N: device (tested live).
; One client at a time. TCP does not keep packet boundaries either, so
; RQLEN finds each request's end from its own structure.
;
; COMMANDS: MOUNT, UNMOUNT, STAT, OPEN, READ, WRITE, CLOSE, OPENDIRX,
; READDIRX, CLOSEDIR -- the ten a real FujiNet sent for FUJIGET, FUJIDIR
; and FUJIPUT. The rest are parsed, to stay in step with the stream,
; and answered 16H (not implemented). Nothing here deletes a file on
; request. The one delete is inside OPEN: an overwrite (the client's
; TRUNCATE flag -- FUJIPUT asks "Replace?" first) is BDOS delete, then
; make, because CP/M 2.2 has no truncate.
;
; DIRECTORY CACHE: the drive's directory is scanned once at startup
; and again only after a file written through TNFSD is closed -- CP/M
; runs one program at a time, so nothing else can change the drive
; meanwhile. A listing needs no disk access. See SCAN.
;
; CP/M FILES ARE RECORDS: a file's size is a multiple of 128 bytes, and
; the last record's unused bytes are whatever was written (usually ^Z).
;
; CONSOLE: a line when a client connects and disconnects, and one per
; file sent or received (a dot per KB as it goes, then the byte count).
; When a connection ends, SUMMRY reports a directory listing (only if
; the client opened no file) and a failed read-open ("NAME: not
; found."). Ctrl-C closes any open files and exits.
;
; Assemble it INSIDE the machine:
;
;       ASM TNFSD               -> TNFSD.HEX
;       LOAD TNFSD              -> TNFSD.COM
;
; THIS PROGRAM TALKS DIRECTLY TO THE 2SIO CARD FOR FUJINET, and to BDOS
; for files and the console. BDOS CLOBBERS EVERY REGISTER (A,B,C,D,E,
; H,L -- only SP survives). Nothing may be left live across CALL BDOS.
;-----------------------------------------------------------------------

        ORG     100H

;---- CP/M --------------------------------------------------------------
BDOS    EQU     0005H

CONOUT  EQU     2               ; E = char
DIRIO   EQU     6               ; E=0FFH polls input (A=0 if none ready)
PRSTR   EQU     9               ; DE = string, '$'-terminated
FOPEN   EQU     15              ; DE = FCB; A=0FFH not found
FCLOSE  EQU     16
FSRCHF  EQU     17              ; search first; A = 0-3 index into DMA, 0FFH none
FSRCHN  EQU     18              ; search next
FDEL    EQU     19
FMAKE   EQU     22              ; A=0FFH directory full
GETDSK  EQU     25              ; A = current drive, 0=A
SETDMA  EQU     26              ; DE = DMA address
GETUSR  EQU     32              ; E=0FFH: A = current user
RDRAN   EQU     33              ; read random: A<>0 = no data there
WRRAN   EQU     34              ; write random: A<>0 = error (disk full, ...)
FSIZE   EQU     35              ; FCB r0-r2 = size in records

CR      EQU     0DH
LF      EQU     0AH
CTRLC   EQU     03H
CPMEOF  EQU     1AH

; FCB offsets
FCBEX   EQU     12
FCBR0   EQU     33
FCBLEN  EQU     36

;---- The 2SIO card, unit b ---------------------------------------------
SIOST   EQU     12H             ; status (IN) / control (OUT)
SIODT   EQU     13H             ; data, both ways
SIORST  EQU     03H             ; master reset
SIOCTL  EQU     15H             ; /16, 8N1, no interrupts

;---- The FujiNet RS232 wire protocol -----------------------------------
NETDEV  EQU     71H             ; the first network device slot
CMDOPEN EQU     4FH
CMDCLOS EQU     43H
CMDREAD EQU     52H
CMDWRIT EQU     57H
CMDSTAT EQU     53H
CMDACPT EQU     41H             ; NET_CONTROL: accept the waiting client
CMDCCLI EQU     63H             ; NET_CLOSE_CLIENT: drop the client
ACKCMD  EQU     06H

ACCRW   EQU     0CH             ; access mode: read/write
TRANONE EQU     00H             ; translation: none (binary)

SLPEND  EQU     0C0H
SLPESC  EQU     0DBH
SLPEEND EQU     0DCH
SLPEESC EQU     0DDH

NETMAX  EQU     512             ; largest single FujiNet READ

;---- TNFS --------------------------------------------------------------
TMOUNT  EQU     00H
TUMOUNT EQU     01H
TCLOSDR EQU     12H
TOPENDX EQU     17H
TREADDX EQU     18H
TREAD   EQU     21H
TWRITE  EQU     22H
TCLOSE  EQU     23H
TSTAT   EQU     24H
TOPEN   EQU     29H

EOK     EQU     00H
ENOENT  EQU     02H             ; file not found
EIO     EQU     03H
EBADF   EQU     06H             ; bad handle
EACCES  EQU     09H
EEXIST  EQU     0BH
ENOTDIR EQU     0CH
EISDIR  EQU     0DH
EINVAL  EQU     0EH
EMFILE  EQU     10H             ; too many files open
ENOSPC  EQU     12H
ENOSYS  EQU     16H             ; not implemented
EEOF    EQU     21H

; OPEN flags: low byte READ=01H WRITE=02H APPEND=08H; high byte
; CREATE=01H TRUNCATE=02H EXCLUSIVE=04H.
OWRITE  EQU     02H
OAPPEND EQU     08H
OCREATE EQU     01H
OTRUNC  EQU     02H
OEXCL   EQU     04H

MAXSTR  EQU     128             ; longest string field accepted
MAXIO   EQU     512             ; most bytes one READ reply carries
MAXWR   EQU     525             ; most bytes one WRITE request carries
NHAND   EQU     4               ; file handles
DIRMAX  EQU     255             ; files the directory cache holds
DIRENT  EQU     13              ; table entry: name(11) + records(2)
DXPER   EQU     16              ; entries per READDIRX reply
RXQMAX  EQU     1100            ; the TCP stream queue

;=======================================================================
; MAIN
;=======================================================================
START:  LXI     SP,STACK
        XRA     A               ; RAM isn't guaranteed to power up zeroed
        LXI     H,VARS
        LXI     B,VARSEND-VARS
ZV:     MOV     M,A
        INX     H
        DCX     B
        MOV     A,B
        ORA     C
        MVI     A,0
        JNZ     ZV
        LXI     H,1
        SHLD    NXTSID

        LXI     D,DMABUF        ; every BDOS disk call uses DMABUF
        MVI     C,SETDMA
        CALL    BDOS
        MVI     C,GETDSK
        CALL    BDOS
        STA     CURDSK
        MVI     E,0FFH
        MVI     C,GETUSR
        CALL    BDOS
        STA     CURUSR

        MVI     A,SIORST        ; the ACIA out of reset...
        OUT     SIOST
        MVI     A,SIOCTL        ; ...and into a real operating mode
        OUT     SIOST

        LXI     D,MBAN1         ; "TNFSD v0.1: serving drive "
        MVI     C,PRSTR
        CALL    BDOS
        LDA     CURDSK
        ADI     'A'
        MOV     E,A
        MVI     C,CONOUT
        CALL    BDOS
        LXI     D,MBAN2         ; ": user "
        MVI     C,PRSTR
        CALL    BDOS
        LDA     CURUSR
        MOV     L,A
        MVI     H,0
        CALL    PDEC
        LXI     D,MBAN3         ; " on TCP 16384. Ctrl-C quits."
        MVI     C,PRSTR
        CALL    BDOS

        CALL    SCAN            ; the directory cache
        LDA     DIRCNT          ; "N files cached. Ctrl-C quits."
        MOV     L,A
        MVI     H,0
        CALL    PDEC
        LXI     D,MSCAN2        ; " files."
        MVI     C,PRSTR
        CALL    BDOS

        CALL    MKOPEN          ; listen: N1:TCP://:16384/
        LXI     H,CTLBUF
        CALL    SENDPK
        CALL    RECVPK
        LDA     RXBUF+1
        CPI     ACKCMD
        JZ      LLOOP
        LXI     D,MFAIL
        MVI     C,PRSTR
        CALL    BDOS
        JMP     0

;-----------------------------------------------------------------------
; LLOOP -- listening. STATUS connected=1 means a client is waiting.
;-----------------------------------------------------------------------
LLOOP:  CALL    CKCTLC
        CALL    NSTAT
        LDA     RXBUF+8         ; connected (here: a client is waiting)
        ORA     A
        JZ      LLOOP
        MVI     A,CMDACPT
        CALL    NBARE
        LDA     RXBUF+1
        CPI     ACKCMD
        JNZ     LLOOP           ; it went away again
        XRA     A               ; a fresh session
        STA     SIDOK
        STA     LASTV
        STA     DIROPN
        STA     PERR
        STA     CLIST
        STA     COPEN
        STA     NFFLAG
        LXI     H,0
        SHLD    RXQLEN
        LXI     D,MCONN
        MVI     C,PRSTR
        CALL    BDOS

;-----------------------------------------------------------------------
; CLOOP -- a client is connected. Queue what it sends, answer every
; whole request in the queue. Nothing waiting and connected=0 means it
; closed.
;-----------------------------------------------------------------------
CLOOP:  CALL    CKCTLC
        CALL    NSTAT
        LHLD    RXBUF+6         ; bytes waiting
        MOV     A,H
        ORA     L
        JZ      CIDLE
        CALL    FILLQ
        CALL    PROCQ
        LDA     PERR
        ORA     A
        JNZ     CPERR
        JMP     CLOOP
CIDLE:  LDA     RXBUF+8
        ORA     A
        JNZ     CLOOP
        LXI     D,MCLOSE        ; the client closed
        JMP     ENDCL
CPERR:  LXI     D,MPERR         ; a request we can't parse -- drop it
ENDCL:  PUSH    D               ; close files first: that ends any
        CALL    CLSALL          ; transfer line with its byte count
        CALL    SUMMRY
        POP     D
        MVI     C,PRSTR
        CALL    BDOS
        MVI     A,CMDCCLI
        CALL    NBARE
        JMP     LLOOP

;-----------------------------------------------------------------------
; SUMMRY -- the end of a connection. FujiNet lists the directory and
; tries a read-open as part of its own GET and PUT, so a listing is
; reported only when the client opened no file (a real directory
; listing), and a failed read-open as "NAME: not found." (for a PUT
; that is its does-it-exist check).
;-----------------------------------------------------------------------
SUMMRY: LDA     NFFLAG
        ORA     A
        JZ      SUM1
        MVI     A,' '
        CALL    PCHAR
        MVI     A,' '
        CALL    PCHAR
        LXI     H,NFNAME
        CALL    PNAME
        LXI     D,MNOTFD
        MVI     C,PRSTR
        CALL    BDOS
SUM1:   LDA     CLIST
        ORA     A
        RZ
        LDA     COPEN
        ORA     A
        RNZ
        LXI     D,MLIST         ; "  Directory listed: N files."
        MVI     C,PRSTR
        CALL    BDOS
        LDA     LSTCNT
        MOV     L,A
        MVI     H,0
        CALL    PDEC
        LXI     D,MLIST2
        MVI     C,PRSTR
        JMP     BDOS

;-----------------------------------------------------------------------
; CKCTLC -- if Ctrl-C was typed: close files, the client, the listener,
; and exit to CP/M.
;-----------------------------------------------------------------------
CKCTLC: MVI     E,0FFH
        MVI     C,DIRIO
        CALL    BDOS
        CPI     CTRLC
        RNZ
        CALL    CLSALL
        MVI     A,CMDCCLI
        CALL    NBARE
        MVI     A,CMDCLOS
        CALL    NBARE
        LXI     D,MQUIT
        MVI     C,PRSTR
        CALL    BDOS
        JMP     0

;=======================================================================
; THE REQUEST QUEUE
;=======================================================================

; FILLQ -- READ min(bytes waiting, NETMAX, room left) into the queue.
FILLQ:  LHLD    RXBUF+6
        SHLD    NREQ
        LXI     D,NETMAX        ; NREQ = min(NREQ, NETMAX)
        CALL    MINW
        LHLD    RXQLEN          ; DE = room = RXQMAX - RXQLEN
        XCHG
        LXI     H,RXQMAX
        MOV     A,L
        SUB     E
        MOV     E,A
        MOV     A,H
        SBB     D
        MOV     D,A
        CALL    MINW
        LHLD    NREQ
        MOV     A,H
        ORA     L
        RZ                      ; no room -- PROCQ will call it an error
        CALL    MKREAD
        LXI     H,CTLBUF
        CALL    SENDPK
        CALL    RECVPK
        LDA     RXBUF+1
        CPI     ACKCMD
        RNZ
        LHLD    RXQLEN          ; DE = RXQ + RXQLEN
        LXI     D,RXQ
        DAD     D
        XCHG
        LHLD    NREQ
        MOV     B,H
        MOV     C,L
        LXI     H,RXBUF+6
        CALL    MOVE
        LHLD    RXQLEN
        XCHG
        LHLD    NREQ
        DAD     D
        SHLD    RXQLEN
        RET

; MINW -- NREQ = min(NREQ, DE).
MINW:   LHLD    NREQ
        MOV     A,L
        SUB     E
        MOV     A,H
        SBB     D
        RC                      ; NREQ < DE
        XCHG
        SHLD    NREQ
        RET

; PROCQ -- answer every whole request at the front of the queue.
PROCQ:  CALL    RQLEN
        ORA     A
        JZ      PQ1
        CPI     1
        RZ                      ; the rest hasn't arrived yet
        MVI     A,1             ; can't be parsed
        STA     PERR
        RET
PQ1:    SHLD    CURLEN
        CALL    HANDLE
        CALL    SHIFTQ
        JMP     PROCQ

; SHIFTQ -- drop the CURLEN bytes just handled from the queue.
SHIFTQ: LHLD    CURLEN
        XCHG
        LHLD    RXQLEN
        MOV     A,L
        SUB     E
        MOV     C,A
        MOV     A,H
        SBB     D
        MOV     B,A             ; BC = bytes left
        MOV     H,B
        MOV     L,C
        SHLD    RXQLEN
        LHLD    CURLEN
        LXI     D,RXQ
        DAD     D               ; HL = RXQ + CURLEN
        LXI     D,RXQ
        JMP     MOVE            ; tail call

;-----------------------------------------------------------------------
; RQLEN -- is there a whole request at the front of the queue?
; A=0: yes, HL = its length. A=1: not yet. A=2: can't tell (unknown
; command, or a string longer than MAXSTR) -- the stream is lost.
; The same rules as request_length() in cpm-tnfs-ref.py.
;-----------------------------------------------------------------------
RQLEN:  LXI     H,4
        CALL    HAVE
        JC      RQMORE
        LDA     RXQ+3           ; the command
        CPI     TUMOUNT
        JZ      RQF4
        CPI     30H             ; SIZE, FREE, SIZE_BYTES, FREE_BYTES
        JC      RQA
        CPI     34H
        JC      RQF4
RQA:    CPI     11H             ; READDIR
        JZ      RQF5
        CPI     TCLOSDR
        JZ      RQF5
        CPI     15H             ; TELLDIR
        JZ      RQF5
        CPI     TCLOSE
        JZ      RQF5
        CPI     16H             ; SEEKDIR
        JZ      RQF9
        CPI     TREADDX
        JZ      RQF6
        CPI     TREAD
        JZ      RQF7
        CPI     25H             ; LSEEK
        JZ      RQF10
        CPI     TMOUNT
        JZ      RQMNT
        CPI     10H             ; OPENDIR
        JZ      RQS41
        CPI     13H             ; MKDIR
        JZ      RQS41
        CPI     14H             ; RMDIR
        JZ      RQS41
        CPI     TSTAT
        JZ      RQS41
        CPI     26H             ; UNLINK
        JZ      RQS41
        CPI     TOPENDX
        JZ      RQS82
        CPI     TOPEN
        JZ      RQS81
        CPI     27H             ; CHMOD
        JZ      RQS61
        CPI     28H             ; RENAME
        JZ      RQS42
        CPI     TWRITE
        JZ      RQWR
        MVI     A,2             ; unknown -- no way to tell its length
        RET

RQF4:   LXI     H,4
        JMP     RQFIX
RQF5:   LXI     H,5
        JMP     RQFIX
RQF6:   LXI     H,6
        JMP     RQFIX
RQF7:   LXI     H,7
        JMP     RQFIX
RQF9:   LXI     H,9
        JMP     RQFIX
RQF10:  LXI     H,10
RQFIX:  PUSH    H
        CALL    HAVE
        POP     H
        JC      RQMORE
        XRA     A
        RET
RQMORE: MVI     A,1
        RET

RQMNT:  LXI     H,6             ; version(2), then path, user, password
        MVI     B,3
        JMP     SKPN
RQS41:  LXI     H,4             ; path
        MVI     B,1
        JMP     SKPN
RQS42:  LXI     H,4             ; from, to
        MVI     B,2
        JMP     SKPN
RQS61:  LXI     H,6             ; mode(2), path
        MVI     B,1
        JMP     SKPN
RQS81:  LXI     H,8             ; flags(2), perms(2), path
        MVI     B,1
        JMP     SKPN
RQS82:  LXI     H,8             ; diropt, sortopt, max(2), pattern, path
        MVI     B,2
        JMP     SKPN

RQWR:   LXI     H,7             ; handle, len(2), then len bytes of data
        CALL    HAVE
        JC      RQMORE
        LHLD    RXQ+5
        LXI     D,MAXWR+1       ; len > MAXWR can't be a real request
        MOV     A,L
        SUB     E
        MOV     A,H
        SBB     D
        JNC     RQBAD
        LXI     D,7
        DAD     D
        JMP     RQFIX
RQBAD:  MVI     A,2
        RET

; SKPN -- skip B NUL-terminated strings starting at queue offset HL.
; Returns as RQLEN does.
SKPN:   CALL    SKPSTR
        ORA     A
        RNZ
        DCR     B
        JNZ     SKPN
        RET                     ; A=0, HL = the length

; SKPSTR -- HL = queue offset of a string. A=0: HL = offset just past
; its NUL. A=1: the NUL hasn't arrived. A=2: longer than MAXSTR.
; Preserves B.
SKPSTR: MVI     C,MAXSTR+1
SKS1:   PUSH    H
        INX     H               ; is offset HL inside the queue?
        CALL    HAVE
        POP     H
        JC      RQMORE
        PUSH    H
        LXI     D,RXQ
        DAD     D
        MOV     A,M
        POP     H
        INX     H
        ORA     A
        RZ                      ; the NUL -- A=0
        DCR     C
        JNZ     SKS1
        MVI     A,2
        RET

; HAVE -- CY set if the queue holds fewer than HL bytes. Keeps B,C.
HAVE:   XCHG
        LHLD    RXQLEN
        MOV     A,L
        SUB     E
        MOV     A,H
        SBB     D
        XCHG
        RET

;=======================================================================
; ANSWERING ONE REQUEST -- the request is at RXQ. Its reply is built
; straight into the payload of the FujiNet WRITE packet (TXBUF+8, from
; REPLY on), so a retry can be answered by sending TXBUF again.
;=======================================================================
HANDLE: LDA     LASTV           ; a retry of the last request?
        ORA     A
        JZ      HNEW
        LDA     SIDOK
        ORA     A
        JZ      HNEW
        LHLD    RXQ
        XCHG
        LHLD    CURSID
        MOV     A,L
        CMP     E
        JNZ     HNEW
        MOV     A,H
        CMP     D
        JNZ     HNEW
        LDA     LASTSQ
        MOV     B,A
        LDA     RXQ+2
        CMP     B
        JNZ     HNEW
        LDA     LASTCM
        MOV     B,A
        LDA     RXQ+3
        CMP     B
        JNZ     HNEW
        JMP     SNDREP          ; a retry: send the same reply again

HNEW:   LXI     H,REPLY         ; the reply header echoes the request's
        SHLD    RPPTR
        LDA     RXQ
        CALL    EMIT
        LDA     RXQ+1
        CALL    EMIT
        LDA     RXQ+2
        CALL    EMIT
        LDA     RXQ+3
        CALL    EMIT

        LDA     RXQ+3
        CPI     TMOUNT
        JZ      DMOUNT
        LDA     SIDOK           ; every other command needs this session
        ORA     A
        JZ      DNOSES
        LHLD    RXQ
        XCHG
        LHLD    CURSID
        MOV     A,L
        CMP     E
        JNZ     DNOSES
        MOV     A,H
        CMP     D
        JNZ     DNOSES
        LDA     RXQ+3
        CPI     TUMOUNT
        JZ      DUMNT
        CPI     TSTAT
        JZ      DSTAT
        CPI     TOPEN
        JZ      DOPEN
        CPI     TREAD
        JZ      DREAD
        CPI     TWRITE
        JZ      DWRITE
        CPI     TCLOSE
        JZ      DCLOSE
        CPI     TOPENDX
        JZ      DOPNDX
        CPI     TREADDX
        JZ      DRDDX
        CPI     TCLOSDR
        JZ      DCLSDR
        MVI     B,'?'
        MVI     A,ENOSYS
        JMP     REPST

DNOSES: MVI     B,'!'
        MVI     A,EINVAL
        JMP     REPST

; REPST -- reply with just a status: A = status, B = the trace char.
REPST:  PUSH    PSW
        MOV     A,B
        STA     TRCH
        POP     PSW
        CALL    EMIT
        JMP     SEND

; OKST -- reply status 0, trace char in B; handlers then emit payload.
OKST:   MOV     A,B
        STA     TRCH
        XRA     A
        JMP     EMIT            ; tail call

;-----------------------------------------------------------------------
; SEND -- send the reply (REPLY up to RPPTR) as one FujiNet WRITE.
;-----------------------------------------------------------------------
SEND:   LXI     H,TXBUF
        MVI     M,NETDEV
        INX     H
        MVI     M,CMDWRIT
        LXI     H,TXBUF+5
        MVI     M,5             ; descr: one 2-byte param (the length)
        LHLD    RPPTR           ; length = RPPTR - REPLY
        LXI     D,0-REPLY
        DAD     D
        SHLD    TXBUF+6
        LHLD    RPPTR
        LXI     D,TXBUF
        CALL    SETLEN
        LDA     RXQ+2           ; for spotting a retry
        STA     LASTSQ
        LDA     RXQ+3
        STA     LASTCM
        MVI     A,1
        STA     LASTV
SNDREP: LXI     H,TXBUF
        CALL    SENDPK
        JMP     RECVPK          ; the WRITE's ACK

;-----------------------------------------------------------------------
; MOUNT -- a new session. Reply: status, version 1.2 (minor first --
; the client refuses anything older), retry 1000 ms.
;-----------------------------------------------------------------------
DMOUNT: CALL    CLSALL
        LHLD    NXTSID
        SHLD    CURSID
        SHLD    REPLY           ; the reply carries the new session id
        INX     H
        MOV     A,H
        ORA     L
        JNZ     DM1
        INX     H               ; skip 0
DM1:    SHLD    NXTSID
        MVI     A,1
        STA     SIDOK
        MVI     B,'M'
        CALL    OKST
        MVI     A,02H
        CALL    EMIT
        MVI     A,01H
        CALL    EMIT
        MVI     A,0E8H
        CALL    EMIT
        MVI     A,03H
        CALL    EMIT
        JMP     SEND

DUMNT:  CALL    CLSALL
        MVI     B,'U'
        CALL    OKST
        JMP     SEND

;-----------------------------------------------------------------------
; STAT -- mode, uid, gid, size, atime, mtime, ctime, two empty names.
; CP/M 2.2 keeps no times, so all three are 0.
;-----------------------------------------------------------------------
DSTAT:  LXI     H,RXQ+4
        CALL    PARSEP
        CPI     1
        JZ      DSTRT
        ORA     A
        JNZ     DSTNO
        LXI     D,TFCB          ; does it exist?
        MVI     C,FSRCHF
        CALL    BDOS
        INR     A
        JZ      DSTNO
        LXI     D,TFCB
        CALL    RECSOF
        MVI     B,'S'
        CALL    OKST
        MVI     A,0A4H          ; mode 81A4: a file, rw-r--r--
        CALL    EMIT
        MVI     A,81H
        CALL    EMIT
        MVI     B,4             ; uid, gid
        CALL    EMITZ
        CALL    EMSIZE
        MVI     B,14            ; three times, two names
        CALL    EMITZ
        JMP     SEND
DSTRT:  MVI     B,'S'           ; the root: a directory
        CALL    OKST
        MVI     A,0EDH          ; mode 41ED
        CALL    EMIT
        MVI     A,41H
        CALL    EMIT
        MVI     B,22
        CALL    EMITZ
        JMP     SEND
DSTNO:  MVI     B,'S'
        MVI     A,ENOENT
        JMP     REPST

;-----------------------------------------------------------------------
; OPEN -- flags(2), perms(2), path. Reply: status, handle (1-4).
;-----------------------------------------------------------------------
DOPEN:  MVI     A,1             ; for SUMMRY: this was not just a listing
        STA     COPEN
        LXI     H,RXQ+8
        CALL    PARSEP
        CPI     1
        JZ      DOPISD
        ORA     A
        JNZ     DOPBAD
        LXI     H,HUSED         ; a free handle?
        MVI     B,0
DOP1:   MOV     A,M
        ORA     A
        JZ      DOP2
        INX     H
        INR     B
        MOV     A,B
        CPI     NHAND
        JC      DOP1
        LXI     D,MTOOMN
        MVI     C,PRSTR
        CALL    BDOS
        MVI     B,'O'
        MVI     A,EMFILE
        JMP     REPST
DOP2:   MOV     A,B
        CALL    SETH
        CALL    TFCBH           ; the handle's FCB = TFCB
        LHLD    HPOSP           ; position 0
        XRA     A
        MOV     M,A
        INX     H
        MOV     M,A
        INX     H
        MOV     M,A

        LDA     RXQ+4
        ANI     OWRITE
        JNZ     DOPW
        MVI     C,FOPEN         ; for reading: it must exist
        CALL    BDOSH
        INR     A
        JZ      DOPNO
        XRA     A
        JMP     DOPOK

DOPW:   MVI     C,FOPEN         ; for writing
        CALL    BDOSH
        INR     A
        JZ      DOPNEW
        LDA     RXQ+5           ; it exists
        ANI     OCREATE+OEXCL
        CPI     OCREATE+OEXCL
        JZ      DOPEX
        LDA     RXQ+5
        ANI     OTRUNC
        JZ      DOPAPP
        MVI     C,FDEL          ; truncate: delete, then make it again
        CALL    BDOSH
        CALL    TFCBH
DOPMK:  MVI     C,FMAKE
        CALL    BDOSH
        INR     A
        JZ      DOPFUL
DOPAPP: LDA     RXQ+4           ; APPEND: start at the end
        ANI     OAPPEND
        JZ      DOPWOK
        LHLD    HFCBP
        XCHG
        CALL    RECSOF
        LHLD    HPOSP           ; position = records * 128
        LDA     RECS
        ORA     A               ; CY=0
        RAR
        MOV     B,A             ; RECS lo >> 1
        MVI     A,0
        RAR
        MOV     M,A             ; P0 = (RECS lo bit 0) << 7
        LDA     RECS+1
        RAR
        MOV     C,A             ; RECS hi >> 1, CY = hi bit 0
        MOV     A,B
        JNC     DOPA1
        ORI     80H
DOPA1:  INX     H
        MOV     M,A             ; P1
        INX     H
        MOV     M,C             ; P2
DOPWOK: MVI     A,1
DOPOK:  MOV     B,A             ; B = writable
        LXI     H,HWR
        CALL    HIDX
        MOV     M,B
        LXI     H,HUSED
        CALL    HIDX
        MVI     M,1
        MOV     A,B             ; "  Sending NAME " / "  Receiving NAME "
        ORA     A
        LXI     D,MSEND
        JZ      DOPM
        LXI     D,MRECV
DOPM:   MVI     C,PRSTR
        CALL    BDOS
        LHLD    HFCBP
        INX     H
        CALL    PNAME
        MVI     E,' '
        MVI     C,CONOUT
        CALL    BDOS
        MVI     B,'O'
        CALL    OKST
        LDA     CURH
        INR     A               ; handles are 1-4
        CALL    EMIT
        JMP     SEND

DOPNEW: LDA     RXQ+5           ; not there: create it only if asked
        ANI     OCREATE
        JZ      DOPNO
        CALL    TFCBH
        JMP     DOPMK
DOPNO:  LXI     H,TFCB+1        ; for SUMMRY: "NAME: not found."
        LXI     D,NFNAME
        LXI     B,11
        CALL    MOVE
        MVI     A,1
        STA     NFFLAG
        MVI     A,ENOENT
        JMP     DOPERR
DOPEX:  MVI     A,EEXIST
        JMP     DOPERR
DOPFUL: LXI     D,MNOCR     ; "  Can't create NAME -- ... full."
        MVI     C,PRSTR
        CALL    BDOS
        LXI     H,TFCB+1
        CALL    PNAME
        LXI     D,MDFULL
        MVI     C,PRSTR
        CALL    BDOS
        MVI     A,ENOSPC
        JMP     DOPERR
DOPISD: MVI     A,EISDIR
        JMP     DOPERR
DOPBAD: LDA     RXQ+4           ; a bad name: EINVAL when creating,
        ANI     OWRITE          ; else "not found"
        MVI     A,ENOENT
        JZ      DOPERR
        LXI     D,MBADNM
        MVI     C,PRSTR
        CALL    BDOS
        MVI     A,EINVAL
DOPERR: MVI     B,'O'
        JMP     REPST

;-----------------------------------------------------------------------
; READ -- handle, len(2). Reply: status, len(2), data; EEOF at the end.
; Random-record reads from the handle's position.
;-----------------------------------------------------------------------
DREAD:  CALL    GETH
        MVI     B,'r'
        MVI     A,EBADF
        JC      REPST
        LHLD    RXQ+5
        SHLD    NREQ
        LXI     D,MAXIO
        CALL    MINW
        LHLD    NREQ
        SHLD    REMAIN
        LXI     H,0
        SHLD    NDONE
        MVI     B,'r'
        CALL    OKST
        LHLD    RPPTR           ; the length goes here, at the end
        SHLD    RLENP
        INX     H
        INX     H
        SHLD    RPPTR
DRLP:   LHLD    REMAIN
        MOV     A,H
        ORA     L
        JZ      DRDONE
        CALL    SETREC
        MVI     C,RDRAN
        CALL    BDOSH
        ORA     A
        JNZ     DREOF
        CALL    CHUNK           ; NCHUNK = min(128 - OFFS, REMAIN)
        LDA     OFFS            ; copy DMABUF+OFFS -> RPPTR
        MOV     E,A
        MVI     D,0
        LXI     H,DMABUF
        DAD     D
        PUSH    H
        LHLD    RPPTR
        XCHG
        POP     H
        LDA     NCHUNK
        MOV     C,A
        MVI     B,0
        CALL    MOVE
        XCHG
        SHLD    RPPTR
        CALL    ADVANC
        CALL    KDOT
        JMP     DRLP
DREOF:  LHLD    NDONE
        MOV     A,H
        ORA     L
        JNZ     DRDONE
        LXI     H,REPLY+4       ; nothing read: just EOF
        SHLD    RPPTR
        MVI     B,'r'
        MVI     A,EEOF
        JMP     REPST
DRDONE: LHLD    NDONE
        XCHG
        LHLD    RLENP
        MOV     M,E
        INX     H
        MOV     M,D
        JMP     SEND

;-----------------------------------------------------------------------
; WRITE -- handle, len(2), data. Reply: status, len(2). A whole record
; is written straight; a part record is read, patched and rewritten.
;-----------------------------------------------------------------------
DWRITE: CALL    GETH
        MVI     B,'w'
        MVI     A,EBADF
        JC      REPST
        LXI     H,HWR
        CALL    HIDX
        MOV     A,M
        ORA     A
        MVI     A,EACCES
        JZ      REPST
        LHLD    RXQ+5
        SHLD    REMAIN
        LXI     H,0
        SHLD    NDONE
        LXI     H,RXQ+7
        SHLD    SRCP
DWLP:   LHLD    REMAIN
        MOV     A,H
        ORA     L
        JZ      DWDONE
        CALL    SETREC
        CALL    CHUNK
        LDA     OFFS            ; a whole record?
        ORA     A
        JNZ     DWPART
        LDA     NCHUNK
        CPI     128
        JZ      DWCOPY
DWPART: MVI     C,RDRAN         ; no: read what's there first
        CALL    BDOSH
        ORA     A
        JZ      DWCOPY
        LXI     H,DMABUF        ; nothing there yet: start from ^Z
        MVI     B,128
DWF:    MVI     M,CPMEOF
        INX     H
        DCR     B
        JNZ     DWF
DWCOPY: LDA     OFFS            ; SRCP -> DMABUF+OFFS
        MOV     E,A
        MVI     D,0
        LXI     H,DMABUF
        DAD     D
        XCHG
        LHLD    SRCP
        LDA     NCHUNK
        MOV     C,A
        MVI     B,0
        CALL    MOVE
        SHLD    SRCP
        CALL    SETREC          ; (the read above moved the FCB on)
        MVI     C,WRRAN
        CALL    BDOSH
        ORA     A
        JNZ     DWERR
        CALL    ADVANC
        CALL    KDOT
        JMP     DWLP
DWDONE: MVI     B,'w'
        CALL    OKST
        LDA     NDONE
        CALL    EMIT
        LDA     NDONE+1
        CALL    EMIT
        JMP     SEND
DWERR:  LXI     D,MWFULL
        MVI     C,PRSTR
        CALL    BDOS
        MVI     B,'w'
        MVI     A,ENOSPC
        JMP     REPST

;-----------------------------------------------------------------------
; CLOSE -- handle. A file opened for writing gets a BDOS close.
;-----------------------------------------------------------------------
DCLOSE: CALL    GETH
        MVI     B,'C'
        MVI     A,EBADF
        JC      REPST
        CALL    CLS1
        MVI     B,'C'
        JMP     REPST           ; A = the status from CLS1

; CLS1 -- close handle CURH (already SETH'd), and end its console line
; with the byte count. A = EOK or EIO.
CLS1:   LXI     H,HUSED
        CALL    HIDX
        MVI     M,0
        MVI     A,EOK
        STA     CLSST
        LXI     H,HWR
        CALL    HIDX
        MOV     A,M
        MVI     M,0
        ORA     A
        JZ      CL1             ; read-only: nothing to write back
        MVI     A,1             ; the directory cache is stale now
        STA     DIRTY
        MVI     C,FCLOSE
        CALL    BDOSH
        INR     A
        JNZ     CL1
        MVI     A,EIO
        STA     CLSST
CL1:    LHLD    HPOSP           ; the position = bytes sent or received
        MOV     A,M
        STA     NUM24
        INX     H
        MOV     A,M
        STA     NUM24+1
        INX     H
        MOV     A,M
        STA     NUM24+2
        MVI     E,' '
        MVI     C,CONOUT
        CALL    BDOS
        CALL    PDEC24
        LXI     D,MBYTES
        LDA     CLSST
        ORA     A
        JZ      CL2
        LXI     D,MCFAIL
CL2:    MVI     C,PRSTR
        CALL    BDOS
        LDA     CLSST
        RET

; CLSALL -- close every open handle, forget the directory listing.
CLSALL: XRA     A
        STA     DIROPN
CA1:    STA     CAIDX
        LXI     H,HUSED
        MOV     E,A
        MVI     D,0
        DAD     D
        MOV     A,M
        ORA     A
        JZ      CA2
        LDA     CAIDX
        CALL    SETH
        CALL    CLS1
CA2:    LDA     CAIDX
        INR     A
        CPI     NHAND
        JC      CA1
        RET

;-----------------------------------------------------------------------
; THE DIRECTORY CACHE. CP/M runs one program at a time: while TNFSD
; runs, only TNFSD itself can change this drive. So the directory is
; scanned once at startup into DIRTAB, and again only after a file
; written through TNFSD is closed (CLS1 sets DIRTY; the next OPENDIRX
; rescans). A swapped floppy needs a TNFSD restart.
;
; SCAN -- one Search First/Next pass over every directory entry of the
; current user (ex='?': every extent). A file's size in records is
; ex*128 + rc of its highest extent -- the arithmetic BDOS function 35
; does, without rescanning the directory once per file. s2=0, so a file
; over 512K shows only its first 512K. No BDOS call may come between
; Search First and Next: everything in the loop is memory only.
;-----------------------------------------------------------------------
SCAN:   XRA     A
        STA     DIRCNT
        LXI     H,SFCB          ; drive 0 (current), 11 x ?, ex = ?
        MVI     M,0
        INX     H
        MVI     B,12
SC1:    MVI     M,'?'
        INX     H
        DCR     B
        JNZ     SC1
        MVI     B,FCBLEN-13     ; s1, s2, rc, ... = 0
SC2:    MVI     M,0
        INX     H
        DCR     B
        JNZ     SC2
        MVI     C,FSRCHF
SCS:    LXI     D,SFCB
        CALL    BDOS
        CPI     0FFH
        RZ
        ADD     A               ; the entry is at DMABUF + A*32
        ADD     A
        ADD     A
        ADD     A
        ADD     A
        MOV     E,A
        MVI     D,0
        LXI     H,DMABUF+1      ; its name, past the user byte
        DAD     D
        LXI     D,NAMBUF        ; the name, attribute bits stripped
        MVI     B,11
SC3:    MOV     A,M
        ANI     7FH
        STAX    D
        INX     H
        INX     D
        DCR     B
        JNZ     SC3
        MOV     A,M             ; ex -> records = ex*128 + rc
        ORA     A               ; CY=0
        RAR
        MOV     D,A
        MVI     A,0
        RAR
        MOV     E,A
        INX     H
        INX     H
        INX     H
        MOV     A,M             ; rc
        ADD     E
        MOV     E,A
        MOV     A,D
        ACI     0
        MOV     D,A
        XCHG
        SHLD    SRECS
        CALL    FINDN
        JC      SCNEW
        LXI     D,11            ; seen before: keep the larger size
        DAD     D
        SHLD    SPTR
        MOV     E,M
        INX     H
        MOV     D,M             ; DE = the size so far
        LHLD    SRECS
        MOV     A,E
        SUB     L
        MOV     A,D
        SBB     H
        JNC     SCNX            ; so far >= this extent's
        XCHG
        LHLD    SPTR
        MOV     M,E
        INX     H
        MOV     M,D
        JMP     SCNX
SCNEW:  LDA     DIRCNT          ; new: HL = the next free slot
        CPI     DIRMAX
        JNC     SCNX            ; table full: list what fits
        INR     A
        STA     DIRCNT
        XCHG
        LXI     H,NAMBUF
        LXI     B,11
        CALL    MOVE
        XCHG
        LDA     SRECS
        MOV     M,A
        INX     H
        LDA     SRECS+1
        MOV     M,A
SCNX:   MVI     C,FSRCHN
        JMP     SCS

; FINDN -- is NAMBUF in DIRTAB? CY=0: HL = its entry. CY=1: HL = the
; slot after the last entry.
FINDN:  LXI     H,DIRTAB
        LDA     DIRCNT
        MOV     B,A
FN1:    MOV     A,B
        ORA     A
        JZ      FNNO
        PUSH    H
        LXI     D,NAMBUF
        MVI     C,11
FN2:    LDAX    D
        CMP     M
        JNZ     FN3
        INX     H
        INX     D
        DCR     C
        JNZ     FN2
        POP     H
        ORA     A               ; CY=0
        RET
FN3:    POP     H
        LXI     D,DIRENT
        DAD     D
        DCR     B
        JMP     FN1
FNNO:   STC
        RET

;-----------------------------------------------------------------------
; OPENDIRX -- diropt, sortopt, max(2), pattern, path. Only the root is
; a directory. No disk access (unless the cache is stale): the pattern
; picks entries from DIRTAB into DIRSEL.
; Reply: status, handle 1, count(2).
;-----------------------------------------------------------------------
DOPNDX: LXI     H,8             ; find the path: after the pattern
        CALL    SKPSTR
        LXI     D,RXQ
        DAD     D
        CALL    PARSEP
        CPI     1
        JZ      DOX1
        ORA     A
        MVI     B,'D'
        MVI     A,ENOTDIR
        JZ      REPST
        MVI     A,ENOENT
        JMP     REPST
DOX1:   LDA     DIRTY           ; a file was written: rescan first
        ORA     A
        JZ      DOX2
        CALL    SCAN
        XRA     A
        STA     DIRTY
DOX2:   LXI     H,RXQ+8
        CALL    PATFCB          ; the pattern -> SFCB+1, with ? wildcards
        XRA     A
        STA     SELCNT
        STA     DIRI
        LXI     H,DIRTAB
        SHLD    DIRP
DSL:    LDA     DIRI            ; every cached entry...
        MOV     B,A
        LDA     DIRCNT
        CMP     B
        JZ      DOXMX
        LHLD    DIRP            ; ...that the pattern matches
        LXI     D,SFCB+1
        MVI     C,11
DSM:    LDAX    D
        CPI     '?'
        JZ      DSM1
        CMP     M
        JNZ     DSNO
DSM1:   INX     H
        INX     D
        DCR     C
        JNZ     DSM
        LDA     SELCNT          ; DIRSEL[SELCNT++] = DIRI
        MOV     E,A
        MVI     D,0
        LXI     H,DIRSEL
        DAD     D
        LDA     DIRI
        MOV     M,A
        LDA     SELCNT
        INR     A
        STA     SELCNT
DSNO:   LHLD    DIRP
        LXI     D,DIRENT
        DAD     D
        SHLD    DIRP
        LDA     DIRI
        INR     A
        STA     DIRI
        JMP     DSL

DOXMX:  LDA     RXQ+7           ; max results (0 = all)
        ORA     A
        JNZ     DOXOK           ; >= 256: more than DIRMAX anyway
        LDA     RXQ+6
        ORA     A
        JZ      DOXOK
        MOV     B,A
        LDA     SELCNT
        CMP     B
        JC      DOXOK
        MOV     A,B
        STA     SELCNT
DOXOK:  LDA     SELCNT          ; for SUMMRY
        STA     LSTCNT
        MVI     A,1
        STA     CLIST
        XRA     A
        STA     DIRPOS
        INR     A
        STA     DIROPN
        MVI     B,'D'
        CALL    OKST
        MVI     A,1             ; the one directory handle
        CALL    EMIT
        LDA     SELCNT
        CALL    EMIT
        XRA     A
        CALL    EMIT
        JMP     SEND

;-----------------------------------------------------------------------
; READDIRX -- handle, max entries. Reply: status, count, flags (01H =
; this is the end), position(2), then per entry: flags(1) size(4)
; mtime(4) ctime(4) name NUL. EEOF once everything was sent.
;-----------------------------------------------------------------------
DRDDX:  LDA     DIROPN
        ORA     A
        JZ      DRXBAD
        LDA     RXQ+4
        CPI     1
        JNZ     DRXBAD
        LDA     DIRPOS          ; nothing left: EOF
        MOV     B,A
        LDA     SELCNT
        SUB     B
        MVI     B,'d'
        MVI     A,EEOF
        JZ      REPST
        LDA     DIRPOS          ; C = entries left
        MOV     B,A
        LDA     SELCNT
        SUB     B
        MOV     C,A
        MVI     A,DXPER         ; n = min(left, DXPER, asked)
        CMP     C
        JNC     DRX1
        MOV     C,A
DRX1:   LDA     RXQ+5
        ORA     A
        JZ      DRX2
        CMP     C
        JNC     DRX2
        MOV     C,A
DRX2:   MOV     A,C
        STA     DIRN
        MVI     B,'d'
        CALL    OKST
        LDA     DIRN
        CALL    EMIT            ; count
        LDA     DIRPOS          ; the end after these?
        MOV     B,A
        LDA     DIRN
        ADD     B
        MOV     B,A
        LDA     SELCNT
        CMP     B
        MVI     A,0
        JNZ     DRX3
        INR     A
DRX3:   CALL    EMIT            ; flags
        LDA     DIRPOS
        CALL    EMIT            ; position
        XRA     A
        CALL    EMIT
DRX6:   LDA     DIRN
        ORA     A
        JZ      DRX9
        DCR     A
        STA     DIRN
        LDA     DIRPOS          ; DIRP = DIRTAB + DIRSEL[DIRPOS]*DIRENT
        MOV     E,A
        MVI     D,0
        LXI     H,DIRSEL
        DAD     D
        MOV     A,M
        LXI     H,DIRTAB
        LXI     D,DIRENT
        CALL    MULADD
        SHLD    DIRP
        XRA     A               ; flags: a plain file
        CALL    EMIT
        LHLD    DIRP            ; size = records * 128
        LXI     D,11
        DAD     D
        MOV     A,M
        STA     RECS
        INX     H
        MOV     A,M
        STA     RECS+1
        CALL    EMSIZE
        MVI     B,8             ; mtime, ctime
        CALL    EMITZ
        LHLD    DIRP
        CALL    EMNAME
        LDA     DIRPOS
        INR     A
        STA     DIRPOS
        JMP     DRX6
DRX9:   JMP     SEND
DRXBAD: MVI     B,'d'
        MVI     A,EBADF
        JMP     REPST

DCLSDR: XRA     A
        STA     DIROPN
        MVI     B,'c'
        JMP     REPST           ; A = 0

;=======================================================================
; FILE HELPERS
;=======================================================================

; PARSEP -- HL = a NUL-terminated TNFS path. A=1: the root. A=0: TFCB
; holds the file's FCB (current drive). A=2: not a CP/M 8.3 file name
; in the root -- a folder, a wildcard, a bad character, too long.
PARSEP: CALL    CLRTF
PP1:    MOV     A,M             ; skip leading /
        CPI     '/'
        JNZ     PP2
        INX     H
        JMP     PP1
PP2:    ORA     A
        MVI     A,1
        RZ
        LXI     D,TFCB+1        ; the name, up to 8
        MVI     B,8
PP3:    MOV     A,M
        ORA     A
        JZ      PP8
        CPI     '.'
        JZ      PP5
        CALL    LEGAL
        JC      PPBAD
        MOV     C,A
        MOV     A,B
        ORA     A
        JZ      PPBAD           ; name longer than 8
        MOV     A,C
        STAX    D
        INX     D
        INX     H
        DCR     B
        JMP     PP3
PP5:    MOV     A,B             ; an empty name?
        CPI     8
        JZ      PPBAD
        INX     H
        LXI     D,TFCB+9        ; the extension, up to 3
        MVI     B,3
PP6:    MOV     A,M
        ORA     A
        JZ      PP9
        CALL    LEGAL
        JC      PPBAD
        MOV     C,A
        MOV     A,B
        ORA     A
        JZ      PPBAD
        MOV     A,C
        STAX    D
        INX     D
        INX     H
        DCR     B
        JMP     PP6
PP8:    MOV     A,B
        CPI     8
        JZ      PPBAD
PP9:    XRA     A
        RET
PPBAD:  MVI     A,2
        RET

; LEGAL -- A = a name character. CY set if CP/M can't have it in a file
; name; else A = it in upper case.
LEGAL:  CPI     '!'
        RC                      ; space, control characters
        CPI     7FH
        CMC
        RC
        PUSH    H
        LXI     H,BADCH
LG1:    CMP     M
        JZ      LGBAD
        INX     H
        PUSH    PSW
        MOV     A,M
        ORA     A
        JZ      LGEND
        POP     PSW
        JMP     LG1
LGEND:  POP     PSW
        POP     H
        CPI     'a'
        JC      LGOK
        CPI     'z'+1
        JNC     LGOK
        SUI     20H
LGOK:   ORA     A               ; CY=0
        RET
LGBAD:  POP     H
        STC
        RET

; PATFCB -- HL = an OPENDIRX pattern. SFCB = it as a search FCB: *
; fills the rest of its field with ?. "" or "*" alone means every file.
PATFCB: LXI     D,SFCB
        XRA     A
        STAX    D               ; the current drive
        INX     D
        MVI     B,11
        MVI     A,' '
PF1:    STAX    D
        INX     D
        DCR     B
        JNZ     PF1
        MVI     B,FCBLEN-12
        XRA     A
PF2:    STAX    D               ; ex = 0: one entry per file
        INX     D
        DCR     B
        JNZ     PF2
        MOV     A,M             ; "" or "*": everything
        ORA     A
        JZ      PFALL
        CPI     '*'
        JNZ     PF3
        INX     H
        MOV     A,M
        DCX     H
        ORA     A
        JZ      PFALL
PF3:    LXI     D,SFCB+1
        MVI     B,8
        CALL    PFFLD
        MOV     A,M
        CPI     '.'
        RNZ
        INX     H
        LXI     D,SFCB+9
        MVI     B,3
        JMP     PFFLD
PFALL:  LXI     H,SFCB+1
        MVI     B,11
PF4:    MVI     M,'?'
        INX     H
        DCR     B
        JNZ     PF4
        RET

; PFFLD -- copy one pattern field (B chars max) from HL to DE. Stops at
; NUL or '.', left there for the caller.
PFFLD:  MOV     A,M
        ORA     A
        RZ
        CPI     '.'
        RZ
        CPI     '*'
        JZ      PFSTAR
        INX     H
        MOV     C,A
        MOV     A,B
        ORA     A
        JZ      PFFLD           ; field full: skip the extra
        MOV     A,C
        CPI     'a'
        JC      PFF1
        CPI     'z'+1
        JNC     PFF1
        SUI     20H
PFF1:   STAX    D
        INX     D
        DCR     B
        JMP     PFFLD
PFSTAR: INX     H
        MOV     A,B
        ORA     A
        JZ      PFFLD
        MVI     A,'?'
PFS1:   STAX    D
        INX     D
        DCR     B
        JNZ     PFS1
        JMP     PFFLD

; CLRTF -- TFCB = current drive, blank name, zeros. Keeps HL.
CLRTF:  PUSH    H
        LXI     H,TFCB
        MVI     M,0
        INX     H
        MVI     B,11
CT1:    MVI     M,' '
        INX     H
        DCR     B
        JNZ     CT1
        MVI     B,FCBLEN-12
CT2:    MVI     M,0
        INX     H
        DCR     B
        JNZ     CT2
        POP     H
        RET

; TFCBH -- the current handle's FCB = TFCB.
TFCBH:  LHLD    HFCBP
        XCHG
        LXI     H,TFCB
        LXI     B,FCBLEN
        JMP     MOVE

; RECSOF -- DE = an FCB. RECS = the file's size in records (BDOS 35).
RECSOF: PUSH    D
        MVI     C,FSIZE
        CALL    BDOS
        POP     H
        LXI     D,FCBR0
        DAD     D
        MOV     A,M
        STA     RECS
        INX     H
        MOV     A,M
        STA     RECS+1
        INX     H
        MOV     A,M             ; r2 set: 65536 records -- cap it
        ORA     A
        RZ
        LXI     H,0FFFFH
        SHLD    RECS
        RET

; BDOSH -- BDOS function C on the current handle's FCB.
BDOSH:  LHLD    HFCBP
        XCHG
        JMP     BDOS

; SETH -- A = handle index 0-3: CURH, HFCBP, HPOSP.
SETH:   STA     CURH
        LXI     H,HFCB
        LXI     D,FCBLEN
        CALL    MULADD
        SHLD    HFCBP
        LDA     CURH
        LXI     H,HPOS
        LXI     D,3
        CALL    MULADD
        SHLD    HPOSP
        RET

; MULADD -- HL = HL + A*DE.
MULADD: ORA     A
        RZ
        DAD     D
        DCR     A
        JMP     MULADD

; GETH -- the request's handle (RXQ+4, 1-4) -> SETH. CY set if it is
; not an open handle.
GETH:   LDA     RXQ+4
        DCR     A
        CPI     NHAND
        CMC
        RC                      ; 0 or > NHAND
        PUSH    PSW
        LXI     H,HUSED
        MOV     E,A
        MVI     D,0
        DAD     D
        MOV     A,M
        ORA     A
        JZ      GHBAD
        POP     PSW
        CALL    SETH
        ORA     A               ; CY=0
        RET
GHBAD:  POP     PSW
        STC
        RET

; HIDX -- HL = HL + CURH.
HIDX:   LDA     CURH
        MOV     E,A
        MVI     D,0
        DAD     D
        RET

; SETREC -- the handle's position -> FCB r0-r2 (record) and OFFS
; (byte in the record).
SETREC: LHLD    HPOSP
        MOV     A,M
        ANI     7FH
        STA     OFFS
        MOV     A,M
        RAL                     ; CY = bit 7 of P0
        INX     H
        MOV     A,M
        RAL
        MOV     B,A             ; r0
        INX     H
        MOV     A,M
        RAL
        MOV     C,A             ; r1
        MVI     A,0
        RAL
        MOV     D,A             ; r2
        PUSH    D
        LHLD    HFCBP
        LXI     D,FCBR0
        DAD     D
        POP     D
        MOV     M,B
        INX     H
        MOV     M,C
        INX     H
        MOV     M,D
        RET

; CHUNK -- NCHUNK = min(128 - OFFS, REMAIN).
CHUNK:  LDA     OFFS
        MOV     B,A
        MVI     A,128
        SUB     B
        MOV     C,A
        LDA     REMAIN+1
        ORA     A
        JNZ     CK1
        LDA     REMAIN
        CMP     C
        JNC     CK1
        MOV     C,A
CK1:    MOV     A,C
        STA     NCHUNK
        RET

; ADVANC -- position += NCHUNK, REMAIN -= NCHUNK, NDONE += NCHUNK.
ADVANC: LDA     NCHUNK
        MOV     C,A
        LHLD    HPOSP
        MOV     A,M
        ADD     C
        MOV     M,A
        INX     H
        MOV     A,M
        ACI     0
        MOV     M,A
        INX     H
        MOV     A,M
        ACI     0
        MOV     M,A
        MVI     B,0
        LHLD    REMAIN
        MOV     A,L
        SUB     C
        MOV     L,A
        MOV     A,H
        SBB     B
        MOV     H,A
        SHLD    REMAIN
        LHLD    NDONE
        DAD     B
        SHLD    NDONE
        RET

;=======================================================================
; BUILDING THE REPLY
;=======================================================================

; EMIT -- A -> the reply. Keeps everything but A.
EMIT:   PUSH    H
        LHLD    RPPTR
        MOV     M,A
        INX     H
        SHLD    RPPTR
        POP     H
        RET

; EMITZ -- B zero bytes.
EMITZ:  XRA     A
        CALL    EMIT
        DCR     B
        JNZ     EMITZ
        RET

; EMSIZE -- the 4-byte size RECS * 128.
EMSIZE: LDA     RECS+1
        ORA     A               ; CY=0
        RAR
        MOV     B,A             ; byte 2
        LDA     RECS
        RAR
        MOV     C,A             ; byte 1
        MVI     A,0
        RAR                     ; byte 0
        CALL    EMIT
        MOV     A,C
        CALL    EMIT
        MOV     A,B
        CALL    EMIT
        XRA     A
        JMP     EMIT

; EMNAME -- HL = an 11-byte FCB name: emit "NAME.EXT" and a NUL.
EMNAME: MVI     B,8
EN1:    MOV     A,M
        CPI     ' '
        JZ      EN2
        CALL    EMIT
        INX     H
        DCR     B
        JNZ     EN1
EN2:    MOV     A,B             ; step to the extension
        ORA     A
        JZ      EN3
        INX     H
        DCR     B
        JMP     EN2
EN3:    MOV     A,M
        CPI     ' '
        JZ      EN5
        MVI     A,'.'
        CALL    EMIT
        MVI     B,3
EN4:    MOV     A,M
        CPI     ' '
        JZ      EN5
        CALL    EMIT
        INX     H
        DCR     B
        JNZ     EN4
EN5:    XRA     A
        JMP     EMIT

;=======================================================================
; FUJINET PACKETS -- the same layout as NC.ASM / TCPECHO.ASM:
;   off0 device  off1 command  off2/3 length  off4 checksum
;   off5 descr   off6+ params, then payload
; Control packets go in CTLBUF; reply WRITEs in TXBUF.
;=======================================================================

; NSTAT -- STATUS. RXBUF+6/7 = bytes waiting, RXBUF+8 = connected.
NSTAT:  LXI     H,CTLBUF
        MVI     M,NETDEV
        INX     H
        MVI     M,CMDSTAT
        LXI     H,CTLBUF+5
        MVI     M,0
        INX     H
        JMP     NCTL

; NBARE -- a zero-parameter command A (ACCEPT, CLOSE_CLIENT, CLOSE).
NBARE:  LXI     H,CTLBUF
        MVI     M,NETDEV
        INX     H
        MOV     M,A
        LXI     H,CTLBUF+5
        MVI     M,0
        INX     H
NCTL:   LXI     D,CTLBUF        ; HL = the end
        CALL    SETLEN
        LXI     H,CTLBUF
        CALL    SENDPK
        JMP     RECVPK

; MKREAD -- READ NREQ bytes.
MKREAD: LXI     H,CTLBUF
        MVI     M,NETDEV
        INX     H
        MVI     M,CMDREAD
        LXI     H,CTLBUF+5
        MVI     M,5             ; descr: one 2-byte param
        INX     H
        LDA     NREQ
        MOV     M,A
        INX     H
        LDA     NREQ+1
        MOV     M,A
        INX     H
        LXI     D,CTLBUF
        JMP     SETLEN

; MKOPEN -- OPEN "N1:TCP://:16384/" read/write, no translation.
MKOPEN: LXI     H,CTLBUF
        MVI     M,NETDEV
        INX     H
        MVI     M,CMDOPEN
        LXI     H,CTLBUF+5
        MVI     M,2             ; descr: two 1-byte params
        INX     H
        MVI     M,ACCRW
        INX     H
        MVI     M,TRANONE
        INX     H
        LXI     D,SPEC
MKO1:   LDAX    D
        MOV     M,A
        INX     H
        INX     D
        ORA     A
        JNZ     MKO1
        LXI     D,CTLBUF
        JMP     SETLEN

; SETLEN -- DE = a packet's start, HL = one past its end. Stores the
; length at +2/3, then the checksum at +4.
SETLEN: XCHG
        SHLD    PKST
        XCHG
        MOV     A,L
        SUB     E
        MOV     C,A
        MOV     A,H
        SBB     D
        MOV     B,A             ; BC = length
        LHLD    PKST
        INX     H
        INX     H
        MOV     M,C
        INX     H
        MOV     M,B
        INX     H
        MVI     M,0             ; zero the checksum before summing
        LHLD    PKST
        CALL    CKSUM
        LHLD    PKST
        INX     H
        INX     H
        INX     H
        INX     H
        MOV     M,A
        RET

; CKSUM -- HL = buffer, BC = length. A = the byte sum with each carry
; folded back in.
CKSUM:  MVI     D,0
CS1:    MOV     A,B
        ORA     C
        JZ      CS9
        MOV     A,D
        ADD     M
        JNC     CS2
        INR     A
CS2:    MOV     D,A
        INX     H
        DCX     B
        JMP     CS1
CS9:    MOV     A,D
        RET

; SENDPK -- HL = a packet: SLIP-frame and transmit it.
SENDPK: SHLD    PKST
        INX     H
        INX     H
        MOV     C,M
        INX     H
        MOV     B,M
        LHLD    PKST
        MVI     A,SLPEND
        CALL    ACOUT
SP1:    MOV     A,B
        ORA     C
        JZ      SP9
        MOV     A,M
        CPI     SLPEND
        JZ      SPQEND
        CPI     SLPESC
        JZ      SPQESC
        CALL    ACOUT
        JMP     SPADV
SPQEND: MVI     A,SLPESC
        CALL    ACOUT
        MVI     A,SLPEEND
        CALL    ACOUT
        JMP     SPADV
SPQESC: MVI     A,SLPESC
        CALL    ACOUT
        MVI     A,SLPEESC
        CALL    ACOUT
SPADV:  INX     H
        DCX     B
        JMP     SP1
SP9:    MVI     A,SLPEND
        JMP     ACOUT

; RECVPK -- read one SLIP frame into RXBUF, decoding as it goes.
RECVPK: CALL    ACIN
        CPI     SLPEND
        JNZ     RECVPK          ; discard anything before the opening 0C0H
        LXI     H,RXBUF
RP1:    CALL    ACIN
        CPI     SLPEND
        RZ                      ; the closing delimiter
        CPI     SLPESC
        JNZ     RP3
        CALL    ACIN
        CPI     SLPEEND
        JZ      RPQEND
        MVI     A,SLPESC        ; anything else after ESC: treat as 0DBH
        JMP     RP3
RPQEND: MVI     A,SLPEND
RP3:    MOV     M,A
        INX     H
        JMP     RP1

; ACOUT -- send A, waiting for TDRE. ACIN -- receive into A.
ACOUT:  PUSH    PSW
AO1:    IN      SIOST
        ANI     02H
        JZ      AO1
        POP     PSW
        OUT     SIODT
        RET

ACIN:   IN      SIOST
        ANI     01H
        JZ      ACIN
        IN      SIODT
        RET

;=======================================================================
; SMALL THINGS
;=======================================================================

; MOVE -- copy BC bytes from HL to DE. Leaves HL, DE just past them.
MOVE:   MOV     A,B
        ORA     C
        RZ
        MOV     A,M
        STAX    D
        INX     H
        INX     D
        DCX     B
        JMP     MOVE

; PDEC -- print HL in decimal.
PDEC:   SHLD    NUM24
        XRA     A
        STA     NUM24+2         ; fall into PDEC24

; PDEC24 -- print the 24-bit NUM24 in decimal, no leading zeros.
; Destroys NUM24.
PDEC24: LXI     H,DECBUF
        SHLD    D24OUT
        LXI     H,POW10
        SHLD    D24POW
        MVI     A,6
        STA     D24CNT
PD1:    MVI     A,'0'
        STA     D24DIG
PD2:    LHLD    D24POW          ; subtract this power until it borrows
        CALL    SUB24
        JC      PD3
        LDA     D24DIG
        INR     A
        STA     D24DIG
        JMP     PD2
PD3:    LHLD    D24POW          ; one too many: add it back
        CALL    ADD24
        LHLD    D24OUT
        LDA     D24DIG
        MOV     M,A
        INX     H
        SHLD    D24OUT
        LHLD    D24POW
        INX     H
        INX     H
        INX     H
        SHLD    D24POW
        LDA     D24CNT
        DCR     A
        STA     D24CNT
        JNZ     PD1
        LDA     NUM24           ; the units
        ADI     '0'
        LHLD    D24OUT
        MOV     M,A
        INX     H
        MVI     M,'$'
        LXI     D,DECBUF        ; skip leading zeros, keep the last digit
        MVI     B,6
PD4:    LDAX    D
        CPI     '0'
        JNZ     PD5
        INX     D
        DCR     B
        JNZ     PD4
PD5:    MVI     C,PRSTR
        JMP     BDOS

; SUB24 / ADD24 -- NUM24 -= / += the 3 bytes at HL. SUB24: CY = borrow.
SUB24:  XCHG
        LXI     H,NUM24
        LDAX    D
        MOV     C,A
        MOV     A,M
        SUB     C
        MOV     M,A
        INX     H
        INX     D
        LDAX    D
        MOV     C,A
        MOV     A,M
        SBB     C
        MOV     M,A
        INX     H
        INX     D
        LDAX    D
        MOV     C,A
        MOV     A,M
        SBB     C
        MOV     M,A
        RET

ADD24:  XCHG
        LXI     H,NUM24
        LDAX    D
        ADD     M
        MOV     M,A
        INX     H
        INX     D
        LDAX    D
        ADC     M
        MOV     M,A
        INX     H
        INX     D
        LDAX    D
        ADC     M
        MOV     M,A
        RET

; PNAME -- print the 11-byte FCB name at HL as NAME.EXT.
PNAME:  MVI     B,8
PN1:    MOV     A,M
        ANI     7FH
        CPI     ' '
        JZ      PN2
        CALL    PCHAR
        INX     H
        DCR     B
        JNZ     PN1
PN2:    MOV     A,B             ; step to the extension
        ORA     A
        JZ      PN3
        INX     H
        DCR     B
        JMP     PN2
PN3:    MOV     A,M
        ANI     7FH
        CPI     ' '
        RZ
        MVI     A,'.'
        CALL    PCHAR
        MVI     B,3
PN4:    MOV     A,M
        ANI     7FH
        CPI     ' '
        RZ
        CALL    PCHAR
        INX     H
        DCR     B
        JNZ     PN4
        RET

; PCHAR -- print A. Keeps B, H, L.
PCHAR:  PUSH    H
        PUSH    B
        MOV     E,A
        MVI     C,CONOUT
        CALL    BDOS
        POP     B
        POP     H
        RET

; KDOT -- a dot each time the handle's position reaches a whole KB.
KDOT:   LHLD    HPOSP
        MOV     A,M
        ORA     A
        RNZ
        INX     H
        MOV     A,M
        ANI     03H
        RNZ
        MVI     A,'.'
        JMP     PCHAR

;=======================================================================
; DATA
;=======================================================================
SPEC:   DB      'N1:TCP://:16384/',0
BADCH:  DB      '<>.,;:=?*[]/"',0     ; not allowed in a CP/M file name

MBAN1:  DB      'TNFSD v0.3: serving drive $'
MBAN2:  DB      ': (user $'
MBAN3:  DB      ') on TCP port 16384.',CR,LF,'$'
MSCAN2: DB      ' files cached. Ctrl-C quits.',CR,LF,'$'
MFAIL:  DB      'TNFSD: FujiNet refused to listen (NAK).',CR,LF,'$'
MCONN:  DB      'Client connected.',CR,LF,'$'
MCLOSE: DB      'Client disconnected.',CR,LF,'$'
MPERR:  DB      'Unreadable request -- client dropped.',CR,LF,'$'
MSEND:  DB      '  Sending $'
MRECV:  DB      '  Receiving $'
MBYTES: DB      ' bytes.',CR,LF,'$'
MCFAIL: DB      ' bytes -- CLOSE FAILED, the file may be incomplete.',CR,LF,'$'
MWFULL: DB      ' -- disk full!',CR,LF,'$'
MNOCR:  DB      '  Can''t create $'
MDFULL: DB      ' -- disk or directory full.',CR,LF,'$'
MBADNM: DB      '  Refused a file name CP/M can''t use.',CR,LF,'$'
MTOOMN: DB      '  Too many files open.',CR,LF,'$'
MNOTFD: DB      ': not found.',CR,LF,'$'
MLIST:  DB      '  Directory listed: $'
MLIST2: DB      ' files.',CR,LF,'$'
POW10:  DB      40H,42H,0FH     ; 1000000
        DB      0A0H,86H,01H    ; 100000
        DB      10H,27H,00H     ; 10000
        DB      0E8H,03H,00H    ; 1000
        DB      64H,00H,00H     ; 100
        DB      0AH,00H,00H     ; 10
MQUIT:  DB      CR,LF,'TNFSD: closed.',CR,LF,'$'

;---- Variables (zeroed at start) ---------------------------------------
VARS:
CURDSK: DS      1
CURUSR: DS      1
NXTSID: DS      2               ; the next session id
CURSID: DS      2
SIDOK:  DS      1               ; a session is mounted
LASTV:  DS      1               ; LASTSQ/LASTCM/TXBUF hold a sent reply
LASTSQ: DS      1
LASTCM: DS      1
PERR:   DS      1               ; the stream can't be parsed
RXQLEN: DS      2
CURLEN: DS      2
NREQ:   DS      2
RPPTR:  DS      2
RLENP:  DS      2
TRCH:   DS      1
CLSST:  DS      1
CLIST:  DS      1               ; this connection listed the directory
LSTCNT: DS      1
COPEN:  DS      1               ; this connection tried to open a file
NFFLAG: DS      1               ; a read-open failed: NFNAME
NFNAME: DS      11
NUM24:  DS      3
D24OUT: DS      2
D24POW: DS      2
D24CNT: DS      1
D24DIG: DS      1
PKST:   DS      2
REMAIN: DS      2
NDONE:  DS      2
NCHUNK: DS      1
OFFS:   DS      1
SRCP:   DS      2
RECS:   DS      2
CURH:   DS      1
CAIDX:  DS      1
HFCBP:  DS      2
HPOSP:  DS      2
HUSED:  DS      NHAND
HWR:    DS      NHAND
HPOS:   DS      NHAND*3         ; byte position, 24 bits
DIROPN: DS      1
DIRCNT: DS      1               ; files in DIRTAB
DIRTY:  DS      1               ; DIRTAB needs a rescan
SELCNT: DS      1               ; entries OPENDIRX picked into DIRSEL
SRECS:  DS      2
SPTR:   DS      2
NAMBUF: DS      11
DIRPOS: DS      1
DIRN:   DS      1
DIRI:   DS      1
DIRP:   DS      2
DECBUF: DS      8
VARSEND:

TFCB:   DS      FCBLEN          ; the file a request names
SFCB:   DS      FCBLEN          ; the directory search pattern
HFCB:   DS      NHAND*FCBLEN    ; one FCB per handle
DMABUF: DS      128
CTLBUF: DS      48
TXBUF:  DS      8+4+1+2+MAXIO+8 ; header, TNFS header, status, len, data
REPLY   EQU     TXBUF+8
RXBUF:  DS      NETMAX+16
RXQ:    DS      RXQMAX
DIRTAB: DS      DIRMAX*DIRENT   ; the directory cache
DIRSEL: DS      DIRMAX          ; OPENDIRX's picks: indexes into DIRTAB

        DS      128             ; stack
STACK   EQU     $

        END     START
