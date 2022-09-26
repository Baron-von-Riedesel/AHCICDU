
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
GENINT  equ 1		; 1=generate interrupt if transfer complete

	.386p	; p-suffix needed to switch to "unreal" mode
	option casemap:none

DRIVER struct
pNext	dd ?
wAttr	dw ?
ofsStr	dw ?
ofsInt	dw ?
name_	db 8 dup (?)
DRIVER ends

;--- DOS "Request Packet" header

RPH struct
Len     db  ?       ;+0 Header byte count.
bSubU   db  ?       ;+1 Subunit number.
bOp     db  ?       ;+2 Command code.
wStat   dw  ?       ;+3 Status field.
        db 8 dup (?);+5 .. +12 (reserved).
RPH ends

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

	assume ds:nothing,ss:nothing

_TEXT segment use16 para public 'CODE'

DGROUP group _TEXT

base DRIVER <-1, 0C800H, offset STRAT, offset ENTRY, 'CD1$$$$$'>

        DW 0
        DB 0
bCount  DB 0
        DB 'AHCI CD/DVD DOS Driver'

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

wPorts  DW 0,0,0,0,0,0	;port offsets (100h,180h,...)
ERRTAB  DB 12,12,2,4,12,0,15,8,8,12,12,12,12,12,12,12
	align 4
pHBA    DD 0	; linear address HBA
pBuff   DD 0	; linear address sector buffer
xmmad   dd 0	; XMM entry

STRAT proc
	MOV word ptr CS:[dwReq+0], BX
	MOV word ptr CS:[dwReq+2], ES
	RETF
STRAT endp

ENTRY proc
	PUSHAD
	PUSH DS
	PUSH ES
	mov bp, sp

	push 0
	pop ds
	mov bx, cs
	mov eax, ds:[13*4]
	shl ebx, 16
	mov bx, offset int0d
	mov cs:[oldint0d], eax
	mov ds:[13*4], ebx

	LES BX, CS:[dwReq]
	cmp ES:[BX].RPH.bOp, 0	;Init?
	JZ NOUNIT
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
	mov al, ES:[BX].RPH.bSubU
	mov cs:[bUnit], al
	cmp AL, CS:[bCount]
	MOV AL, 1
	JNC ERRORX
NOUNIT:
	movzx ax, ES:[BX].RPH.bOp
	ADD AL, AL
	JC HIGHV
	CMP AL, LVECTOR
	JNC ERROR3
	MOV SI, OFFSET VECTOR
LOWVEC:
	ADD SI, AX
	JMP WORD PTR CS:[SI]
HIGHV:
	MOV SI, OFFSET VECT2
	CMP AL, LVECT2
	JC LOWVEC
ERROR3::
	MOV AL,3
ERRORX::
	MOV AH,81H
	STC
	JMP EXIT1
EXIT::
	MOV AX, 100H
	CLC
EXIT1:
	mov sp, bp
	push cs:[oldint0d]
	pop dword ptr ds:[13*4]
	MOV [bp+2*2+7*4], AX
	LDS BX, CS:[dwReq]
	MOV [BX].RPH.wStat, AX
	POP ES
	POP DS
	POPAD
	RETF
ENTRY endp

;--- IOCTL input
;--- es:[bx+14]=transfer addr

IOCTLI proc
	LES SI, ES:[BX+14]
	MOV AL, ES:[SI+0]
	CMP AL, LIVEC
	JNC ERROR3
	ADD AL, AL
	movzx di, al
	call CS:[DI][IVEC]
	jmp EXIT
IOCTLI endp

IOC_GETHDR:
	MOV WORD PTR ES:[SI+1], 0
	MOV ES:[SI+3], CS
	ret

IOC_DEVST:
	MOV DWORD PTR ES:[SI+1], 2		; DOOR LOCK ? OPEN=1 UNLOCK=2
	ret

IOC_SECSIZ:
	MOV WORD PTR ES:[SI+2], SECSIZE
	ret

IOC_MEDIA proc
	PUSH SI
	CALL SETUP
	mov [edi].CT.Pkt0, 14AH	; ACMD.00: 4A,01,00,00 (4A=get event status notification)
	mov [edi].CT.Pkt1, 10H	; ACMD.04: 10,00,00,00
	mov [edi].CT.Pkt2, 8	; ACMD.08: 08,00,00,00
	CALL REQ8
	POP SI
	AND AL, AL
	JNZ MEDCHG

	mov eax, cs:[pBuff]
	mov ax, [eax][4]

	AND AL, AL
	JNZ MEDCHG
	TEST AH, 2
	JZ MEDCHG
	MOV BYTE PTR ES:[SI+1], 1
	JMP MEDEND
MEDCHG:
	MOV BYTE PTR ES:[SI+1], 0
MEDEND:
	PUSH SI
	CALL SETUP
	CALL REQSEN
	POP SI

	mov eax, cs:[pBuff]
	mov al, [eax][2]

	AND AL, 15
	JZ @F
	MOV BYTE PTR ES:[SI+1], 0
	CMP AL, 6
	JZ MEDEND
