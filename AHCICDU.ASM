
;--- AHCI CD/DVD driver,
;--- based on R. Loew's AHCICD.SYS,
;--- uses "unreal-mode" for extended memory access.
;---
;--- to make the binary using jwasm:
;---   jwasm -bin -Fo=ahcicdu.sys ahcicdu.asm
;---
;--- to make the binary using MS tools:
;---   ml -c ahcicdu.asm
;---   link16 /tiny ahcicdu.obj, ahcicdu.sys;

?CHECKA20 equ 1	;1=check A20 state on driver entry
ifndef ?EXTMEM
?EXTMEM   equ 1
endif

SECSIZE equ 2048	; "cooked" mode sector size
CLSIZE  equ 32*32	; size cmd list
FBSIZE  equ 256		; size fis buffer
MAXDRV  equ 6		; max cd/dvd-roms supported
GENINT  equ 1		; 1=generate interrupt if transfer complete

	.386p	; p-suffix needed to switch to "unreal" mode
	option casemap:none

DRIVER struct
pNext	dd ?	;+0
wAttr	dw ?	;+4
ofsStr	dw ?	;+6
ofsInt	dw ?	;+8
name_	db 8 dup (?)	;+10
wRes1	dw 0	;+18 CDROM drivers only
bRes2	db 0	;+20 CDROM drivers only, modified by MSCDEX
bUnits	db 0	;+21 CDROM drivers only, units
DRIVER ends

;--- DOS "Request Packet" header

RPH struct
Len     db  ?       ;+0 Header byte count.
bSubU   db  ?       ;+1 Subunit number.
bOp     db  ?       ;+2 Command code.
wStat   dw  ?       ;+3 Status field.
        db 8 dup (?);+5 .. +12 (reserved).
RPH ends

;--- DOS error codes ( lobyte of wStat if wStat[15]==1 )
DE_WRITEPROTECT equ 0
DE_NOTREADY     equ 2
DE_CRCERROR     equ 4
DE_SECTORNOTFND equ 8
DE_GENFAILURE   equ 12
DE_INVALDISKCHG equ 15


;--- Init request packet

RPInit struct
        RPH <>
bUnit   db  ?       ;+13 Number of units found.
dwFree  dd  ?       ;+14 return: far16 ptr first free byte behind driver
CmdLine dd  ?       ;+18 Command-line data pointer.
RPInit  ends

;--- IOCTL input request packet

RPIOC struct
        RPH <>
        db ?	;+13 Media descriptor byte
dwAddr  dd ?	;+14 Data-transfer address.
wLength dw ?	;+18 Data-transfer length.
RPIOC ends

;--- Read Long request packet

RPRL struct
        RPH <>
bAMode  db ?	;+13 Addressing mode.
dwAddr  dd ?	;+14 Data-transfer address.
wSecCnt dw ?	;+18 Data-transfer sector count.
dwStart dd ?	;+20 Starting sector number.
bDMode  db ?	;+24 Data-transfer mode (raw/cooked).
RPRL  ends

;--- AHCI structs

HBA struct
dwCAP   dd ?	;+0 HBA capabilities
dwGHC   dd ?	;+4 global HBA control
dwIS    dd ?	;+8 interrupt status
dwPI    dd ?	;+12 ports implemented
HBA ends

PORT struct		; AHCI port
dqCLB   dq ?	;+0  Command list base addr ( 1 kB aligned )
dqFB    dq ?	;+8  (received) FIS base addr ( 256 B aligned )
dwIS    dd ?	;+16 interrupt status
dwIE    dd ?	;+20 interrupt enable
dwCMD   dd ?	;+24 command and status
        dd ?	;+28
dwTFD   dd ?	;+32 task file data
dwSIG   dd ?	;+36 signature
dwSSTS  dd ?	;+40 SATA status
dwSCTL  dd ?	;+44 SATA control
dwSERR  dd ?	;+48 SATA error
dwSACT  dd ?	;+52 SATA active
dwCI    dd ?	;+56 command issued
PORT ends

