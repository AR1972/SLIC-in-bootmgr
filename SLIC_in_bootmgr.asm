file 'bin\bootmgr_part1'
;
;
;==============================================================================
;
; SLIC in bootmgr - reversed by untermensch 05/14/2010 (file version 0.03)
; original author(s) unknown possibly gkend
; assemble with FASM - http://flatassembler.net/
;
;==============================================================================
;
org 0
use16
;
;==============================================================================
loader:
;-------------------------------------------------------------------------------

		call	$+3
		pop	bx
		sub	bx, loader
		shr	bx, 4
		mov	ax, cs
		add	bx, ax
		push	cs
		pushad
		push	bx
		mov	ds, bx
		push	EntryPoint0
		sgdt	fword [ds:SavedGDT]
		retf

;==============================================================================

GDT1:
		dw    0 	; limit
		dw    0 	; base
		db    0 	; hibase
		db    0 	; access
		db    0 	; hilimit
		db    0 	; msbase

		dw    0FFFFh	; limit
		dw    0 	; base
		db    0 	; hibase
		db    93h	; access
		db    0 	; hilimit
		db    0 	; msbase

		dw    0FFFFh	; limit
		dw    0 	; base
		db    0 	; hibase
		db    93h	; access
		db    8Fh	; hilimit (4GB)
		db    0 	; msbase
GDT1_END:
GDTR		dw    GDT1_END - GDT1 - 1h
GDT		dd    0

;==============================================================================

EntryPoint0:

;==============================================================================
OpenA20Gate:
;------------------------------------------------------------------------------

		mov	al, 0D1h
		out	64h, al
	 loc_14F:
		in	al, 64h
		test	al, 2
		jnz	loc_14F
		mov	al, 0DFh
		out	60h, al
		mov	al, 0FFh
		out	64h, al
		mov	al, 2
		out	92h, al

;==============================================================================
SwitchToProtectedMode:
;------------------------------------------------------------------------------

		mov	eax, cs
		shl	eax, 4
		add	eax, GDT1
		mov	[ds:GDT], eax

		cli
		lgdt	fword [ds:GDTR]
		mov	eax, cr0
		or	al, 1
		mov	dx, 10h
		mov	cr0, eax
		jmp	short $+2
		mov	fs, dx
		and	al, 0FEh
		mov	cr0, eax
		jmp	short $+2

		push	0
		pop	fs

;==============================================================================
FindRSDP:
;------------------------------------------------------------------------------
; search BIOS area for RSDP, from FFFE0 to E0000
;------------------------------------------------------------------------------

		mov	eax, 0FFFE0h
FindRSDPLoop:
		cmp	dword [fs:eax], 'RSD '
		jnz	GetNext
		cmp	dword [fs:eax+4], 'PTR '
		jz	RSDPFound
GetNext:
		sub	eax, 10h
		cmp	eax, 0E0000h
		ja	FindRSDPLoop
		jmp	JumpBoot

;==============================================================================
RSDPFound:
;------------------------------------------------------------------------------
; entry:
; EAX has RSDP addr
; leave:
; EAX has RSDT addr
; EBX has RSDP addr
; EDX had RSDT len + 4
;------------------------------------------------------------------------------

		mov	[ds:RSDPAddr], eax	   ; save RSDP addr
		mov	ebx, eax		   ; move RSDP addr to EBX
		cmp	byte [fs:ebx+15], 02h	   ; check RSDP revision
		jnge	SkipXSDT		   ; skip if not >= 02h
		mov	eax, [fs:ebx+18h]	   ; move XSDT addr to eax
		mov	[ds:XSDTAddr], eax	   ; save XSDT addr
