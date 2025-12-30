@echo off
echo Building WindSim in ReleaseFast mode...
zig build -Doptimize=ReleaseFast
if %ERRORLEVEL% NEQ 0 (
    echo Build failed!
    pause
    exit /b %ERRORLEVEL%
)
echo Build successful! Artifacts are in .\zig-out\bin
pause
