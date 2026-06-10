@echo off
setlocal
cd /d "%~dp0"
start "" mshta.exe "%~dp0KakaoWorkExporter.hta"
exit /b 0
