<#
    .SYNOPSIS
        Create extension and create Go Current package.
    .NOTES
        Requires:
        Node.js (npm)
        npm install -g vsce
        Go Current server
#>

param(
    [string] $GitCommit = $env:Build_SourceVersion,
    [string] $BuildNumber = $env:Build_BuildNumber,
    [string] $Vsce = $env:bamboo_capability_system_builder_command_vsce,
    [string] $Npm = $env:bamboo_capability_system_builder_command_npm,
    [string] $Branch = $env:Build_SourceBranchName,
    [string] $ReleaseBranch = 'master'
)

Write-Host "vsce: $Vsce"
Write-Host "npm: $Npm"

$ErrorActionPreference = 'stop'

$env:Path += ';' + (Join-Path $env:USERPROFILE 'AppData\Roaming\npm')
Write-Host $env:Path

function Install-NpmIfNecessary
{
    param(
        $ToolName
    )
    $Command = Get-Command -Name $ToolName -ErrorAction SilentlyContinue
    if (!$Command)
    {
        Write-Host "Installing: $ToolName"
        npm install $ToolName -g
        return
    }
    Write-Host "$ToolName already installed."
}
Install-NpmIfNecessary -ToolName 'vsce'

function ConvertTo-PackageBranchName
{
    param(
        $GitBranchName
    )
    return $GitBranchName.Replace('origin/', '').Replace('/', '-').Replace('_', '-').ToLower()
}

Remove-Item (Join-Path $PSScriptRoot '*.vsix')

If(!(test-path (Join-Path $PSScriptRoot '/PackageOutput')))
{
    Remove-Item (Join-Path $PSScriptRoot '*.zip')   
}
else
{
    Remove-Item (Join-Path $PSScriptRoot '/PackageOutput') -Recurse -Force -Confirm:$false
}

$PackageBackupPath = Join-Path $PSScriptRoot 'package.json.original'
$PackagePath = (Join-Path $PSScriptRoot 'package.json')

$PackageContent = (Get-Content -Path $PackagePath -Raw)
$PackageJson = ConvertFrom-Json -InputObject $PackageContent
$Version = $PackageJson.Version.Replace('-developer', '')

if ($GitCommit -and $BuildNumber)
{
    Copy-Item $PackagePath $PackageBackupPath
    $GitCommit = $GitCommit.Substring(0, 8)

    Set-Content -Path (Join-Path $PSScriptRoot 'commit') -Value $GitCommit
    if ($Branch -eq $ReleaseBranch)
    {
        $Version = "$Version"
    }
    else
    {
        $BranchName = ConvertTo-PackageBranchName -GitBranchName $Branch
        $Version = "$Version-dev.$BranchName.$BuildNumber+$GitCommit"
    }

    $NewPackageContent = $PackageContent.Replace([string]$PackageJson.version, [string]$Version)
    Set-Content -Value $NewPackageContent -Path (Join-Path $PSScriptRoot 'package.json')
}
Push-Location
Set-Location $PSScriptRoot
if (!$Vsce -or !(Test-Path $Vsce))
{
    Write-Host "Set global vsce"
    $Vsce = 'vsce'
}
if (!$Npm -or !(Test-Path $Npm))
{
    Write-Host "Set global npm"
    $Npm = 'npm'
}

$ErrorActionPreference = 'continue'

& $Npm install | Write-Host

if ($LASTEXITCODE -ne 0)
{
    throw "npm exited with $LASTEXITCODE."
}


& $Vsce package | Write-Host

if ($LASTEXITCODE -ne 0)
{
    throw "vsce exited with $LASTEXITCODE."
}

$ErrorActionPreference = 'stop'

Pop-Location

if (Test-Path $PackageBackupPath)
{
    Move-Item $PackageBackupPath $PackagePath -Force
}

$OutputDir = Join-Path $PSScriptRoot 'PackageOutput'

Import-Module GoCurrentServer
$Package = @{
    'Id' = 'ls-update-service-workspace'
    'Name' = "Update Service Workspace"
    'Version' = $Version
    'IncludePaths' = @(
        (Get-Item (Join-Path $PSScriptRoot "*.vsix")),
        (Join-Path $PSScriptRoot 'package\*')
    )
    'OutputDir' = $OutputDir
    'Commands' = @{
        'Install' = 'Package.psm1:Install-Package'
        'Update' = 'Package.psm1:Install-Package'
        'Remove' = 'Package.psm1:Remove-Package'
    }
}

New-GocsPackage @Package -Force
$DeploymentFile = Join-Path $PSScriptRoot '.azure\deployment.ps1'
Copy-Item $DeploymentFile -Destination $OutputDir