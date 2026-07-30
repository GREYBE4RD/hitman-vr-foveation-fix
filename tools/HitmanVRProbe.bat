@echo off
rem  Read-only diagnostic. It writes nothing to the game.
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0HitmanVRProbe.ps1"