CLH struct		; command list header
flags1  db ?	;+0  P[7]=Prefetchable, W[6]=Write, A[5]=ATAPI, CFL[4:0]=Command FIS Length
flags2  db ?	;+1  PMP[15:12]=Port Multiplier Port, R[11]=Reserved, C[10]=Clear Busy, B[9]=BIST, R[8]=Reset
PRDTL   dw ?	;+2  Physical Region Descriptor Table Length
PRDBC   dd ?	;+4  Physical Region Descriptor Byte Count
dwCTBA  dd ?	;+8  Command Table Base Address bits 0-31 (128 byte aligned)
dwCTBAU dd ?	;+12 Command Table Base Address bits 32-63
	dd 4 dup (?)
CLH ends

PRDT struct
dwBase   dd ?	;+0 base - must be word aligned (bit 0 is "reserved")
dwBaseU  dd ?	;+4 base upper
dwRsvd   dd ?	;+8 reserved
dwCnt    dd ?	;+12 cnt ( bits 0-30: size - 1, that is, 7 means: transfer 8 bytes ); bit 31: 1=cause interrupt if done
PRDT ends

CT struct		; command table
cfis0  dd ?
cfis1  dd ?
cfis2  dd ?
cfis3  dd ?
       db 30h dup (?)
Pkt0   dd ?		; 40h=offset ATAPI in command table
Pkt1   dd ?
Pkt2   dd ?
       dd ?		; Packets are 12/16 bytes
       db 30h dup (?)
p0     PRDT <>	; 80h=offset PRDT in command table
CT ends

;--- ATAPI structs
;--- cmds used by driver: 03, 28, 4A

PKT03 struct	; 03=request sense command - SPC-3
bOC      db ?	; operation code (03h)
bFlgs    db ?	; bit 0: DESC (0=return fixed format sense data)
         db ?,?	; rsvd
bAllocL  db ?	; allocation length (size of data to be returned)
PKT03 ends

FFSD struct		; fixed format sense data
bRC      db ?	; response code ( bit 7: 1=valid data )
         db ?
bFlgs    db ?	; 0-3: sense key, 4:rsvd, 5=ILI, 6=EOM, 7=FILEMARK
dwInfo   dd ?
bASL     db ?	; additional sense length
FFSD ends

FFSDF_SKMASK equ 1111b	; sense key bits

;--- sense keys
SK_NOSENSE         equ 0
SK_RECOVERED_ERROR equ 1
SK_NOT_READY       equ 2
SK_MEDIUM_ERROR    equ 3
SK_HARDWARE_ERROR  equ 4
SK_ILLEGAL_REQUEST equ 5
SK_UNIT_ATTENTION  equ 6
SK_DATA_PROTECT    equ 7
SK_BLANK_CHECK     equ 8
SK_VENDOR_SPECIFIC equ 9
SK_COPY_ABORTED    equ 10
SK_ABORTED_COMMAND equ 11
SK_12              equ 12	; obsolete
SK_VOLUME_OVERFLOW equ 13
SK_MISCOMPARE      equ 14
SK_15              equ 15	: reserved

PKT28 struct	; 28=read(10) command - SBC-2
bOC      db ?	; operation code (28h)
bFlgs    db ?	; bit 1: FUA_NV, bit 3: FUA, bit 4: DPO, bit 5-7:RDPROTECT
dwLBA    dd ?	; Logical Block Address ( high, .. low )
bGrp     db ?	; bit 0-4: group number
wLength  dw ?	; transfer length ( high, low )
bCtrl    db ?	; Control
PKT28 ends

PKT4A struct	; 4A=get event notification - MMC-3
bOC    db ?		; operation code (4Ah)
bFlgs  db ?		; bit 0: I
       db ?,?	; rsvd
bNCR   db ?		; notification class request (1=op change, 2=power mgmnt, 4=media)
       db ?,?	; rsvd
wAL    dw ?		; allocation length (high, low)
bCtrl  db ?
PKT4A ends

;--- data returned by "get event notification"

EVENT4A struct
wEDL     dw ?	; event data length (high, low)
bEHFlgs  db ?	; event header flags (0-2: notification class, 7: NEA no event available)
bSuppEC  db ?	; supported event classes
wED0     dw ?	; event data bytes 0-1
wED1     dw ?	; event data bytes 2-3
EVENT4A ends

	assume ds:nothing,ss:nothing

