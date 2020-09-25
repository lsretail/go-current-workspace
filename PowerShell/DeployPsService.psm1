$ErrorActionPreference = 'stop'

Import-Module (Join-Path $PSScriptRoot 'ProjectFile.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'ErrorHandling.psm1')

Add-Type -AssemblyName 'System.ServiceModel'
try
{
    $env:PSModulePath = [System.Environment]::GetEnvironmentVariable("PSModulePath", "machine")
    Import-Module GoCurrent
    $_GoCurrentInstalled = $true
}
catch
{
    $_GoCurrentInstalled = $false
}

$_GoCWizardPath = $null

function Get-GoCurrentVersion()
{
    $HasRequiredVersion = $false
    $CurrentVersion = ''
    $RequiredVersion = [Version]::Parse('0.15.11')
    if ($_GoCurrentInstalled)
    {
        $CurrentVersion = ((Get-Module -Name 'GoCurrent') | Select-Object -First 1).Version

        $HasRequiredVersion = $CurrentVersion -ge $RequiredVersion
        $CurrentVersion = $CurrentVersion.ToString()
    }
    $RequiredVersion = $RequiredVersion.ToString()

    return ConvertTo-Json -Compress -InputObject @{
        RequiredVersion = $RequiredVersion
        CurrentVersion = $CurrentVersion
        HasRequiredVersion = $HasRequiredVersion
        IsInstalled = $_GoCurrentInstalled
    }
}

function Invoke-AsAdminOld()
{
    param(
        [string] $Command,
        [string] $Arguments,
        [string] $ExceptionText
    )
    $OutputPath = [System.IO.Path]::GetTempFileName()
    $Command = "`$ErrorActionPreference='stop';trap{Write-Host `$_ -ForegroundColor Red;Write-Host `$_.ScriptStackTrace -ForegroundColor Red;pause;};Import-Module (Join-Path '$PSScriptRoot' 'DeployPsService.psm1');$Command -OutputPath '$OutputPath' $Arguments;"
    $Process = Start-Process powershell $Command -Verb runas -PassThru

    $Process.WaitForExit()
    if ($Process.ExitCode -ne 0)
    {
        Write-JsonError $ExceptionText -Type 'User'
    }
    $Data = Get-Content $OutputPath -Raw
    Remove-Item $OutputPath
    return $Data
}

function Install-AsAdmin()
{
    param(
        $ProjectFilePath,
        $PackageGroupId,
        $InstanceName,
        $ArgumentsFilePath,
        $OutputPath
    )
    if ([string]::IsNullOrEmpty($ArgumentsFilePath))
    {
        $ArgumentsFilePath = $null
    }
    $PackageGroup = GetPackageGroup -ProjectFilePath $ProjectFilePath -PackageGroupId $PackageGroupId
    $Result = @($PackageGroup.Packages | Install-GocPackage -InstanceName $InstanceName -Arguments $ArgumentsFilePath)

    Set-Content -Value (ConvertTo-Json $Result -Depth 100 -Compress) -Path $OutputPath
}

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

    $PackageGroup = GetPackageGroup -ProjectFilePath $ProjectFilePath -PackageGroupId $PackageGroupId -BranchName $BranchName -Target $Target

    $Packages = $PackageGroup.Packages

    return Install-Packages -InstanceName $InstanceName -Packages $Packages -Arguments $PackageGroup.Arguments -Servers $Servers
}

function Install-PackagesJson
{
    param(
        $InstanceName,
        $Packages,
        $Servers,
        $Arguments
    )

    $Packages = ConvertFrom-Json $Packages

    return Install-Packages -Servers $Servers -InstanceName $InstanceName -Packages $Packages
}

