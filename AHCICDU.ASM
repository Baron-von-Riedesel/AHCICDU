
;--- AHCI CD/DVD driver,
;--- based on R. Loew's AHCICD.SYS,
;--- uses "unreal-mode" to access addresses beyond 0x100000.

;--- define _TEXT before .model to allow "align 8" & "align 4".
;--- ( this isn't Masm-compatible! ).

_TEXT segment para public 'CODE'
_TEXT ends

	.model tiny
	.586p	; p-suffix needed to switch to "unreal" mode
	option casemap:none

DRIVER struct
pNext	dd ?
wAttr	dw ?
ofsStr	dw ?
ofsInt	dw ?
name_	db 8 dup (?)
DRIVER ends

PORT struct
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

CLH struct
flags1  db ?	;+0  P[7]=Prefetchable, W[6]=Write, A[5]=ATAPI, CFL[4:0]=Command FIS Length
flags2  db ?	;+1  PMP[15:12]=Port Multiplier Port, R[11]=Reserved, C[10]=Clear Busy, B[9]=BIST, R[8]=Reset
PRDTL   dw ?	;+2  Physical Region Descriptor Table Length
PRDBC   dd ?	;+4  Physical Region Descriptor Byte Count
dwCTBA  dd ?	;+8  Command Table Base Address bits 0-31 (128 byte aligned)
dwCTBAU dd ?	;+12 Command Table Base Address bits 32-63
	dd 4 dup (?)
CLH ends

@setint0d macro
	push 0
	pop ds
	mov bx, cs
	shl ebx, 16
	mov bx, offset int0d
	xchg ebx, ds:[13*4]
	mov cs:[oldint0d], ebx
endm
@restint0d macro
	push cs:[oldint0d]
	pop dword ptr ds:[13*4]
endm

	.code

BASE label byte
	DRIVER <-1,0C800H,offset STRAT,offset ENTRY,'-       '>

        DW 0
        DB 0
COUNT   DB 0
        DB 'AHCI CD/DVD DOS Driver',0

	align 8

gdt label qword
	dw -1,0,9200h,0CFh	; 32-bit flat data descriptor
;	dw -1,0,9200h,0		; 16-bit data descriptor

gdtr dw 2*8-1,0,0

;--- cmds 00-0E
VECTOR  DW      INIT,ERROR3,ERROR3,IOCTLI,ERROR3,ERROR3,ERROR3,ERROR3
        DW      ERROR3,ERROR3,ERROR3,ERROR3,ERROR3,EXIT,EXIT
LVECTOR equ $ - offset VECTOR

;--- cmds 80-82
VECT2   DW      READL,ERROR3,EXIT
LVECT2  equ $ - offset VECT2

;--- IOCTL subcmds
IVEC    DW      GETHDR,ERROR3,ERROR3,ERROR3,ERROR3,ERROR3,DEVST,SECSIZ
        DW      ERROR3,MEDIA
LIVEC   equ ($ - offset IVEC) shr 1

dwReq   DD      0
SECCNT  DW      0
wPorts  DW      0,0,0,0,0,0	;port offsets (100h,180h,...)
ERRTAB  DB      12,12,2,4,12,0,15,8,8,12,12,12,12,12,12,12
	align 4
XFERAD  DD      0
SECTOR  DD      0
pHBA    DD      0
PBUFF   DD      0	; linear address sector buffer
oldint0d dd     0
bUnit   db      0
bQuiet  db      0

STRAT:
    MOV     word ptr CS:[dwReq+0], BX
    MOV     word ptr CS:[dwReq+2], ES
    RETF

ENTRY:
    CLD
    PUSHAD
    PUSH    DS
    PUSH    ES
    @setint0d
    LES     BX, CS:[dwReq]
    cmp     byte ptr ES:[BX+2], 0
    JZ      NOUNIT
    mov     al, ES:[BX+1]
    mov     cs:[bUnit], al
    cmp     AL, CS:[COUNT]
    MOV     AL,1
    JNC     ERRORX
NOUNIT:
    SUB     AH,AH
    MOV     AL,ES:[BX+2]
    ADD     AL,AL
    JC      HIGHV
    CMP     AL,LVECTOR
    JNC     ERROR3
    MOV     SI,OFFSET VECTOR
LOWVEC:
    ADD     SI,AX
    JMP     WORD PTR CS:[SI]
HIGHV:
    MOV     SI,OFFSET VECT2
    CMP     AL,LVECT2
    JC      LOWVEC
ERROR3:
    MOV     AL,3
ERRORX:
    MOV     AH,81H
    STC
    JMP     EXIT1
EXIT:
    MOV     AX,100H
    CLC
EXIT1:
	@restint0d
    LDS     BX, CS:[dwReq]
    MOV     DS:[BX+3],AX
    POP     ES
    POP     DS
	mov bp,sp
	MOV [bp+28],AX
    POPAD
    RETF

IOCTLI:
    LES     SI, ES:[BX+14]
    MOV     AL,ES:[SI]
    CMP     AL,LIVEC
    JNC     ERROR3
    MOV     DI,OFFSET IVEC
IOCTL:
    ADD     AL,AL
    SUB     AH,AH
    ADD     DI,AX
    JMP     WORD PTR CS:[DI]

GETHDR:
    MOV     WORD PTR ES:[SI+1],0
    MOV     ES:[SI+3],CS
    JMP     EXIT

DEVST:
    MOV     DWORD PTR ES:[SI+1],2           ;DOOR LOCK ? OPEN=1 UNLOCK=2
    JMP     EXIT

SECSIZ:
    MOV     WORD PTR ES:[SI+2],2048
    JMP     EXIT

MEDIA:
    PUSH    SI
    CALL    SETUP
	mov dword ptr [edi+40h], 14AH	; ACMD.00: 4A,01,00,00
	mov dword ptr [edi+44H], 10H	; ACMD.04: 10,00,00,00
	mov dword ptr [edi+48H], 8		; ACMD.08: 08,00,00,00
    CALL    REQ8
    POP     SI
    AND     AL,AL
    JNZ     MEDCHG

	mov eax, cs:[PBUFF]
	mov ax, [eax][4]

    AND     AL,AL
    JNZ     MEDCHG
    TEST    AH,2
    JZ      MEDCHG
    MOV     BYTE PTR ES:[SI+1],1
    JMP     MEDEND
MEDCHG:
    MOV     BYTE PTR ES:[SI+1],0
MEDEND:
    PUSH    SI
    CALL    SETUP
    CALL    REQSEN
    POP     SI

	mov eax, cs:[PBUFF]
	mov al, [eax][2]

    AND     AL,15
    JZ      EXIT
    MOV     BYTE PTR ES:[SI+1],0
    CMP     AL,6
    JZ      MEDEND
    JMP     EXIT

;   +1=UNIT +14=ADDRESS +18=SEC COUNT +20=START SEC

READL:
    CMP     BYTE PTR ES:[BX+13],0
    JNZ     ERROR3
    CMP     BYTE PTR ES:[BX+24],0
    JNZ     ERROR3
    MOV     EAX, ES:[BX+14]
    MOV     CS:[XFERAD], EAX
    MOV     AX, ES:[BX+18]
    MOV     CS:[SECCNT], AX
    MOV     EAX, ES:[BX+20]
    MOV     CS:[SECTOR], EAX
READLP:
    CMP     WORD PTR CS:[SECCNT],0
    JZ      EXIT
    CALL    SETUP
    MOV     ECX,CS:[SECTOR]
    SHR     ECX,16
    XCHG    CL,CH
    SHL     ECX,16
    MOV     CX,28H		; ACMD.00: 28h,00,SECTOR.04,SECTOR.03
	mov [edi+40h], ecx
	MOVZX ECX,WORD PTR CS:[SECTOR]
	XCHG CL,CH			; ACMD.04: SECTOR.02, SECTOR.01
	mov [edi+44h], ecx
	mov dword ptr [edi+48h], 1			; ACMD.08: 01,00,00,00 
	mov dword ptr [edi+8Ch], 800007FFH	; PRDT.0C: FF,07,00,80
    CALL    DOIT
    AND     AL,AL
    JZ      GOOD
    CALL    SETUP
    CALL    REQSEN
    AND     AL,AL
    JNZ     ERRORX

	mov eax, cs:[PBUFF]
	mov al, [eax][2]

    AND  AL, 15
    mov  BX, OFFSET ERRTAB
    XLAT cs:[bx]
    JMP  ERRORX

GOOD:
	push es
	MOV ECX,200H
	LES DI,CS:[XFERAD]
	movzx edi, di
	mov esi, cs:[PBUFF]
	CLD
	REP MOVSD es:[edi], ds:[esi]
	pop es

    ADD     WORD PTR CS:[XFERAD+2],80H
    INC     DWORD PTR CS:[SECTOR]
    DEC     WORD PTR CS:[SECCNT]
    JMP     READLP

;--- setup command list, command table, port.CMD
;--- out:
;--- esi=linear address port
;--- edi=linear address command table

SETUP:
	MOV AL, CS:[bUnit]
	mov AH, 0
	ADD AL, AL
	mov SI, AX
	MOVZX ESI, CS:[si][wPorts]
	add esi, cs:[pHBA]
	add al, al

	mov edx, dword ptr [esi].PORT.dqCLB		; get command list base
	mov edi, [edx].CLH.dwCTBA				; get command table base address
	mov dword ptr [edx].CLH.flags1, 10025H	; CL.00: 25,00,01,00 [CFL=5 dwords, A=1,PRDTL=1]
	mov dword ptr [edx].CLH.PRDBC, 0		; CL.04: 00,00,00,00 [PRDBC=0]

	mov dword ptr [edi+0], 1A08027H	; CT.00: 27,80,A0,01 [27=H2D register FIS,80=set command register,A0=ATAPI packet command,01=Features]
	mov dword ptr [edi+4], 0FFFF00H	; CT.04: 00,FF,FF,00 [LBA low,mid,high,device]
	XOR ECX, ECX
	mov [edi+8], ecx	; CT.08: 00,00,00,00 [LBA (exp) low,mid,high,features]
	MOV ECX, 1
	mov [edi+12], ecx	; CT.0C: 01,00,00,00 [sector count, sector count,res,control]
	MOV ECX, CS:[PBUFF]
	mov [edi+80h], ecx	; CT.PRDT.base+0
	XOR ECX, ECX
	mov [edi+84h], ecx	; CT.PRDT.base+4
	mov [edi+88h], ecx	; CT.PRDT.reserved
	XOR ECX, ECX
	mov [esi].PORT.dwIE, ecx
	MOV ECX, -1
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

REQSEN:
	mov dword ptr [edi+40h], 3	; ACMD.00: 03,00,00,00
	mov dword ptr [edi+44h], 8	; ACMD.04: 08,00,00,00
	mov dword ptr [edi+48h], 0	; ACMD.08: 00,00,00,00
REQ8:
	mov dword ptr [edi+8Ch], 80000007H	; PRDT.0C: 07,00,00,80 (PRC=7 transfer 8 bytes, 80=I)
DOIT:
	mov dword ptr [esi+38h], 1	;P.CI
WAITEN:
    mov eax, [esi+38h]	;P.CI
    AND EAX,EAX
    JZ  FIN
    mov eax, [esi+10h]	;P.IS
    TEST EAX,40000000H	;P.IS.30
    JNZ FINERR
    mov eax, [esi+30h]	;P.SERR
    AND EAX,EAX
    JZ  WAITEN
FINERR:
    CALL STOP
    MOV  AL,12
    JMP  PROCER
FIN:
    mov  eax, [esi+20h]	;P.TFD
    TEST AL,1
    JNZ  FINERR
    CALL STOP
    XOR  AX,AX
PROCER:
    RET

STOP:
	mov ecx, [esi+18h]
	OR CL,8
	AND CL,0EEH
	mov [esi+18h], ecx
    RET

;--- handle exception 0D

SEL_FLAT equ 8

int0d:
	push ax
	mov al, 0Bh
	out 20h, al
	in al, 20h
	test al, 20h	; real IRQ 5?
	pop ax
	jz @F
	jmp cs:[oldint0d]
@@:
	push ds
	push eax
	mov eax, cs
	shl eax, 4
	add eax, offset gdt-8
	mov dword ptr cs:[gdtr+2],eax	;set GDTR linear address
	lgdt fword ptr cs:[gdtr]
	mov eax,cr0
	inc ax
	mov cr0,eax
	jmp @F
@@:
	dec ax
	push SEL_FLAT
	pop ds
	mov cr0,eax
	pop eax
	pop ds
	iret

	ALIGN 16

ENDRES label byte

	.code _ITEXT

DGROUP group _ITEXT

xmsad dd 0

GETPCI:
    PUSH    EDX                      ;EDX = ADDR+80000000
    PUSH    EBX
    PUSH    EDX
    MOV     DX,0CF8H
    IN      EAX,DX
    MOV     EBX,EAX
    POP     EAX
    OUT     DX,EAX
    MOV     DL,0FCH
    IN      EAX,DX
    MOV     DL,0F8H
    PUSH    EAX
    MOV     EAX,EBX
    OUT     DX,EAX
    POP     EAX
    POP     EBX
    POP     EDX
    RET

INIT:
    MOV WORD PTR ES:[BX+14],OFFSET ENDRES
    LDS SI,ES:[BX+12H]

;--- skip driver path & name

@@:
	lodsb
	cmp al,' '
	ja @B
	dec si

	xor bp,bp

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
	MOV DI,DRIVER.name_
	mov cx, sizeof DRIVER.name_
	pusha
	mov al,' '
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
	cmp al, '0'
	jb errcmdl
	cmp al, '9'
	Ja errcmdl
	sub al, '0'
	mov ah,0
	mov bp, ax
	jmp nextchar
isOptQ:
	mov cs:[bQuiet], 1
	jmp nextchar

donecmdl:

	cmp cs:[bQuiet], 0
	jnz @F
    PUSH CS
    POP DS
    MOV DX,OFFSET MESS
    MOV AH,9
    INT 21H
@@:

;--- scan PCI for AHCI controllers

    PUSH 0
    POP DS
    MOV     EDX,80000008H
FNDHBA:
    CALL    GETPCI
    AND     EAX,0FFFFFF00H
    CMP     EAX,1060100H
    JZ      GOTHBA
NXTHBA:
    ADD     EDX,100H
    CMP     EDX,81000008H
    JC      FNDHBA
    JMP     NG
GOTHBA:
    DEC     BP
    JNS     NXTHBA

	smsw ax
	test ax,1
	jz @F
	mov dx,offset msg6
	jmp NG1
msg6 db "AHCICDU can't work in V86 mode",13,10,'$'
@@:
	mov dl,24h	;get ABAR5
	call GETPCI
	mov cs:[pHBA],eax

	mov esi, eax

;--- get XMS address and enable A20

	mov ax, 4300h
	int 2Fh
	test al, 80h
	jz errnoxmm
	mov ax, 4310h
	int 2Fh
	mov word ptr cs:[xmsad+0],bx
	mov word ptr cs:[xmsad+2],es
	mov ah, 5		; local enable A20
	call cs:[xmsad]

;--- first usage of "unreal" mode

	mov eax, [esi+4]
    TEST    EAX,80000000H	; AHCI enabled?
    JZ      INACT

;--- scan ports

	mov ecx, [esi+0Ch]		; get port bitmask
    MOV     EDX,100H
    XOR     bx, bx
    MOV     DI,OFFSET wPorts
NEXTPRT:
    AND     ECX,ECX
    JZ      DONEPORTS
    TEST    CL,1
    JNZ     YESPRT
SKIPPORT:
    SHR     ECX, 1
    ADD     DX, 80H
    JMP     NEXTPRT
YESPRT:
    mov eax, [esi+edx+24h]
    CMP     EAX,0EB140101H	; ATAPI device?
    JNZ     SKIPPORT
    mov eax, [esi+edx+28h]
    AND     AL,0FH
    CMP     AL, 3			; communication established?
    JNZ     SKIPPORT
    MOV     CS:[DI], DX		; ok, valid ATAPI device found
    ADD     DI, 2
    INC     bx
    CMP     bx, 6			; reached max of 6 devices?
    JC      SKIPPORT

DONEPORTS:
    MOV     CX, BX
    MOV     CS:[COUNT], CL
    AND     CL, CL
    JZ      NG

    add     CS:[MESS4], CL
    MOV     DX, OFFSET MESS4
	push ds
	push cs
	pop ds
    MOV AH,9
    INT 21H
	pop ds

;--- set sector buffer address

	les bx, cs:[dwReq]
if 0

;--- sector buffer in conv. memory (behind resident driver code)

    MOV     AX, CS
    ADD     AX, 80H		;80h paragraphs = 2048
    MOV     ES:[BX+16],AX

    XOR     EAX,EAX
    XOR     EDX,EDX
    MOV     AX,CS
    SHL     EAX,4
    MOV     DX,OFFSET ENDRES
    ADD     EAX,EDX
    MOV     CS:[PBUFF],EAX
else

;--- sector buffer in extended memory

    MOV ES:[BX+16], CS
	mov dx, 4		; get 4 kB extended memory
	mov ah, 9
	call cs:[xmsad]
	and ax, ax
	jz errnomem
	mov ah, 0Ch		; lock block
	call cs:[xmsad]
	push dx
	push bx
	pop ebx
	lea esi, [ebx+800h]
	mov al, bh
	and al, 0Ch		; mask bits 10+11: if 00/04/08 ok, if 0C -> add 800h to DX:BX
	cmp al, 0Ch
	jnz @F
	xchg esi, ebx
@@:
	mov cs:[PBUFF], ebx

;--- relocate CL, FIS and CT

	mov edi, cs:[pHBA]
	movzx cx, cs:[COUNT]
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
@@:
	mov [esi+ecx*4], eax
	inc cx
	cmp cx, 500h/4
	jnz @B
	lea eax, [esi+500h]
	mov [esi].CLH.dwCTBA, eax
endif
    JMP     EXIT

INACT:
    MOV     DX,OFFSET MESS5
    JMP     NG1
errnoxmm:
    MOV     DX,OFFSET msg7
    JMP     NG1
errnomem:
    MOV     DX,OFFSET msg8
    JMP     NG1
errcmdl:
    MOV     DX,OFFSET MESS2
    JMP     NG1
NG:
    MOV     DX,OFFSET MESS3
NG1:
	push ds
    PUSH    CS
    POP     DS
    MOV     AH,9
    INT     21H
	pop ds
    MOV     WORD PTR CS:[BASE+4],0
    JMP     ERROR3

MESS    DB      'AHCI Optical Drive Driver  Version 1.2',13,10
        DB      "Based upon Rudolph R. Loew's AHCICD driver.",13,10
        DB      'Using unreal-mode, incompatible with V86-mode.',13,10
        DB      '$'
MESS2   DB      'SYNTAX: DEVICE=AHCICDU.SYS /D:devname [/Q][/C:#]',13,10,'$'
MESS3   DB      'No AHCI Optical Disk Found',13,10,'$'
MESS4   DB      '0 AHCI Optical Disk(s) Found',13,10,'$'
MESS5   DB      'AHCI Controller not in AHCI Mode',13,10,'$'
msg7    DB      'No XMM installed',13,10,'$'
msg8    DB      'Alloc extended memory failed',13,10,'$'

    END