_TEXT segment use16 para public 'CODE'

DGROUP group _TEXT

base DRIVER <-1, 0C800H, offset STRAT, offset ENTRY, 'CD1$$$$$',0,0,0>
	DB 'AHCI CD/DVD DOS Driver'	; signature ( size at least 6 bytes? )

	align 8

gdt label qword
	dw -1,0,9200h,0CFh	; 32-bit flat data descriptor
;	dw -1,0,9200h,0		; 16-bit data descriptor

SEL_FLAT equ 8

gdtr dw 2*8-1,offset gdt-8,0

;--- cmds 00-0E
VECTOR  DW INIT,ERROR3,ERROR3,IOCTLI,ERROR3,ERROR3,ERROR3,ERROR3
        DW ERROR3,ERROR3,ERROR3,ERROR3,ERROR3,EXIT,EXIT
LVECTOR equ $ - offset VECTOR

;--- cmds 80-82
VECT2   DW READL,ERROR3,EXIT
LVECT2  equ $ - offset VECT2

;--- IOCTL subcmds
IVEC    DW IOC_GETHDR,ERROR3,ERROR3,ERROR3,ERROR3,ERROR3,IOC_DEVST,IOC_SECSIZ
        DW ERROR3,IOC_MEDIA
LIVEC   equ ($ - offset IVEC) shr 1

wPorts  DW MAXDRV dup (?)	;port offsets (100h,180h,...)

;--- translate "sense key" to DOS device driver return code
ERRTAB  label byte
	db DE_GENFAILURE	;0
	db DE_GENFAILURE	;1
	db DE_NOTREADY		;2
	db DE_CRCERROR		;3
	db DE_GENFAILURE	;4
	db DE_WRITEPROTECT	;5
	db DE_INVALDISKCHG	;6
	db DE_SECTORNOTFND	;7
	db DE_SECTORNOTFND	;8
	db 7 dup (DE_GENFAILURE) ;9,10,11,12,13,14,15

	align 4
pHBA    DD 0	; linear address HBA
pBuff   DD 0	; linear address sector buffer
xmmad   dd 0	; XMM entry

STRAT proc
	mov word ptr cs:[dwReq+0], bx
	mov word ptr cs:[dwReq+2], es
	retf
STRAT endp

ENTRY proc
	pushad
	push ds
	push es
	mov bp, sp

	push 0
	pop ds
	mov bx, cs
	mov eax, ds:[13*4]
	shl ebx, 16
	mov bx, offset int0d
	mov cs:[oldint0d], eax
	mov ds:[13*4], ebx

	les bx, cs:[dwReq]
	cmp es:[bx].RPH.bOp, 0	;Init?
	JZ nounit
if ?CHECKA20
	mov ecx, ds:[0]
	cmp ecx, ds:[100000h]
	jnz @F
	push bx
	mov ah, 5
	call cs:[xmmad]
	pop bx
@@:
endif
	mov al, es:[bx].RPH.bSubU
	mov cs:[bUnit], al
	cmp al, cs:[base.bUnits]
	mov al, 1
	jnc ERRORX
nounit:
	movzx ax, es:[bx].RPH.bOp
	add al, al
	jc HighVec
	cmp al, LVECTOR
	jnc ERROR3
	mov si, offset VECTOR
LowVec:
	add si, ax
	jmp word ptr cs:[si]
HighVec:
	mov si, offset VECT2
	cmp al, LVECT2
	jc LowVec
ERROR3::
	mov al,3
ERRORX::
	mov ah,81h
	stc
	jmp exit1
EXIT::
	mov ax, 100h
	clc
exit1:
	mov sp, bp
	push cs:[oldint0d]
	pop dword ptr ds:[13*4]
	mov [bp+2*2+7*4], ax
	lds bx, cs:[dwReq]
	mov [bx].RPH.wStat, ax
	pop es
	pop ds
	popad
	retf
ENTRY endp

;--- IOCTL input

