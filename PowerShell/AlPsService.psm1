$ErrorActionPreference = 'stop'

Import-Module GoCurrent
Import-Module (Join-Path $PSScriptRoot 'AdminUtils.psm1')
Import-Module (Join-Path $PSScriptRoot 'ErrorHandling.psm1')

function Invoke-UpgradeDataAdmin
{
    param(
        [Parameter(Mandatory = $true)]
        $InstanceName
    )

    $Block = {
        param(
            [Parameter(Mandatory)]
            $ScriptDir,
            [Parameter(Mandatory)]
            $InstanceName
        )
        Import-Module (Join-Path $ScriptDir 'AlPsService.psm1')
        Invoke-UpgradeData -InstanceName $InstanceName
    }
    $Arguments = @{
        ScriptDir = $PSScriptRoot
        InstanceName = $InstanceName
    }
    return Invoke-AsAdmin -ScriptBlock $Block -Arguments $Arguments
}

function Invoke-UpgradeData
{
    param(
        [Parameter(Mandatory = $true)]
        $InstanceName
    )

    $Server = Get-GocInstalledPackage -Id 'bc-server' -InstanceName $InstanceName

    if (!$Server)
    {
        return (ConvertTo-Json @() -Compress)
    }

    Import-Module (Get-BcModulePath -InstanceName $InstanceName -Type Apps) -Global

    $Apps = Get-NAVAppInfo -ServerInstance $Server.Info.ServerInstance -TenantSpecificProperties -Tenant default
    $Apps = $Apps | Where-Object { $_.ExtensionDataVersion -ne $_.Version}

    $AppsUpgraded = @()

    foreach ($App in $Apps)
    {
        $AppsUpgraded += "$($App.Name) by $($App.Publisher) ($($App.AppId))"
        if ($App.SyncState -ne [Microsoft.Dynamics.Nav.Types.Apps.NavAppSyncState]::Synced)
        {
            $App | Sync-NAVApp -Mode Development -Force
        }
        
        $App | Start-NAVAppDataUpgrade
    }
    return (ConvertTo-Json $AppsUpgraded -Compress)
}

function Invoke-UnpublishAppAdmin
{
    param(
        [Parameter(Mandatory)]
        $AppId,
        [Parameter(Mandatory)]
        $InstanceName
    )
    $Block = {
        param(
            [Parameter(Mandatory)]
            $ScriptDir,
            [Parameter(Mandatory)]
            $AppId,
            [Parameter(Mandatory)]
            $InstanceName
        )
        Import-Module (Join-Path $ScriptDir 'AlPsService.psm1')
        Invoke-UnpublishApp -AppId $AppId -InstanceName $InstanceName
    }
    $Arguments = @{
        ScriptDir = $PSScriptRoot
        AppId = $AppId
        InstanceName = $InstanceName
    }
    return Invoke-AsAdmin -ScriptBlock $Block -Arguments $Arguments
}

function Invoke-UnpublishApp
{
    param(
        [Parameter(Mandatory)]
        $AppId,
        [Parameter(Mandatory)]
        $InstanceName
    )

    $Server = Get-GocInstalledPackage -Id 'bc-server' -InstanceName $InstanceName

    if (!$Server)
    {
        Write-JsonError -Message "Instance doesn't exists `"$InstanceName`"." -Type 'User'
    }

    Import-Module (Get-BcModulePath -InstanceName $InstanceName -Type Apps) -Global

    $ServerInstance = $Server.Info.ServerInstance

    $App = Get-NavAppInfo -ServerInstance $ServerInstance -Id $AppId
    if ($App)
    {
        $App | Uninstall-NavApp -ServerInstance $ServerInstance -Tenant default -Force
        $App | Unpublish-NavApp -ServerInstance $ServerInstance
        return ConvertTo-Json $true -Compress
    }
    else
    {
        return ConvertTo-Json $false -Compress
    }
}

function Invoke-ImportLicenseAdmin
{
    param(
        [Parameter(Mandatory)]
        $InstanceName,
        [Parameter(Mandatory)]
        $FileName        
    )

    $Block = {
        param(
            [Parameter(Mandatory)]
            $ScriptDir,
            [Parameter(Mandatory)]
            $FileName,
            [Parameter(Mandatory)]
            $InstanceName
        )
        Import-Module (Join-Path $ScriptDir 'AlPsService.psm1')
        Invoke-ImportLicense -InstanceName $InstanceName -FileName $FileName 

    }

    $Arguments = @{
        ScriptDir = $PSScriptRoot
        FileName = $FileName
        InstanceName = $InstanceName
    }
    return Invoke-AsAdmin -ScriptBlock $Block -Arguments $Arguments
}


function Invoke-ImportLicense
{
    param(
        [Parameter(Mandatory)]
        $InstanceName,
        [Parameter(Mandatory)]
        $FileName
    )

    $Server = Get-GocInstalledPackage -Id 'bc-server' -InstanceName $InstanceName

    if (!$Server)
    {
        Write-JsonError -Message "Instance doesn't exists `"$InstanceName`"." -Type 'User'
    }

    Import-Module (Get-BcModulePath -InstanceName $InstanceName -Type Management) -Global

    $ServerInstance = $Server.Info.ServerInstance

    $Uri = New-Object System.UriBuilder($FileName)

    $File = ($Uri.Uri.Localpath).Substring(1)
    
    Import-NAVServerLicense -LicenseFile $File -Database NavDatabase -ServerInstance $ServerInstance
}

