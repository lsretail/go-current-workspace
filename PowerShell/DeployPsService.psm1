$ErrorActionPreference = 'stop'

Import-Module (Join-Path $PSScriptRoot 'Lib\ProjectFile.psm1')
Import-Module (Join-Path $PSScriptRoot 'ErrorHandling.psm1')
Import-Module (Join-Path $PSScriptRoot 'AdminUtils.psm1')
Import-Module (Join-Path $PSScriptRoot 'GoCurrentPsService.psm1')
Import-Module (Join-Path $PSScriptRoot 'Utils.psm1')

Add-Type -AssemblyName 'System.ServiceModel'

function Install-PackageGroup
{
    param(
        $ProjectFilePath,
        $PackageGroupId,
        $InstanceName,
        $BranchName,
        $Target,
        [string] $Servers
    )

    if (!$PackageGroupId)
    {
        if ($InstanceName -and (Test-GocInstanceExists -InstanceName $InstanceName))
        {
            $Packages = Get-GocInstalledPackage -InstanceName $InstanceName | Where-Object { $_.Selected }

            return Install-Packages -InstanceName $InstanceName -Packages $Packages -Servers $Servers
        }
        return @()
    }

    $PackageGroup = Get-PackageGroup -ProjectFilePath $ProjectFilePath -PackageGroupId $PackageGroupId -BranchName $BranchName -Target $Target

    $UpdateInstanceMode = 'Replace'

    if ($PackageGroup.updateInstanceMode)
    {
        $UpdateInstanceMode = $PackageGroup.updateInstanceMode
    }

    $Packages = $PackageGroup.Packages | Where-Object { !$_.onlyRestrictVersion}

    Assert-ValidVersionQuery -Packages $Packages

    return Install-Packages -InstanceName $InstanceName -Packages $Packages -Arguments $PackageGroup.Arguments -Servers $Servers -UpdateInstanceMode $UpdateInstanceMode -Title $PackageGroup.name
}

function Get-AvailableUpdates
{
    param(
        $ProjectFilePath,
        $PackageGroupId,
        $InstanceName,
        $Target,
        $BranchName,
        [string] $Servers
    )

    $ServersObj = ConvertTo-ServersObj -Servers $Servers

    if ($PackageGroupId)
    {
        $PackageGroup = Get-PackageGroup -ProjectFilePath $ProjectFilePath -PackageGroupId $PackageGroupId -Target $Target -BranchName $BranchName -NoThrow
    }

    if (!$PackageGroup)
    {
        if ($InstanceName -and (Test-GocInstanceExists -InstanceName $InstanceName))
        {
            $Updates = @(Get-GocInstalledPackage -InstanceName $InstanceName | Where-Object { $_.Selected } | Get-GocUpdates -Server $ServersObj)
            return (ConvertTo-Json $Updates -Compress -Depth 100)
        }

        return (ConvertTo-Json @() -Compress)
    }

    # We only want to check optional packages for updates if they where installed, here we filter them out:
    $SelectedPackages = $PackageGroup.packages | Get-GocInstalledPackage -InstanceName $InstanceName | ForEach-Object { $_.Id }
    $Packages = $PackageGroup.packages | Where-Object { (!$_.optional) -or ($_.optional -and $SelectedPackages.Contains($_.id)) }

    $UpdateInstanceMode = 'Replace'

    if ($PackageGroup.updateInstanceMode)
    {
        $UpdateInstanceMode = $PackageGroup.updateInstanceMode
    }

    Assert-ValidVersionQuery -Packages $Packages -Name $PackageGroup.name

    $Updates = @($Packages | Get-GocUpdates -InstanceName $InstanceName -Server $ServersObj -UpdateInstanceMode $UpdateInstanceMode)
    return (ConvertTo-Json $Updates -Compress -Depth 100)
}

function Test-IsInstance
{
    param(
        $ProjectFilePath,
        $PackageGroupId,
        $Target,
        $BranchName
    )
    $PackageGroup = Get-PackageGroup -ProjectFilePath $ProjectFilePath -PackageGroupId $PackageGroupId -Target $Target -BranchName $BranchName -NoThrow
    if (!$PackageGroup)
    {
        return (ConvertTo-Json $false -Compress)
    }
    $Result = $PackageGroup.packages | Test-GocIsInstance
    return (ConvertTo-Json $Result -Compress -Depth 100)
}

