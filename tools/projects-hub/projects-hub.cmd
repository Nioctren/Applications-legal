@echo off
rem Lance Projects Hub dans Windows PowerShell. Options transmises : -NoFetch
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0projects-hub.ps1" %*
