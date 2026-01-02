<#
.SYNOPSIS
    Project management script for Odin Game Server and Zig Client.
    
.DESCRIPTION
    Centralizes building, running, and testing for the whole project.
    
.EXAMPLE
    .\manage.ps1 build-server
    .\manage.ps1 run-server -Headless
    .\manage.ps1 run-client
#>

param (
    [Parameter(Mandatory=$true, Position=0)]
    [ValidateSet("build-server", "build-client", "build-all", "run-server", "run-client", "test", "clean", "help")]
    $Action,

    [switch]$Headless,
    [switch]$WithServer,
    [string]$Transport = "ipc",
    [string]$Sync = "authoritative"
)

# Credits: Nguyen Phi Hung

$ProjectRoot = Get-Item "$PSScriptRoot\..\.."
$OdinRoot = "$ProjectRoot\Odin"
$ZigRoot = "$OdinRoot\renderer\ZigClient"
$OdinExe = "g:\Projects\SandboxDev\thirdparties\odin-windows-amd64-dev-2025-12a\dist\odin.exe"

function Build-OdinServer {
    Write-Host "[BUILD] Building Odin Server..." -ForegroundColor Cyan
    Push-Location $OdinRoot
    & $OdinExe build game -out:game/vampire_survival.exe
    Pop-Location
}

function Build-ZigClient {
    Write-Host "[BUILD] Building Zig Client..." -ForegroundColor Cyan
    Push-Location $ZigRoot
    zig build
    Pop-Location
}

function Run-OdinServer {
    Write-Host "[RUN] Starting Odin Server..." -ForegroundColor Green
    
    # Kill existing server if running
    Get-Process vampire_survival -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 1
    
    $args = @()
    if ($Headless) { $args += "--headless" }
    $args += "--transport", $Transport
    $args += "--sync", $Sync
    
    Push-Location $OdinRoot
    & .\game\vampire_survival.exe $args
    Pop-Location
}

function Run-ZigClient {
    if ($WithServer) {
        Write-Host "[RUN] Starting Server background process..." -ForegroundColor Cyan
        
        # Kill existing server if running
        Get-Process vampire_survival -ErrorAction SilentlyContinue | Stop-Process -Force
        Start-Sleep -Seconds 1

        $ServerPath = "$OdinRoot\game\vampire_survival.exe"
        $ServerArgs = "--headless --transport ipc"
        Start-Process -FilePath $ServerPath -ArgumentList $ServerArgs -NoNewWindow:$false
        Start-Sleep -Seconds 1
    }

    Write-Host "[RUN] Starting Zig Client..." -ForegroundColor Green
    
    $DllPath = "$ProjectRoot\thirdparties\raylib-5.5_win64_msvc16\lib\raylib.dll"
    $DestPath = "$ZigRoot\zig-out\bin\raylib.dll"
    if (Test-Path $DllPath) {
        Copy-Item -Force $DllPath $DestPath
    }

    Push-Location $ZigRoot
    & .\zig-out\bin\ZigClient.exe
    Pop-Location
}

function Run-Tests {
    Write-Host "[TEST] Running Project Tests..." -ForegroundColor Yellow
    Push-Location $OdinRoot
    & $OdinExe test game
    Pop-Location
}

function Clean-Project {
    Write-Host "[CLEAN] Cleaning artifacts..." -ForegroundColor Red
    if (Test-Path "$OdinRoot\game\vampire_survival.exe") { Remove-Item "$OdinRoot\game\vampire_survival.exe" }
    if (Test-Path "$ZigRoot\.zig-cache") { Remove-Item -Recurse -Force "$ZigRoot\.zig-cache" }
    if (Test-Path "$ZigRoot\zig-out") { Remove-Item -Recurse -Force "$ZigRoot\zig-out" }
}

function Show-Help {
    Write-Host "Odin Project Management Script" -ForegroundColor White
    Write-Host "Actions:"
    Write-Host "  build-server  - Compile the Odin game server"
    Write-Host "  build-client  - Compile the Zig Raylib client"
    Write-Host "  build-all     - Build everything"
    Write-Host "  run-server    - Run the Odin server (use -Headless switch)"
    Write-Host "  run-client    - Run the Zig client"
    Write-Host "  test          - Run Odin shared memory test"
    Write-Host "  clean         - Remove build artifacts"
}

switch ($Action) {
    "build-server" { Build-OdinServer }
    "build-client" { Build-ZigClient }
    "build-all"    { Build-OdinServer; Build-ZigClient }
    "run-server"   { Run-OdinServer }
    "run-client"   { Run-ZigClient }
    "test"         { Run-Tests }
    "clean"        { Clean-Project }
    "help"         { Show-Help }
}
