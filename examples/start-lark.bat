@echo off
rem ===================================================================
rem  dsh-lark-bot launcher  (Windows)
rem
rem  HOW TO USE:
rem    1. Open this file with Notepad
rem    2. Replace YOUR_API_KEY_HERE with your DeepSeek API key
rem    3. Save, then double-click this file
rem
rem  Get a key: https://platform.deepseek.com/api_keys
rem  (existing keys never expire - you may reuse one)
rem
rem  ------------------------------------------------------------------
rem  IMPORTANT - keep this file ASCII-only with CRLF line endings.
rem  cmd.exe reads .bat files using the local ANSI code page, so UTF-8
rem  text (especially with a BOM) gets mangled, line breaks shift, and
rem  comments start being executed as commands.
rem  ------------------------------------------------------------------
rem ===================================================================
setlocal

title dsh-lark-bot

rem ===== [1] YOUR DEEPSEEK API KEY - the only line you must edit =====
set "DEEPSEEK_API_KEY=YOUR_API_KEY_HERE"

rem ===== [2] runtime + data dir (put the DSH runtime on a big drive) =====
set "DSH_HOME=D:\dsh"
set "DSH_BIN=D:\dsh\profiles\node_modules\@deepseek-ai\dsh\lib\bin.js"

rem ===== [3] model route =====
rem NOTE: the DeepSeek API model id is "deepseek-flash", NOT
rem       "deepseek-v4-flash". The rc.8 provider is patched by
rem       reapply-patches.ps1 to match - keep these spellings.
rem       Use "deepseek-v4-pro" for the stronger model.
set "DSH_LARK_PROVIDER=deepseek-official"
set "DSH_LARK_MODEL=deepseek-flash"

if "%DEEPSEEK_API_KEY%"=="YOUR_API_KEY_HERE" goto :nokey

if not exist "%DSH_BIN%" goto :nobin

echo.
echo   Starting dsh-lark-bot ...
echo   ==========================================
echo    DSH_HOME : %DSH_HOME%
echo    Provider : %DSH_LARK_PROVIDER%
echo    Model    : %DSH_LARK_MODEL%
echo   ==========================================
echo.
echo   First run prints a QR code - scan it with the Feishu app.
echo   Keep this window open; closing it takes the bot offline.
echo   Press Ctrl+C to stop.
echo.

node "%DSH_BIN%" --profile dsh-lark

echo.
echo   Exited.
pause
exit /b 0

:nokey
echo.
echo   [X] API key is not set yet.
echo.
echo       Open this file with Notepad and change:
echo           set "DEEPSEEK_API_KEY=YOUR_API_KEY_HERE"
echo       to:
echo           set "DEEPSEEK_API_KEY=sk-your-real-key"
echo.
echo       Get a key at: https://platform.deepseek.com/api_keys
echo.
pause
exit /b 1

:nobin
echo.
echo   [X] dsh runtime not found at:
echo       %DSH_BIN%
echo.
echo       Install it first, e.g.:
echo           npm install --prefix D:\dsh\profiles @deepseek-ai/dsh@0.1.0-rc.8
echo.
pause
exit /b 1
