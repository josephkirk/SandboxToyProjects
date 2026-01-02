@echo off
pushd %~dp0

echo ========================================
echo Building Zig Client Simulator...
echo ========================================
pushd client_sim
zig run client_sim/test_simulation.zig