SkipXSDT:
		mov	eax, [fs:ebx+10h]	   ; move RSDT addr to EAX
		mov	[ds:RSDTAddr], eax	   ; save RSDT addr
		mov	edx, [fs:eax+4] 	   ; move RSDT len to EDX
		add	edx, 4			   ; add 4 to RSDT len
		mov	[fs:eax+4], edx 	   ; write len back to RSDT
		cmp	edx, [fs:eax+4] 	   ; check if the write took
		jnz	JumpBoot		   ; quit if no
		push	ebx			   ; save RSDP to stack
		call	FindExistingSLIC	   ; on retn EBX has SLIC addr
		pop	ecx			   ; pop RSDP to ECX
		mov	eax, [ds:XSDTAddr]	   ; move XSDT addr to EAX
		cmp	byte [fs:ebx+15], 02h
		jnge	JumpBoot
		cmp	dword [fs:ecx+1Ch], 0	   ; sanity check on XSDT addr
		jnz	JumpBoot		   ; quit if insane
		or	eax, eax		   ; check if XSDT is null
		jz	JumpBoot		   ; quit if yes

;==============================================================================
; patch XSDT with SLIC pointer
; entry:
; EBX has SLIC addr
; EAX has XSDT addr
; leave:
;
;------------------------------------------------------------------------------

		cmp	dword [fs:eax], 'XSDT'	   ; check first dw of XSDT for XSDT
		jnz	JumpBoot		   ; quit if no
		cmp	dword [fs:ebx], 'SLIC'	   ; check for SLIC sig in EBX
		jnz	SkipSLICXSDT		   ;
		mov	edx, [fs:eax+4] 	   ; move XSDT len to EDX
;------------------------------------------------------------------------------
; modification to overwrite a pointer when there is not enough
; room for the SLIC pointer.
;------------------------------------------------------------------------------
		cmp	dword [fs:eax+edx], 0	   ; check for space for SLIC pointer
		jne	OverwriteXSDTPointer
		cmp	dword [fs:eax+edx+4], 0    ; check for space for SLIC pointer
		jne	OverwriteXSDTPointer
		mov	[fs:eax+edx], ebx	   ; move SLIC pointer to XSDT
		jmp	WriteXSDTPointerDone
OverwriteXSDTPointer:
		push	eax			   ; push XSDT addr to stack
		push	ebx			   ; push SLIC pointer to stack
		add	eax, edx		   ; EAX now point's to end of XSDT
		sub	eax, 8			   ; subtract 8 to point to start of last entry
		mov	ecx, edx		   ; move XSDT len to ECX
		sub	ecx, 24h		   ; subtract XSDT header
		shr	ecx, 3			   ; divide by 8
OverwriteXSDTPointerLoop:
		mov	ebx, [fs:eax]		   ; move XSDT entry to EBX
		cmp	dword [fs:ebx], 'BOOT'	   ; compare table sig to BOOT
		je	OverwriteXSDTPointerLoopDone
		cmp	dword [fs:ebx], 'MCFG'	   ; compare table sig to MCFG
		je	OverwriteXSDTPointerLoopDone
		sub	eax, 8			   ; point EAX to next XSDT entry
		loop	OverwriteXSDTPointerLoop
OverwriteXSDTPointerLoopDone:
		pop	ebx			   ; pop SLIC pointer to EBX
		mov	[fs:eax], ebx		   ; move SLIC pointer to XSDT
		pop	eax
;------------------------------------------------------------------------------
WriteXSDTPointerDone:
		add	dword [fs:eax+4], 8	   ; add 8 to XSDT len
SkipSLICXSDT:
		push	JumpBoot
		jmp	OEMIDTable

;==============================================================================

JumpBoot:
		jmp	Boot

;==============================================================================

AddSLIC:
		mov	ebx, [ds:SLICAddr]

;==============================================================================
ZeroScan:
;------------------------------------------------------------------------------
; find room for table
; this is a failure point, some MB's write other than 00h to memory
; this should be changed to find the high table add the length
;------------------------------------------------------------------------------

		lea	esi, [ebx+20000h]	   ; move max RAM to search to esi
SetCounter:
		mov	cx, 90h 		   ; move 90h to CX
ZeroScanLoop:
		cmp	dword [fs:ebx], 0	   ; compare RAM loc to 0
		jnz	NotZero 		   ; not 0 jump
		add	ebx, 4			   ; else add 4
		dec	cx			   ; deincrement CX
		jnz	ZeroScanLoop		   ; loop
		jmp	ZeroScanSuccess 	   ; found enough space for SLIC
NotZero:
		add	ebx, 4			   ; add 4 to EBX
		cmp	ebx, esi		   ; check if EBX past max RAM to search
		jb	SetCounter		   ; if not jump back into loop
		jmp	ZeroScanFail		   ; else fail