IOCTLI proc
	les si, es:[bx].RPIOC.dwAddr
	mov al, es:[si+0]
	cmp al, LIVEC
	jnc ERROR3
	add al, al
	movzx di, al
	call cs:[di][IVEC]
	jmp EXIT
IOCTLI endp

IOC_GETHDR:
	mov word ptr es:[si+1], 0
	mov es:[si+3], cs
	ret

IOC_DEVST:
	mov dword ptr es:[si+1], 2		; DOOR LOCK ? OPEN=1 UNLOCK=2
	ret

IOC_SECSIZ:
	mov word ptr es:[si+2], SECSIZE
	ret

IOC_MEDIA proc
	push si
	call Setup
	mov [edi].CT.Pkt0, 14AH	; ACMD.00: 4A,01,00,00 (4A=get event status notification)
	mov [edi].CT.Pkt1, 10H	; ACMD.04: 10,00,00,00 (10=req "media" notification
	mov [edi].CT.Pkt2, 8	; ACMD.08: 08,00,00,00 (08=low byte "allocation length")
	call Req8
	pop si
	and al, al
	jnz MEDCHG

	mov eax, cs:[pBuff]
	mov ax, [eax].EVENT4A.wED0	; get first 2 bytes of event data

	and al, al
	jnz MEDCHG
	test ah, 2
	jz MEDCHG
	mov byte ptr es:[si+1], 1
	jmp MEDEND
MEDCHG:
	mov byte ptr es:[si+1], 0
MEDEND:
	push si
	call Setup
	call ReqSen
	pop si

	mov eax, cs:[pBuff]
	mov al, [eax].FFSD.bFlgs	; fixed format sense data

	and al, FFSDF_SKMASK		; mask sense key
	jz @F
	mov byte ptr es:[si+1], 0
	cmp al, SK_UNIT_ATTENTION	; ???
	jz MEDEND					; ??? very improbable to be useful
@@:
	ret
IOC_MEDIA endp

;--- Read long (cmd 128)
;--- the read is always done thru the sector buffer.
;--- it's possible to read directly into the dst buffer if it's word-aligned.

READLS struct
	org -10
dwSector dd ?
wSecCnt  dw ?
pXfer    dd ?
READLS ends

READL proc
	cmp es:[bx].RPRL.bAMode, 0	; addressing mode HS?
	jnz ERROR3
	cmp es:[bx].RPRL.bDMode, 0	; transfer mode "cooked"?
	jnz ERROR3

	push es:[bx].RPRL.dwAddr	; transfer address
	push es:[bx].RPRL.wSecCnt	; sector count
	push es:[bx].RPRL.dwStart	; start sector
ReadLP:
	cmp [bp].READLS.wSecCnt, 0
	jz EXIT
	call Setup
	mov cx, word ptr [bp].READLS.dwSector+2
	xchg cl, ch
	shl ecx, 16
	mov cl, 28h
	mov [edi].CT.Pkt0, ecx		; ACMD.00: bOC=28(read cooked),00,dwLBA.04,dwLBA.03
	movzx ecx, word ptr [bp].READLS.dwSector+0
	xchg cl, ch
	mov [edi].CT.Pkt1, ecx		; ACMD.04: dwLBA.02,dwLBA.01,bGrp=0,wLength.02=00
	mov [edi].CT.Pkt2, 1		; ACMD.08: wLength.01=01,00,00,00 
	mov ecx, (GENINT shl 31) or ( SECSIZE - 1 )	; value for PRDT.dwCnt
	call ReqECX
	and al, al
	jnz rl_error
	mov ecx, SECSIZE shr 2
	les di, [bp].READLS.pXfer
	movzx edi, di
	mov esi, cs:[pBuff]
	cld
	rep movsd es:[edi], ds:[esi]
	add word ptr [bp].READLS.pXfer+2, SECSIZE shr 4
	inc [bp].READLS.dwSector
	dec [bp].READLS.wSecCnt
	jmp ReadLP

rl_error:
	call Setup
	call ReqSen
	and al, al
	jnz @f
	mov eax, cs:[pBuff]
	mov al, [eax].FFSD.bFlgs
	and al, FFSDF_SKMASK		; mask sense key
	mov bx, offset ERRTAB
	xlatb cs:[bx]
@@:
	jmp ERRORX

READL endp

;--- setup command list, command table, port.CMD
;--- out:
;--- esi=linear address port
;--- edi=linear address command table

Setup proc
	mov al, cs:[bUnit]
	add al, al
	movzx si, al
	movzx esi, cs:[si][wPorts]
	add esi, cs:[pHBA]
	add al, al

	mov edx, dword ptr [esi].PORT.dqCLB		; get command list base
	mov edi, [edx].CLH.dwCTBA				; get command table base address
	mov dword ptr [edx].CLH.flags1, 10025H	; 25,00,0001 [CFL=5 dwords, A=1,PRDTL=1]
	mov [edx].CLH.PRDBC, 0

	mov [edi].CT.cfis0, 1A08027H	; 27,80,A0,01 [27=H2D register FIS,80=set command register,A0=ATAPI packet command,01=Features]
	mov [edi].CT.cfis1, 0FFFF00H	; 00,FF,FF,00 [LBA low,mid,high,device]
	mov [edi].CT.cfis2, 0			; 00,00,00,00 [LBA (exp) low,mid,high,features]
	mov [edi].CT.cfis3, 1			; 01,00,00,00 [sector count, sector count,res,control]
	mov ecx, cs:[pBuff]
	mov [edi].CT.p0.dwBase, ecx
	xor ecx, ecx
	mov [edi].CT.p0.dwBaseU, ecx
	mov [edi].CT.p0.dwRsvd, ecx
	xor ecx, ecx
	mov [esi].PORT.dwIE, ecx
	or ecx, -1
	mov [esi].PORT.dwIS, ecx
	mov [esi].PORT.dwSERR, ecx
	mov ecx, [esi].PORT.dwCMD
	or cl, 10h			; P.CMD.FRE
	mov [esi].PORT.dwCMD, ecx
	or cl, 1			; P.CMD.ST
	mov [esi].PORT.dwCMD, ecx
waitst:
	mov eax, [esi].PORT.dwCMD
	test ax, 8000H		; P.CMD.CR
	jz waitst
	ret
Setup endp

;--- ReqSen: request sense notification

ReqSen:
	mov [edi].CT.Pkt0, 3	; ACMD.00: 03,00,00,00 (03=request sense)
	mov [edi].CT.Pkt1, 8	; ACMD.04: 08,00,00,00
	mov [edi].CT.Pkt2, 0	; ACMD.08: 00,00,00,00

;--- fall thru
;--- Req8:   entry for IOC_MEDIA

Req8:
	mov ecx, (GENINT shl 31) or (8-1)	; PRDT.dwCnt: 0000007 (transfer 8 bytes, I)

;--- get ECX bytes
;--- start transfer from ATAPI device
;--- out: AL=0 ok, AL!=0 failure

ReqECX proc
	mov [edi].CT.p0.dwCnt, ecx
	mov [esi].PORT.dwCI, 1
cont_wait:
	cmp [esi].PORT.dwCI, 0
	jz FIN
	bt [esi].PORT.dwIS, 30
	jc FINERR
	cmp [esi].PORT.dwSERR, 0
	jz cont_wait
FINERR:
	call Stop
	mov al, DE_GENFAILURE
	ret
FIN:
	mov eax, [esi].PORT.dwTFD
	test al, 1
	jnz FINERR
	call Stop
	mov al, 0
	ret

Stop:
	mov ecx, [esi].PORT.dwCMD
	or cl, 8
	and cl, 0EEH
	mov [esi].PORT.dwCMD, ecx
	retn
ReqECX endp

;--- handle exception 0D

int0d proc
	push ax
	mov al, 0Bh
	out 20h, al
	in al, 20h
	test al, 20h	; real IRQ 5?
	pop ax
	jz @F
	db 0eah
oldint0d dd ?
@@:
	push ds
	push eax
	lgdt fword ptr cs:[gdtr]
	mov eax, cr0
	inc ax
	mov cr0, eax
	jmp @F
@@:
	dec ax
	push SEL_FLAT
	pop ds
	mov cr0, eax
	pop eax
	pop ds
	iret
int0d endp

bUnit db 0	; current unit ( index for wPorts )
	align 4
dwReq dd 0	; current request packet

	align 16

ENDRES label byte

_TEXT ends

_ITEXT segment use16 word public 'CODE'

DGROUP group _ITEXT

bDev    db 0		; /C cmdline option default
bQuiet  db 0		; /Q cmdline option

GetPCI proc		;ECX = index
	mov eax, ecx
	mov dx, 0cf8h
	out dx, eax
	mov dl, 0fch
	in eax, dx
	mov dl, 0f8h
	ret
GetPCI endp

INIT proc

	mov eax, cs
	mov word ptr es:[bx].RPInit.dwFree+0, offset ENDRES
	mov word ptr es:[bx].RPInit.dwFree+2, ax
	shl eax, 4
	add dword ptr cs:[gdtr+2], eax	;set GDTR linear address

	lds si, es:[bx].RPInit.CmdLine
	cld

;--- skip driver path & name

nextsp:
	lodsb
	cmp al, ' '
	ja nextsp
	dec si

;--- scan arguments

nextchar:
	lodsb
	cmp al, ' '
	jz nextchar
	cmp al, 9
	jz nextchar
	cmp al, 13
	jz donecmdl
	cmp al, 0
	jz donecmdl
	cmp al, '/'
	jnz errcmdl
	lodsb
	mov ah, [si]
	or al, 20h
	cmp ax, ':c'
	jz isOptC
	cmp ax, ':d'
	jz isOptD
	cmp al, 'q'
	jz isOptQ
	jmp errcmdl

isOptD:
	push cs
	pop es
	inc si
	mov di, DRIVER.name_
	mov cx, sizeof DRIVER.name_
	pusha
	mov al, ' '
	rep stosb
	popa
nextdevchar:
	lodsb
	cmp al, ' '
	jbe doneOptD
	cmp al, 'a'
	jb @F
	cmp al, 'z'
	ja @F
	sub al, 20H
@@:
	stosb
	loop nextdevchar
	inc si
doneOptD:
	dec si
	jmp nextchar

isOptC:
	inc si
	lodsb
	sub al, '0'
	jb errcmdl
	cmp al, 9
	ja errcmdl
	mov cs:[bDev], al
	jmp nextchar
isOptQ:
	mov cs:[bQuiet], 1
	jmp nextchar

donecmdl:

	cmp cs:[bQuiet], 0
	jnz @F
	push cs
	pop ds
	mov dx, offset banner
	mov ah, 9
	int 21h
@@:

	smsw ax
	test ax, 1
	jnz errnov86

;--- scan PCI for AHCI controllers

	mov dx, 0cf8h
	in eax, dx
	mov ebx, eax
	mov ecx, 80000008h
nextHBA:
	call GetPCI
	shr eax, 8
	cmp eax, 10601H		; AHCI controller?
	jz foundHBA
skipHBA:
	add ecx, 100h
	cmp ecx, 81000008h
	jc nextHBA
	mov eax, ebx
	out dx, eax
	jmp errnodisk
foundHBA:
	dec cs:[bDev]
	jns skipHBA

	mov cl, 24h	;get ABAR5
	call GetPCI
	mov cs:[pHBA], eax
	mov esi, eax
	mov eax, ebx
	out dx, eax

;--- get XMS address and enable A20

	mov ax, 4300h
	int 2Fh
	test al, 80h
	jz errnoxmm
	mov ax, 4310h
	int 2Fh
	mov word ptr cs:[xmmad+0], bx
	mov word ptr cs:[xmmad+2], es
	mov ah, 5				; local enable A20
	call cs:[xmmad]

;--- first usage of "unreal" mode

	push 0
	pop ds
	mov eax, [esi].HBA.dwGHC
	test eax, 80000000H		; AHCI enabled?
	JZ errinact

;--- scan ports

	mov ebx, [esi].HBA.dwPI	; get port bitmask
	mov edx, 100h
	xor cx, cx
	mov di, offset wPorts
nextport:
	shr ebx, 1
	jc foundport
	jz doneports
contport:
	add dx, 80h
	jmp nextport
foundport:
	mov eax, [esi+edx].PORT.dwSIG
	cmp eax, 0EB140101H		; ATAPI device?
	jnz contport
	mov eax, [esi+edx].PORT.dwSSTS
	and al, 0fh
	cmp al, 3				; communication established?
	jnz contport
	mov cs:[di], dx			; ok, valid atapi device found
	add di, 2
	inc cx
	cmp di, offset wPorts + sizeof wPorts	; max reached?
	jb contport
doneports:
	mov cs:[base.bUnits], cl
	and cl, cl
	jz errnodisk

	add cs:[msg4], cl
	mov dx, offset msg4
	push ds
	push cs
	pop ds
	mov ah, 9
	int 21h
	pop ds

;--- set sector buffer address

	les bx, cs:[dwReq]

ife ?EXTMEM

;--- sector buffer in conv. memory (behind resident driver code)

	add word ptr ES:[BX].RPInit.dwFree+0, SECSIZE

	xor eax, eax
	xor edx, edx
	mov ax, cs
	shl eax, 4
	mov dx, offset ENDRES
	add eax, edx
	mov cs:[pBuff], eax
else

;--- sector buffer in extended memory

	mov dx, 4		; get 4 kB extended memory
	mov ah, 9
	call cs:[xmmad]
	and ax, ax
	jz errnomem
	mov ah, 0Ch		; lock block
	call cs:[xmmad]
	push dx
	push bx
	pop ebx

;--- ensure that sector buffer won't cross a page boundary
;--- for AHCI, this check isn't really necessary. 

	lea esi, [ebx+800h]
	mov al, bh
	and al, 0Ch		; mask bits 10+11: if 00/04/08 ok, if 0C -> add 800h to DX:BX
	cmp al, 0Ch
	jnz @F
	xchg esi, ebx
@@:
	mov cs:[pBuff], ebx

;--- relocate CL, FIS and CT

	mov edi, cs:[pHBA]
	movzx cx, cs:[base.bUnits]
	mov bx, offset wPorts
	lea eax, [esi+CLSIZE]
@@:
	movzx edx, word ptr cs:[bx]
	mov dword ptr [edi+edx].PORT.dqCLB, esi
	mov dword ptr [edi+edx].PORT.dqFB, eax
	add bx, 2
	loop @B

	xor ecx, ecx
	xor eax, eax
nextdw:
	mov [esi+ecx*4], eax
	inc cx
	cmp cx, (CLSIZE+FBSIZE+sizeof CT)/4
	jnz nextdw
	lea eax, [esi+CLSIZE+FBSIZE]
	mov [esi].CLH.dwCTBA, eax
endif
	jmp EXIT

errinact:
	mov dx, offset msg5
	jmp errout
errnov86:
	mov dx, offset msg6
	jmp errout
errnoxmm:
	mov dx, offset msg7
	jmp errout
if ?EXTMEM
errnomem:
	mov dx, offset msg8
	jmp errout
endif
errcmdl:
	mov dx, offset msg2
	jmp errout
errnodisk:
	mov dx, offset msg3
errout:
	push ds
	push cs
	pop ds
	mov ah, 9
	int 21h
	mov ds:[base.wAttr], 0
	pop ds
	jmp ERROR3

INIT endp

banner  db 'AHCI CD/DVD Driver v1.2',13,10
        db "Based upon Rudolph R. Loew's AHCICD driver.",13,10
        db 'Using unreal-mode, incompatible with V86-mode.',13,10
        db '$'
msg2    db 'SYNTAX: DEVICE=AHCICDU.SYS /D:devname [/Q][/C:#]',13,10,'$'
msg3    db 'No AHCI Optical Disk Found',13,10,'$'
msg4    db '0 AHCI Optical Disk(s) Found',13,10,'$'
msg5    db 'AHCI Controller not in AHCI Mode',13,10,'$'
msg6    db "AHCICDU can't work in V86 mode",13,10,'$'
msg7    db 'No XMM installed',13,10,'$'
if ?EXTMEM
msg8    db 'Alloc extended memory failed',13,10,'$'
endif

_ITEXT ends

	END