function Install-Packages
{
    param(
        $InstanceName,
        [Array] $Packages,
        $Arguments,
        [string] $Servers
    )

    $ServersObj = ConvertTo-ServersObj -Servers $Servers

    $ToUpdate = @($Packages | Get-GocUpdates -InstanceName $InstanceName -Server $ServersObj)

    $WizardPath = Get-GoCurrentWizardPath

    $Install = @{
        Name = ""
        Description = ""
        PackageGroups = @(
            @{
                Name = ""
                Description = ""
                Packages = $Packages
                Arguments = $Arguments
            }
        )
    }

    if ($ServersObj)
    {
        $Install.Servers = $ServersObj
    }

    $TempFilePath = (Join-Path $env:TEMP "GoCWorkspace\$([System.IO.Path]::GetRandomFileName())")
    [System.IO.Directory]::CreateDirectory((Split-Path $TempFilePath -Parent)) | Out-Null
    (ConvertTo-Json -InputObject $Install -Depth 100 -Compress) | Set-Content -Path $TempFilePath

    $ArgumentList = @('-InstallerMetadata', $TempFilePath, '-SelectFirst')
    if ($InstanceName)
    {
        $ArgumentList += '-InstanceName', $InstanceName, '-UpdateInstance'
    }

    $Process = Start-Process -FilePath $WizardPath -ArgumentList $ArgumentList -PassThru
    $Process.WaitForExit()

    Remove-Item $TempFilePath -Force -ErrorAction SilentlyContinue

    if ($Process.ExitCode -ne 0)
    {
        throw "Error occurred while installing packages."
    }

    $Installed = $ToUpdate | ForEach-Object {
        $InstalledPackage = $_ | Get-GocInstalledPackage
        if (!$InstalledPackage -or $InstalledPackage.Version -ne $_.Version)
        {
            return $null
        }
        return $InstalledPackage
    }
    $Installed = @($Installed | Where-Object { $_ -ne $null })
    return (ConvertTo-Json $Installed -Depth 100 -Compress)
}

function ConvertTo-ServersObj
{
    param(
        $Servers
    )
    if ($Servers)
    {
        $ServersObj = @()
        ConvertFrom-Json $Servers | Foreach-Object { 
            $_ | Foreach-Object { 
                $Item = @{}; 
                $ServersObj += $Item
                $_.PSObject.Properties | Foreach-Object { $Item[$_.Name] = $_.Value} 
            }
        }
        return @(,$ServersObj)
    }
    return @()
}

function Test-PackageAvailable
{
    param(
        $PackageId,
        $Servers
    )

    $ServersObj = ConvertTo-ServersObj -Servers $Servers

    try
    {
        Get-GocPackage -Id $PackageId -VersionQuery "" -Server $ServersObj | Out-Null
    }
    catch
    {
        if ($_.Exception -is [LSRetail.GoCurrent.Common.Exceptions.NoPackageInRangeException])
        {
            return (ConvertTo-Json $false -Compress)
        }
        throw
    }
    return (ConvertTo-Json $true -Compress)
}

function Get-AvailableUpdates()
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
        $PackageGroup = GetPackageGroup -ProjectFilePath $ProjectFilePath -PackageGroupId $PackageGroupId -Target $Target -BranchName $BranchName -NoThrow
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

    $Updates = @($Packages | Get-GocUpdates -InstanceName $InstanceName -Server $ServersObj)
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
    $PackageGroup = GetPackageGroup -ProjectFilePath $ProjectFilePath -PackageGroupId $PackageGroupId -Target $Target -BranchName $BranchName -NoThrow
    if (!$PackageGroup)
    {
        return (ConvertTo-Json $false -Compress)
    }
    $Result = $PackageGroup.packages | Test-GocIsInstance
    return (ConvertTo-Json $Result -Compress -Depth 100)
}

function GetPackageGroup
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

function ReplaceVariables
{
    param(
        $PackageGroup,
        $Variables
    )
    foreach ($Package in $PackageGroup.Packages)
    {
        foreach ($Pair in $Variables.PSObject.Properties)
        {
            $Package.Version = $Package.Version.Replace("`${$($Pair.Name)}", $Pair.Value)
        }
    }
}

function Test-InstanceExists($InstanceName)
{
    return ConvertTo-Json (Test-GocInstanceExists -Instancename $InstanceName) -Depth 100 -Compress
}

