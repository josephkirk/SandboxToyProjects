@echo off
pushd %~dp0

echo ========================================
echo Building Zig Client Simulator...
echo ========================================
pushd client_sim
zig build-exe main.zig -O ReleaseSafe
if %ERRORLEVEL% NEQ 0 (
    echo [ERROR] Zig build failed!
    popd
    exit /b %ERRORLEVEL%
)
popd

echo ========================================
echo Starting Odin Server (Headless)...
echo ========================================
start "Odin Server" game_release.exe --headless

echo ========================================
echo Starting Zig Client Simulator...
echo ========================================
client_sim\main.exe

popd
