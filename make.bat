@echo off
rem makes ahcicdu.sys
jwasm -nologo -bin -Sg -Fl -Fo=AHCICDU.SYS ahcicdu.asm
rem alternately using MS tools
rem ml -c -Sg -Fl ahcicdu.asm
rem \msvc\bin\link /tiny ahcicdu.obj, AHCICDU.SYS, ahcicdu.map;
