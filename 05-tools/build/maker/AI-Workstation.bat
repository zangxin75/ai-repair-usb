@echo off
chcp 65001 >nul
REM =====================================================================
REM repair-on-windows.bat - AI 电脑维修U盘 · 场景③ Windows 在线维修 双击入口
REM 创建日期: 2026-10-13  版本: 0.3.0（P-A A2）
REM 作用: UTF-8 控制台（R41 中文不乱码）后直接调用同目录
REM       repair-on-windows.ps1。本入口不自动请求 UAC 提权——
REM       ps1 先出模式菜单（维修/办公助手/余额），选择「维修模式」
REM       时才按需触发 UAC；拒绝提权则降级只读诊断模式（R3/R4）。
REM 提示: 本文件须与 repair-on-windows.ps1 一起放在U盘数据分区根目录；
REM       本文件与 AI-Workstation.bat 内容完全一致（双入口命名，设计 §9-3）
REM =====================================================================

REM 控制台切换 UTF-8 代码页（已提前至首行生效）

REM 直接调用 ps1（-File 保证 $PSScriptRoot 定位U盘根，R5；提权由 ps1 模式菜单按需触发）
title AI 电脑维修U盘 - Windows 在线维修
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0repair-on-windows.ps1"
pause
