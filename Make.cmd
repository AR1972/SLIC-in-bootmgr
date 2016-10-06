@echo OFF
"%~dp0bin\FASM.EXE"  "%~dp0SLIC_in_bootmgr.asm"
MOVE "%~dp0SLIC_in_bootmgr.bin" "%~dp0bootmgr"
pause
