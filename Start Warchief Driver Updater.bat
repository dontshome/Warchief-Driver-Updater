@echo off
:: Launches the Warchief Driver Updater GUI. For the Horde!
start "" powershell -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0WarchiefDriverUpdater.ps1"
