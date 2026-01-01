@echo off
pushd %~dp0

echo ========================================
echo 1. Generating FlatBuffers Schemas and Wrappers...
echo ========================================
uv run python tools\build_schemas.py
if %ERRORLEVEL% NEQ 0 (
    echo [ERROR] Schema generation failed!
    popd
    exit /b %ERRORLEVEL%
)

echo ========================================
echo 2. Building Odin Game...
echo ========================================
"%~dp0..\thirdparties\odin-windows-amd64-dev-2025-12a\dist\odin.exe" build game -out:game_release.exe -o:speed
if %ERRORLEVEL% NEQ 0 (
    echo [ERROR] Odin build failed!
    popd
    exit /b %ERRORLEVEL%
)

echo ========================================
echo 3. Building Unreal Project...
echo ========================================
call "G:\Epic\UE_5.7\Engine\Build\BatchFiles\Build.bat" OdinRenderEditor Win64 Development "G:\Projects\SandboxDev\Odin\renderer\OdinRender\OdinRender.uproject" -waitmutex
if %ERRORLEVEL% NEQ 0 (
    echo [ERROR] Unreal build failed!
    popd
    exit /b %ERRORLEVEL%
)

echo ========================================
echo           BUILD SUCCESSFUL
echo ========================================
popd
