@echo off
REM =====================================================================
REM repair-on-windows.bat - AI 电脑维修U盘 · 场景③ Windows 在线维修 双击入口
REM 创建日期: 2026-10-13  版本: 0.1.0（RDD R1）
REM 作用: UTF-8 控制台（R41 中文不乱码）+ 请求 UAC 提权后调用同目录
REM       repair-on-windows.ps1（标准自提升模式；拒绝提权时 ps1 侧降级
REM       为只读诊断模式，R3/R4）
REM 提示: 本文件须与 repair-on-windows.ps1 一起放在U盘数据分区根目录
REM =====================================================================

REM 控制台切换 UTF-8 代码页（中文输出）
chcp 65001 >nul

REM 请求 UAC 提权：非管理员时以管理员身份重启自身
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo 正在请求管理员权限（请在弹出的 UAC 窗口点「是」）...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

REM 已具备管理员权限：同目录调用 ps1（-File 保证 $PSScriptRoot 定位U盘根，R5）
title AI 电脑维修U盘 - Windows 在线维修
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0repair-on-windows.ps1" -Elevated
pause
