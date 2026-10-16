@echo off
chcp 65001 >nul
REM =====================================================================
REM repair-on-windows.bat - AI Repair USB, Scene 3 Windows online repair entry
REM Created: 2026-10-13  Version: 0.3.1
REM NOTE: This file must stay pure ASCII (English only). Chinese comments in
REM       a .bat break cmd parsing after chcp 65001 (parser re-seeks the file
REM       with the new codepage and mis-splits multi-byte lines, executing
REM       comment text as commands - the mojibake bug fixed in 0.3.1).
REM Role: switch console to UTF-8 (R41, so the ps1's Chinese output renders),
REM       then run repair-on-windows.ps1 from the same directory.
REM       No UAC here - the ps1 mode menu requests elevation only when
REM       "repair mode" is chosen (R3/R4 read-only fallback on refusal).
REM Both entry names are identical by design (see design doc 9-3).
REM =====================================================================

title AI Repair USB - Windows Online Repair
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0repair-on-windows.ps1"
pause
