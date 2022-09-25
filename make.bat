@echo off
rem makes ahcicdu.sys
jwasm -nologo -bin -Sg -Fl -D?EXTMEM=1 -Fo=ahcicdu.sys ahcicdu.asm
