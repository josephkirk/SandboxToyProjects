@echo off
pushd %~dp0
call "G:\Epic\UE_5.7\Engine\Build\BatchFiles\Build.bat" OdinRenderEditor Win64 Development "G:\Projects\SandboxDev\Odin\renderer\OdinRender\OdinRender.uproject" -waitmutex
popd