function Publish-AppAdmin
{
    param(
        [Parameter(Mandatory)]
        $AppPath,
        [Parameter(Mandatory)]
        $InstanceName
    )
    $Block = {
        param(
            [Parameter(Mandatory)]
            $ScriptDir,
            [Parameter(Mandatory)]
            $AppPath,
            [Parameter(Mandatory)]
            $InstanceName
        )
        Import-Module (Join-Path $ScriptDir 'AlPsService.psm1')
        Publish-App -AppPath $AppPath -InstanceName $InstanceName
    }
    $Arguments = @{
        ScriptDir = $PSScriptRoot
        AppPath = $AppPath
        InstanceName = $InstanceName
    }
    return Invoke-AsAdmin -ScriptBlock $Block -Arguments $Arguments
}

function Publish-App
{
    param(
        [Parameter(Mandatory)]
        $AppPath,
        [Parameter(Mandatory)]
        $InstanceName
    )

    $Server = Get-GocInstalledPackage -Id 'bc-server' -InstanceName $InstanceName

    if (!$Server)
    {
        Write-JsonError -Message "Instance doesn't exists `"$InstanceName`"." -Type 'User'
    }

    Import-Module (Get-BcModulePath -InstanceName $InstanceName -Type Apps) -Global

    $SyncMode = 'Development'
    $AllowForceSync = $true

    $ServerInstance = $Server.Info.ServerInstance

    $AppFileInfo = Get-NAVAppInfo -Path $AppPath

    $ExistingApp = $AppFileInfo | Get-NavAppInfo -ServerInstance $ServerInstance -TenantSpecificProperties -Tenant default | Select-Object -First 1


    $AllExisting = Get-NavAppInfo -ServerInstance $ServerInstance -TenantSpecificProperties -Tenant default -Id $AppFileInfo.AppId
    $AllExisting | Uninstall-NAVApp -ServerInstance $ServerInstance -Tenant default -Force

    $App = Publish-NAVApp -ServerInstance $ServerInstance -Path $AppPath -SkipVerification -PassThru
    $App | Sync-NAVApp -ServerInstance $ServerInstance -Mode $SyncMode -Force

    try 
    {
        $App | Sync-NAVApp -ServerInstance $ServerInstance -Mode $SyncMode -Force
    }
    catch 
    {
        if (!$AllowForceSync)
        {
            throw
        }
        $App | Sync-NAVApp -ServerInstance $ServerInstance -Mode ForceSync -Force
    }

    if (!$ExistingApp)
    {
        $App | Install-NAVApp -ServerInstance $ServerInstance -Tenant default
    }
    else 
    {
        $App | Start-NAVAppDataUpgrade -ServerInstance $ServerInstance    
    }
}

function Get-BcModuleDir
{
    param(
        [Parameter(Mandatory, ParameterSetName='ServerDir')]
        $ServerDir,
        [Parameter(Mandatory, ParameterSetName='InstanceName')]
        $InstanceName
    )

    if ($InstanceName)
    {
        $BcServer = Get-UscInstalledPackage -Id 'bc-server' -InstanceName $InstanceName

        if (!$BcServer)
        {
            throw "Specified instance ($InstanceName) does not exists or is not a Business Central instance."
        }

        $ServerDir = $BcServer.Info.ServerDir
    }

    if (Test-Path (Join-Path $ServerDir 'Management\Microsoft.Dynamics.Nav.Management.dll'))
    {
        return Join-Path $ServerDir 'Management'
    }
    return $ServerDir
}

function Get-BcModulePath
{
    param(
        [Parameter(Mandatory, ParameterSetName='ServerDir')]
        [string] $ServerDir,
        [Parameter(Mandatory, ParameterSetName='InstanceName')]
        [string] $InstanceName,
        [ValidateSet('Apps', 'Management')]
        [string] $Type
    )

    if ($InstanceName)
    {
        $BcServer = Get-UscInstalledPackage -Id 'bc-server' -InstanceName $InstanceName

        if (!$BcServer)
        {
            throw "Specified instance ($InstanceName) does not exists or is not a Business Central instance."
        }

        $ServerDir = $BcServer.Info.ServerDir
    }

    if ($Type -eq 'Apps')
    {
        $Paths = @(
            (Join-Path $ServerDir 'Microsoft.Dynamics.Nav.Apps.Management.dll')
            (Join-Path $ServerDir 'Management\Microsoft.Dynamics.Nav.Apps.Management.dll')
            (Join-Path $ServerDir 'Management\Microsoft.Dynamics.Nav.Management.dll')
        )
        return Get-FirstExisting $Paths
    }
    elseif ($Type -eq 'Management')
    {
        $Paths = @(
            (Join-Path $ServerDir 'Microsoft.Dynamics.Nav.Management.dll')
            (Join-Path $ServerDir 'Management\Microsoft.Dynamics.Nav.Management.dll')
        )
        return Get-FirstExisting $Paths
    }
    throw 'Invalid type specified.'
}

function Get-FirstExisting
{
    param(
        [string[]]$Path
    )

    foreach ($Path in $Paths)
    {
        if (Test-Path $Path)
        {
            return $Path
        }
    }
    throw 'None of the specified paths exists.'
}