function Test-CanInstall
{
    param(
        $ProjectFilePath, 
        $PackageGroupId,
        $Target,
        $BranchName
    )
    $PackageGroup = GetPackageGroup -ProjectFilePath $ProjectFilePath -PackageGroupId $PackageGroupId -Target $Target -BranchName $BranchName
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

function Test-IsInstalled
{
    param(
        $Packages,
        $InstanceName
    )

    if ($InstanceName)
    {
        return ConvertTo-Json (Test-GocInstanceExists -InstanceName $InstanceName) -Compress
    }

    foreach ($Package in $Packages)
    {
        $Installed = $Package | Get-GocInstalledPackage -InstanceName $InstanceName
        if ($Installed)
        {
            return ConvertTo-Json $true -Compress
        }
    }
    return ConvertTo-Json $false -Compress
}

function Get-Arguments
{
    param(
        $ProjectFilePath, 
        $PackageGroupId,
        $Target,
        $BranchName
    )
    $PackageGroup = GetPackageGroup -ProjectFilePath $ProjectFilePath -PackageGroupId $PackageGroupId -Target $Target -BranchName $BranchName
    $Arguments = $PackageGroup.packages | Get-GocArguments
    return ConvertTo-Json $Arguments -Compress -Depth 100
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

function Remove-AsAdmin()
{
    param(
        $OutputPath,
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
    $NotInstances | Remove-GocPackage

    Set-Content -Value (ConvertTo-Json $Deployment.name -Depth 100 -Compress) -Path $OutputPath
}

function Remove-Deployment()
{
    param(
        $WorkspaceDataPath,
        $DeploymentGuid
    )
    $Command = 'Remove-AsAdmin'
    $Arguments = "'$WorkspaceDataPath' '$DeploymentGuid'"
    $ExceptionText = "Exception occured while uninstalling packages."
    Invoke-AsAdminOld -Command $Command -Arguments $Arguments -ExceptionText $ExceptionText
}

function Get-AvailableBaseUpdates()
{
    $Packages = @(
        'go-current-client',
        'go-current-workspace'
    )
    $Updates = @($Packages | Get-GocUpdates)
    return (ConvertTo-Json $Updates -Compress -Depth 100)
}

function Install-BasePackages()
{
    $Packages = @(
        @{ Id = 'go-current-client'; Version = "" },
        @{ Id = 'go-current-workspace'; Version = "" }
    )
    return Install-Packages -Packages $Packages
}

function Install-BaseAsAdmin($OutputPath)
{
    $Packages = @(
        'go-current-client',
        'go-current-workspace'
    )
    $Result = @($Packages | Install-GocPackage)
    Set-Content -Value (ConvertTo-Json $Result -Depth 100 -Compress) -Path $OutputPath
}

function GetDeployedPackages()
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

function Get-DeployedPackages()
{
    param(
        $WorkspaceDataPath,
        $DeploymentGuid
    )
    return (ConvertTo-Json @(GetDeployedPackages -WorkspaceDataPath $WorkspaceDataPath -DeploymentGuid $DeploymentGuid) -Depth 100 -Compress)
}

function Invoke-OpenGoCurrentWizard
{
    $WizardPath = Get-GoCurrentWizardPath

    & $WizardPath
}

function Get-Instances
{
    return ConvertTo-Json  @(Get-GocInstalledPackage | Where-Object { $_.InstanceName } | Group-Object -Property 'InstanceName' | Sort-Object -Property 'Name' | ForEach-Object { @(,$_.Group)}) -Depth 100 -Compress
}

function Get-GoCurrentWizardPath
{
    if ($null -ne $_GoCWizardPath)
    {
        return $_GoCWizardPath
    }
    $GoCModule = Get-Module GoCurrent | Select-Object -First 1

    $Dir = Split-Path $GoCModule.Path -Parent

    $_GoCWizardPath = Join-Path $Dir 'LSRetail.GoCurrent.Client.Wizard.exe'
    return $_GoCWizardPath
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