function Get-PackageGroup
{
    param(
        [Parameter(Mandatory = $true)]
        $ProjectFilePath,
        [Parameter(Mandatory = $true)]
        $PackageGroupId,
        $Target,
        $BranchName,
        [switch] $NoThrow
    )
    $Group = Get-ProjectFilePackages -Id $PackageGroupId -Path $ProjectFilePath -Target $Target -BranchName $BranchName
    if (!$Group -and !$NoThrow)
    {
        Write-JsonError "Package group `"$PackageGroupId`" does not exists in project file." -Type 'User'
    }
    return $Group
}

function Test-CanInstall
{
    param(
        $ProjectFilePath, 
        $PackageGroupId,
        $Target,
        $BranchName
    )
    $PackageGroup = Get-PackageGroup -ProjectFilePath $ProjectFilePath -PackageGroupId $PackageGroupId -Target $Target -BranchName $BranchName
    foreach ($Package in $PackageGroup.packages)
    {
        $First = Get-GocInstalledPackage -Id $Package.id | Select-Object -First 1
        if (!$First)
        {
            return ConvertTo-Json $true -Compress
        }
        elseif (![string]::IsNullOrEmpty($First.InstanceName))
        {
            return ConvertTo-Json $true -Compress
        } 
    }    
}

function Get-InstalledPackages($Id, $InstanceName)
{
    return ConvertTo-Json @(Get-GocInstalledPackage -Id $Id -InstanceName $InstanceName) -Compress -Depth 100
}

function GetDeployment()
{
    param(
        $WorkspaceDataPath,
        $DeploymentGuid
    )

    $WorkspaceData = Get-Content -Path $WorkspaceDataPath | ConvertFrom-Json
    foreach ($Set in $WorkspaceData.deployments)
    {
        if ($Set.guid -eq $DeploymentGuid)
        {
            return $Set
        }
    }
    Write-JsonError "Deployment `"$DeploymentGuid`" does not exists workspace data file." -Type 'User'
}

function Remove-Deployment
{
    param(
        $WorkspaceDataPath,
        $DeploymentGuid
    )

    $Deployment = GetDeployment -WorkspaceDataPath $WorkspaceDataPath -DeploymentGuid $DeploymentGuid

    if ((![string]::IsNullOrEmpty($Deployment.instanceName)) -and (Test-GocInstanceExists -InstanceName $Deployment.instanceName))
    {
        Remove-GocPackage -InstanceName $Deployment.instanceName
    }

    if ($Deployment.packages.Count -eq 0)
    {
        return
    }

    $NotInstances = $Deployment.packages | Where-Object { !(Test-GocIsInstance -Id $_.id)}
    $NotInstances = $NotInstances | Where-Object { $null -ne (Get-GocInstalledPackage -Id $_.id ) }
    if ($NotInstances)
    {
        $NotInstances | Remove-GocPackage
    }

    return (ConvertTo-Json $Deployment.name -Depth 100 -Compress)
}

function Remove-DeploymentAdmin
{
    param(
        [Parameter(Mandatory)]
        $WorkspaceDataPath,
        [Parameter(Mandatory)]
        $DeploymentGuid
    )
    $Block = {
        param(
            [Parameter(Mandatory)]
            $ScriptDir,
            [Parameter(Mandatory)]
            $WorkspaceDataPath,
            [Parameter(Mandatory)]
            $DeploymentGuid
        )
        Import-Module (Join-Path $ScriptDir 'DeployPsService.psm1')
        Remove-Deployment -WorkspaceDataPath $WorkspaceDataPath -DeploymentGuid $DeploymentGuid
    }

    $Arguments = @{
        WorkspaceDataPath = $WorkspaceDataPath
        DeploymentGuid = $DeploymentGuid
        ScriptDir = $PSScriptRoot
    }
    
    return Invoke-AsAdmin -ScriptBlock $Block -Arguments $Arguments
}

function GetDeployedPackages
{
    param(
        $WorkspaceDataPath,
        $DeploymentGuid
    )
    $Deployment = GetDeployment -WorkspaceDataPath $WorkspaceDataPath -DeploymentGuid $DeploymentGuid

    if ((![string]::IsNullOrEmpty($Deployment.instanceName)) -and (Test-GocInstanceExists -InstanceName $Deployment.instanceName))
    {
        Get-GocInstalledPackage -InstanceName $Deployment.instanceName
    }

    if ($Deployment.packages.Count -eq 0)
    {
        return
    }

    $NotInstances = $Deployment.packages | Where-Object { !(Test-GocIsInstance -Id $_.id)}
    $NotInstances | Where-Object { $null -ne (Get-GocInstalledPackage -Id $_.id ) }
}

function Get-DeployedPackages
{
    param(
        $WorkspaceDataPath,
        $DeploymentGuid
    )
    return (ConvertTo-Json @(GetDeployedPackages -WorkspaceDataPath $WorkspaceDataPath -DeploymentGuid $DeploymentGuid) -Depth 100 -Compress)
}

function Get-Targets
{
    param(
        [Parameter(Mandatory)]
        $ProjectFilePath,
        $Id,
        $UseDevTarget = $false
    )
    return ConvertTo-Json -Depth 100 -Compress -InputObject @(Get-ProjectFileTargets -Path $ProjectFilePath -Id $Id -UseDevTarget:$UseDevTarget)
}

function Get-ResolvedProjectFile
{
    param(
        $ProjectFilePath,
        $Target,
        $BranchName
    )
    $ProjectFile = Get-ProjectFile -Path $ProjectFilePath -Target $Target -BranchName $BranchName
    $ProjectFile.Variables = Get-ProjectFileVariables -Path $ProjectFilePath -Target $Target -BranchName $BranchName
    return (ConvertTo-Json $ProjectFile -Compress -Depth 100)
}

function Get-ResolvedPackageGroup
{
    param(
        [Parameter(Mandatory = $true)]
        $ProjectFilePath,
        [Parameter(Mandatory = $true)]
        $PackageGroupId,
        $Target,
        $BranchName
    )
    return ConvertTo-Json (Get-PackageGroup -ProjectFilePath $ProjectFilePath -PackageGroupId $PackageGroupId -Target $Target -BranchName $BranchName) -Compress -Depth 100
}