NextTableXSDTChk:
		cmp	dword [fs:edx], 'XSDT'	   ; check if next table is XSDT
		jz	ZeroScanFail		   ; if not jump to move table, else fail
		cmp	dword [fs:edx], 'RSDT'
		jnz	MoveTableBegin
ZeroScanFail:
		sub	dword [fs:eax+4], 4	   ; subtract 4 from RSDT len
		retn
ZeroScanSuccess:
		sub	ebx, 200h

;==============================================================================
CopySLIC:
;------------------------------------------------------------------------------
; entry:
; EBX has SLIC pointer
; EAX has RSDT addr
; EDX has RSDT len + 4
; leave:
; EAX has RSDT addr
; EBX has SLIC pointer
; EDX points to end of RSDT
;------------------------------------------------------------------------------

		mov	cx, 176h		   ; SLIC length
		mov	si, SLIC
		mov	edi, ebx		   ; move SLIC pointer to EDI
		push	ax			   ; save RSDT addr
WriteSLICLoop:
		lodsb				   ; load byte of SLIC to AL
		mov	[fs:edi], al		   ; move AL to SLIC
		inc	edi			   ; incriment to netx byte of SLIC
		loop	WriteSLICLoop		   ; loop until CX = 0
		pop	ax			   ; pop RSDT addr
		call	OEMIDTable		   ; add OEMID to RSDT
RSDTSLICPointerChk:
		sub	edx, 4			   ; RETN if SLIC overwrite, substract 4 from RSDT len
		add	edx, eax		   ; add RSDT addr to RSDT len
		mov	ecx, [fs:edx]		   ; move address entry to be patched to ECX
		or	ecx, ecx		   ; check if zero
		jnz	NextTableXSDTChk	   ; if not gotta move the table
		mov	[fs:edx], ebx		   ; else patch RSDT with SLIC pointer
		retn

;==============================================================================
MoveTableBegin:
;------------------------------------------------------------------------------
; entry:
; EAX has RSDT addr
; EBX has SLIC pointer
; EDX points to end of RSDT
;------------------------------------------------------------------------------

		mov	ecx, edx		   ; move RSDT end to ECX
FindTableLoop:
		cmp	[fs:edx-4], ecx 	   ; find table to move pointer
		jz	MoveTable		   ; found pointer move table
		sub	edx, 4			   ; else subtract 4, move to next table entry
		cmp	edx, eax		   ; check if EDX and RSDT pointer begin equal
		ja	FindTableLoop		   ; loop if greater
		mov	[fs:ecx], ebx		   ; else write SLIC pointer to end of RSDT
		retn

;==============================================================================

MoveTable:
		mov	edi, ecx		   ; move RSDT end to EDI
		mov	ecx, [fs:edi+4] 	   ; move table to move len to ECX
		mov	si, Empty		   ; move temp table loc to SI
		push	edi			   ; save RSDT end
		push	ax			   ; save RSDT addr
MoveTableLoop:
		mov	al, [fs:edi]		   ; move tabel to temp loc
		mov	[si], al		   ;
		inc	si			   ;
		inc	edi			   ;
		loop	MoveTableLoop		   ; loop until ECX = 0
		pop	ax			   ; pop RSDT addr
		pop	esi			   ; pop RSDT end
		jmp	MoveTableFinish

;==============================================================================
OEMIDTable:
;------------------------------------------------------------------------------
; EAX has table to be patched addr
;------------------------------------------------------------------------------

		mov	si, SLIC + 0Ah		   ; beginning of slic oem id
		mov	cx, 0Eh 		   ; length of slic oem id + table id
		lea	edi, [eax+0Ah]		   ; move table OEMID start to EDI
		push	ax			   ; save table addr to stack
OEMIDTableLoop:
		lodsb				   ; load byte of SLIC OEMID to AL
		mov	[fs:edi], al		   ; move AL to table
		inc	edi			   ; increment to next byte of OEMID
		loop	OEMIDTableLoop		   ; loop until CX = 0
		pop	ax			   ; restore table addr
		retn

;==============================================================================