@@:
	ret
IOC_MEDIA endp

;--- Read long (cmd 128)
;--- Request struct: +1=UNIT +14=ADDRESS +18=SEC COUNT +20=START SEC
;--- the read is always done thru the sector buffer.
;--- it's possible to read directly into the dst buffer if it's word-aligned.

READLS struct
	org -10
dwSector dd ?
wSecCnt  dw ?
pXfer    dd ?
READLS ends

READL proc
	CMP BYTE PTR ES:[BX+13], 0
	JNZ ERROR3
	CMP BYTE PTR ES:[BX+24], 0
	JNZ ERROR3

	push dword ptr ES:[BX+14]	; transfer address
	push  word ptr ES:[BX+18]	; sector count
	push dword ptr ES:[BX+20]	; start sector
READLP:
	CMP [bp].READLS.wSecCnt, 0
	JZ EXIT
	CALL SETUP
	MOV ECX, [bp].READLS.dwSector
	SHR ECX, 16
	XCHG CL, CH
	SHL ECX, 16
	MOV CX, 28H
	mov [edi].CT.Pkt0, ecx	; ACMD.00: 28h,00,SECTOR.04,SECTOR.03 (28=read cooked)
	MOVZX ECX, WORD PTR [bp].READLS.dwSector+0
	XCHG CL, CH
	mov [edi].CT.Pkt1, ecx	; ACMD.04: SECTOR.02, SECTOR.01
	mov [edi].CT.Pkt2, 1	; ACMD.08: 01,00,00,00 
	mov ecx, (GENINT shl 31) or ( SECSIZE - 1 )	; value for PRDT.dwCnt
	CALL REQECX
	AND AL, AL
	JNZ rl_error
	MOV ECX, SECSIZE shr 2
	LES DI, [bp].READLS.pXfer
	movzx edi, di
	mov esi, cs:[pBuff]
	CLD
	REP MOVSD es:[edi], ds:[esi]
	ADD WORD PTR [bp].READLS.pXfer+2, SECSIZE shr 4
	INC [bp].READLS.dwSector
	DEC [bp].READLS.wSecCnt
	JMP READLP

rl_error:
	CALL SETUP
	CALL REQSEN
	AND AL, AL
	JNZ @F
	mov eax, cs:[pBuff]
	mov al, [eax][2]
	AND AL, 15
	mov BX, OFFSET ERRTAB
	XLAT cs:[bx][ERRTAB]
@@:
	JMP ERRORX

READL endp

;--- setup command list, command table, port.CMD
;--- out:
;--- esi=linear address port
;--- edi=linear address command table

SETUP proc
	MOV AL, CS:[bUnit]
	ADD AL, AL
	movzx si, al
	MOVZX ESI, CS:[si][wPorts]
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
	MOV ECX, CS:[pBuff]
	mov [edi].CT.p0.dwBase, ecx
	XOR ECX, ECX
	mov [edi].CT.p0.dwBaseU, ecx
	mov [edi].CT.p0.dwRsvd, ecx
	XOR ECX, ECX
	mov [esi].PORT.dwIE, ecx
	or ECX, -1
	mov [esi].PORT.dwIS, ecx
	mov [esi].PORT.dwSERR, ecx
	mov ecx, [esi].PORT.dwCMD
	OR CL, 10H			; P.CMD.FRE
	mov [esi].PORT.dwCMD, ecx
	OR CL, 1			; P.CMD.ST
	mov [esi].PORT.dwCMD, ecx
WAITST:
	mov eax, [esi].PORT.dwCMD
	TEST AX, 8000H		; P.CMD.CR
	JZ WAITST
	RET
SETUP endp

;--- start transfer from ATAPI device
;--- REQSEN: request sense notification
;--- REQ8:   entry for IOC_MEDIA
;--- REQECX: entry for READL

REQSEN:
	mov [edi].CT.Pkt0, 3	; ACMD.00: 03,00,00,00 (03=request sense)
	mov [edi].CT.Pkt1, 8	; ACMD.04: 08,00,00,00
	mov [edi].CT.Pkt2, 0	; ACMD.08: 00,00,00,00
REQ8:
	mov ecx, (GENINT shl 31) or (8-1)	; PRDT.dwCnt: 0000007 (transfer 8 bytes, I)
REQECX:						; <--- entry, ECX=PRDT.dwCnt
	mov [edi].CT.p0.dwCnt, ecx
	mov [esi].PORT.dwCI, 1
WAITEN:
	mov eax, [esi].PORT.dwCI
	AND EAX, EAX
	JZ FIN
	mov eax, [esi].PORT.dwIS
	TEST EAX, 40000000H	;P.IS.30
	JNZ FINERR
	mov eax, [esi].PORT.dwSERR
	AND EAX, EAX
	JZ WAITEN
FINERR:
	CALL STOP
	MOV AL, 12
	JMP PROCER
FIN:
	mov eax, [esi].PORT.dwTFD
	TEST AL, 1
	JNZ FINERR
	CALL STOP
	XOR AX, AX
PROCER:
	RET

