@echo off
pushd %~dp0

echo Starting Odin Server (Headless)...
start "Odin Server" game_release.exe --headless

echo Starting Unreal Engine Client...
"G:\Epic\UE_5.7\Engine\Binaries\Win64\UnrealEditor.exe" "%~dp0renderer\OdinRender\OdinRender.uproject" -game -log -windowed -resx=1280 -resy=720

popd