MoveTableFinish:
		mov	byte [ds:CopySLIC], 0C3h   ; change first instruction of CopySLIC to RETN
		mov	[fs:esi], ebx		   ; move SLIC pointer to end of RSDT
		push	ebx			   ; save SLIC pointer
		call	ZeroScan		   ; RETN with tables new addr in EBX

		mov	[fs:edx-4], ebx 	   ; EBX has tables new loc, update the RSDT pointer

;------------------------------------------------------------------------------
; >>>>> modification to update XSDT with moved table's new location <<<<<
; this should be changed to scan the XSDT pointer's for the moved
; tables old location then overwrite that pointer.
;------------------------------------------------------------------------------
		mov	eax, [ds:XSDTAddr]	   ; move XSDT addr to EAX
		add	eax, [fs:eax+4] 	   ; add XSDT len to EAX
		mov	[fs:eax-8], ebx 	   ; overwrite last entry of XSDT
;------------------------------------------------------------------------------

		mov	si, Empty		   ; move temp loc to SI
		mov	cx, [si+4]		   ; move tabel len in temp loc to CX
MoveTableFinishLoop:
		lodsb				   ; load byte of tabel in temp loc to AL
		mov	[fs:ebx], al		   ; move byte to new loc
		inc	ebx			   ; increment EBX
		loop	MoveTableFinishLoop	   ; loop until CX = 0
		pop	ebx			   ; pop SLIC pointer to EBX
		retn

;==============================================================================
FindExistingSLIC:
;------------------------------------------------------------------------------
; entry:
; EAX has RSDT addr
; EDX has RSDT len
; leave:
; EAX has RSDT addr
; EBX has SLIC pointer
; EDX has RSDT len
;------------------------------------------------------------------------------

		mov	ecx, eax		   ; move RSDT addr to ECX
		add	ecx, 24h		   ; add 24h (36) bytes moves to
LoopFindSLICPointer:				   ; begin of RSDT pointers
		mov	ebx, [fs:ecx]		   ; move begin RSDT pointers to EBX
		cmp	dword [fs:ebx], 'SLIC'	   ; check if entry points to SLIC
		jz	SLICFound		   ; if yes end
		add	ecx, 4			   ; if no increment to next entry
		push	ecx			   ; save entry to stack
		sub	ecx, eax		   ; subtract RSDT addr from RSDT entry ?
		cmp	ecx, edx		   ; compare result with RSDT len
		pop	ecx			   ; pop table entry to ECX
		jnb	NoSLICFound		   ; jump to no SLIC found
		cmp	ebx, [ds:SLICAddr]	   ; compare EBX to saved addr
		jbe	LoopFindSLICPointer	   ; loop if below equal
		mov	[ds:SLICAddr], ebx	   ; save entry
		jmp	LoopFindSLICPointer	   ; loop
NoSLICFound:
		jmp	AddSLIC
SLICFound:
		mov	byte [ds:RSDTSLICPointerChk], 0C3h    ; modify instruction at RSDTSLICPointerChk to RETN
		sub	dword [fs:eax+4], 4		      ; subtract 4 from RSDT len
		jmp	CopySLIC

;==============================================================================
Boot:
;------------------------------------------------------------------------------
; done, return control to bootmgr
;------------------------------------------------------------------------------

		popad
		mov	ax, ds
		pop	bx
		push	bx
		sub	ax, bx
		shl	ax, 4
		sub	ax, 3D28h
		push	ax
		lgdt	fword [ds:SavedGDT]
		retf

;==============================================================================
;
;==============================================================================
; begin data section
; some extra stuff here to help with debugging
;------------------------------------------------------------------------------
;
align 10h
SLIC:
file  'slic.bin'
;
align 10h
SavedGDT df 0
db '-GDT'

align 10h
RSDPAddr dd 0
db '---RSDP'

align 10h
RSDTAddr dd 0
db '---RSDT'

align 10h
XSDTAddr dd 0
db '---XSDT'

align 10h
SLICAddr dd 0
db '---SLIC'

align 10h
Empty:
;
;==============================================================================
; end data section
;------------------------------------------------------------------------------
;
times 1000h - ($-$$) db 0
file '\bin\bootmgr_part2'
;
;