STOP:
	mov ecx, [esi].PORT.dwCMD
	OR CL, 8
	AND CL, 0EEH
	mov [esi].PORT.dwCMD, ecx
	RET

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
dwReq DD 0	; current request packet

	ALIGN 16

ENDRES label byte

_TEXT ends

_ITEXT segment use16 word public 'CODE'

DGROUP group _ITEXT

bDev    db 0		; /C cmdline option default
bQuiet  db 0		; /Q cmdline option

GETPCI proc		;ECX = index
	mov eax, ecx
	MOV DX, 0CF8H
	OUT DX, EAX
	MOV DL, 0FCH
	IN EAX, DX
	mov dl, 0F8h
	RET
GETPCI endp

INIT proc

	mov eax, cs
	shl eax, 4
	add dword ptr cs:[gdtr+2], eax	;set GDTR linear address
	MOV WORD PTR ES:[BX+14], OFFSET ENDRES
	LDS SI, ES:[BX+12H]
	CLD

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
	cmp AL, 'q'
	jz isOptQ
	jmp errcmdl

isOptD:
	PUSH CS
	POP ES
	inc si
	MOV DI, DRIVER.name_
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
	Ja errcmdl
	mov cs:[bDev], al
	jmp nextchar
isOptQ:
	mov cs:[bQuiet], 1
	jmp nextchar

donecmdl:

	cmp cs:[bQuiet], 0
	jnz @F
	PUSH CS
	POP DS
	MOV DX, OFFSET MESS
	MOV AH,9
	INT 21H
@@:

	smsw ax
	test ax, 1
	jnz errnov86

;--- scan PCI for AHCI controllers

	MOV DX, 0CF8H
	IN EAX, DX
	MOV EBX, EAX
	MOV ECX, 80000008H
FNDHBA:
	CALL GETPCI
	AND EAX, 0FFFFFF00H
	CMP EAX, 1060100H
	JZ GOTHBA
NXTHBA:
	ADD ECX, 100H
	CMP ECX, 81000008H
	JC FNDHBA
	mov eax, ebx
	out dx, eax
	JMP NG
GOTHBA:
	DEC cs:[bDev]
	JNS NXTHBA

	mov cl, 24h	;get ABAR5
	call GETPCI
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

	PUSH 0
	POP DS
	mov eax, [esi].HBA.dwGHC
	TEST EAX, 80000000H		; AHCI enabled?
	JZ INACT

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
	mov cs:[bCount], cl
	and cl, cl
	jz NG

	add CS:[MESS4], CL
	MOV DX, OFFSET MESS4
	push ds
	push cs
	pop ds
	MOV AH, 9
	INT 21H
	pop ds

;--- set sector buffer address

	les bx, cs:[dwReq]

ife ?EXTMEM

;--- sector buffer in conv. memory (behind resident driver code)

	MOV AX, CS
	ADD AX, SECSIZE shr 4
	MOV ES:[BX+16], AX

	XOR EAX, EAX
	XOR EDX, EDX
	MOV AX, CS
	SHL EAX, 4
	MOV DX, OFFSET ENDRES
	ADD EAX, EDX
	MOV CS:[pBuff], EAX
else

;--- sector buffer in extended memory

	MOV ES:[BX+16], CS
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
	movzx cx, cs:[bCount]
	mov bx, offset wPorts
	lea eax, [esi+400h]
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
	cmp cx, 500h/4
	jnz nextdw
	lea eax, [esi+500h]
	mov [esi].CLH.dwCTBA, eax
endif
	JMP EXIT

INACT:
	MOV DX, OFFSET MESS5
	JMP NG1
errnov86:
	mov dx, offset msg6
	jmp NG1
errnoxmm:
	MOV DX, OFFSET msg7
	JMP NG1
if ?EXTMEM
errnomem:
	MOV DX, OFFSET msg8
	JMP NG1
endif
errcmdl:
	MOV DX, OFFSET MESS2
	JMP NG1
NG:
	MOV DX, OFFSET MESS3
NG1:
	push ds
	PUSH CS
	POP DS
	MOV AH, 9
	INT 21H
	MOV ds:[base.wAttr], 0
	pop ds
	JMP ERROR3

INIT endp

MESS    DB 'AHCI CD/DVD Driver v1.2',13,10
        DB "Based upon Rudolph R. Loew's AHCICD driver.",13,10
        DB 'Using unreal-mode, incompatible with V86-mode.',13,10
        DB '$'
MESS2   DB 'SYNTAX: DEVICE=AHCICDU.SYS /D:devname [/Q][/C:#]',13,10,'$'
MESS3   DB 'No AHCI Optical Disk Found',13,10,'$'
MESS4   DB '0 AHCI Optical Disk(s) Found',13,10,'$'
MESS5   DB 'AHCI Controller not in AHCI Mode',13,10,'$'
msg6    db "AHCICDU can't work in V86 mode",13,10,'$'
msg7    DB 'No XMM installed',13,10,'$'
if ?EXTMEM
msg8    DB 'Alloc extended memory failed',13,10,'$'
endif

_ITEXT ends

	END
