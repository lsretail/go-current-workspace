$ErrorActionPreference = 'stop'

Import-Module GoCurrent
Import-Module (Join-Path $PSScriptRoot 'ProjectFile.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '_Utils.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '_ExportAppJsonFromApp.psm1') -Force

function Get-AlDependencies
{
    param(
        [Parameter(Mandatory)]
        $Dependencies,
        [Parameter(Mandatory)]
        $OutputDir,
        [switch] $Force
    )
    $Verbose = [bool]$PSBoundParameters["Verbose"]
    Get-AlDependenciesInternal -Dependencies $Dependencies -OutputDir $OutputDir -Force:$Force -SkipPackages ([System.Collections.ArrayList]::new()) -Verbose:$Verbose
}

function Get-AlDependenciesInternal
{
    param(
        [Parameter(Mandatory)]
        $Dependencies,
        [Parameter(Mandatory)]
        $OutputDir,
        [System.Collections.ArrayList] $SkipPackages,
        [switch] $Force
    )

    $Verbose = [bool]$PSBoundParameters["Verbose"]
    
    $PackageIds = $Dependencies | ForEach-Object { Get-Value -Values @($_.Id, $_.PackageId) }
    
    $Deps = ConvertTo-HashtableList $Dependencies

    $AllResolved = $Deps | Get-GocUpdates

    $Resolved = @($AllResolved | Where-Object { $PackageIds.Contains($_.Id)})

    $TempDir = [System.IO.Path]::Combine($env:TEMP, "AlTools", [System.IO.Path]::GetRandomFileName())
    [System.IO.Directory]::CreateDirectory($TempDir) | Out-Null
    [System.IO.Directory]::CreateDirectory($OutputDir) | Out-Null

    $PropagateDependencies = @()

    try
    {
        foreach ($Package in $Resolved)
        {
            if ($SkipPackages.Contains($Package.Id))
            {
                continue
            }
            $AppPath = Get-AppFromPackage -Package $Package -OutputDir $TempDir -Verbose:$Verbose
            if (!$AppPath)
            {
                continue
            }

            $SkipPackages.Add($Package.Id) | Out-Null
            $FileName = [IO.Path]::GetFileName($AppPath)
            try
            {
                $AppJson = Get-AppJsonFromApp -Path $AppPath
                $FileName = "$($AppJson.Publisher)_$($AppJson.Name)_$($AppJson.Version).app"
                if ($AppJson.propagateDependencies)
                {
                    $Manifest = Get-JsonFileFromPackage -Id $Package.Id -VersionQuery $Package.Version -FilePath 'Manifest.json'
                    foreach ($Dependency in $Manifest.Dependencies)
                    {
                        $PropagateDependencies += $Dependency
                    }
                }
            }
            catch
            {
                # We end up here if the app is a runtime app, because we can't extract the app.json from it.
                if ($FileName -notmatch '\d+\.\d+\.\d+\.\d+')
                {
                    # We want to include the version number.
                    $Version = (ConvertTo-GocSemanticVersion $Package.Version).ToString($true, $true)
                    $FileName = [IO.Path]::GetFileNameWithoutExtension($FileName)
                    $FileName = "$($FileName)_$($Version).app"
                }
                
            }
            Move-Item $AppPath -Destination (Join-Path $OutputDir $FileName) -Force:$Force
        }
    }
    finally
    {
        try
        {
            Remove-Item $TempDir -Force -Recurse    
        }
        catch
        {
            # Ignore
        }
    }
    if ($PropagateDependencies)
    {
        Get-AlDependenciesInternal -Dependencies $PropagateDependencies -OutputDir $OutputDir -Force:$Force -Verbose:$Verbose -SkipPackages $SkipPackages
    }
}

function Get-AlAddinDependencies
{
    param(
        [Parameter(Mandatory = $true)]
        $Dependencies,
        [Parameter(Mandatory = $true)]
        $OutputDir,
        [switch] $IncludeServer,
        [switch] $Force
    )
    $PackageIds = $Dependencies | ForEach-Object { $_.Id}
    
    $Deps = ConvertTo-HashtableList $Dependencies

    $Resolved = @($Deps | Get-GocUpdates | Where-Object { $PackageIds.Contains($_.Id) -or ($IncludeServer -and $_.Id -eq 'bc-server')})

    $TempDir = Join-Path $OutputDir 'Temp'
    $GatherDir = Join-Path $TempDir '.gather'

    foreach ($Package in $Resolved)
    {
        $IsBcServer = $Package.Id -eq 'bc-server'

        if (!$IsBcServer)
        {
            $FoundAddin = $false
            foreach ($File in $Package | Get-GocFile)
            {
                if ($File.FilePath.ToLower().StartsWith('addin\'))
                {
                    $FoundAddin = $true
                    break;
                }
            }

            if (!$FoundAddin)
            {
                continue
            }
        }

        Write-Verbose "  -> $($Package.Id) v$($Package.version)..."
        $Package | Get-GocFile -Download -OutputDir $TempDir

        $Dir = [System.IO.Path]::Combine($GatherDir, $Package.Id)
        [System.IO.Directory]::CreateDirectory($Dir) | Out-Null

        if ($IsBcServer)
        {
            Move-Item -Path ([System.IO.Path]::Combine($TempDir, $Package.Id, 'Service', '*')) -Destination $Dir | Out-Null    
        }
        else
        {
            Move-Item -Path ([System.IO.Path]::Combine($TempDir, $Package.Id, 'Addin', '*')) -Destination $Dir | Out-Null    
        }
        
        Get-ChildItem -Path $Dir -Filter '*.txt' -Recurse | Remove-Item
        Get-ChildItem -Path $Dir -Filter '*.xml' -Recurse | Remove-Item
    }
    if (Test-Path $GatherDir)
    {
        Move-Item -Path (Join-Path $GatherDir '*') -Destination $OutputDir | Out-Null
    }

    if (Test-Path $TempDir)
    {
        Remove-Item $TempDir -Force -Recurse
    }
}

function Get-AlDevDependencies
{
    param(
        [Parameter(Mandatory)]
        $Dependencies,
        [Parameter(Mandatory)]
        $ProjectDir,
        $TempDir
    )

    $PackageIds = $Dependencies | ForEach-Object { $_.Id}
    
    $Deps = ConvertTo-HashtableList $Dependencies

    $Resolved = @($Deps | Get-GocUpdates | Where-Object { $PackageIds.Contains($_.Id)})

    if (!$TempDir)
    {
        $TempDir = Join-Path $env:TEMP 'AlTools'
    }
    
    [System.IO.Directory]::CreateDirectory($TempDir) | Out-Null

    $ScriptFileName = 'ProjectDeploy.ps1'

    foreach ($Package in $Resolved)
    {
        $Files = $Package | Get-GocFile | Where-Object { $_.FilePath -ieq $ScriptFileName }

        if (!$Files)
        {
            continue
        }

        Write-Verbose "  -> $($Package.Id) v$($Package.version)..."
        $Package | Get-GocFile -Download -OutputDir $TempDir

        $PackageDir = [System.IO.Path]::Combine($TempDir, $Package.Id)

        & (Join-Path $PackageDir $ScriptFileName) -Context @{ProjectDir = $ProjectDir}
    }

    Remove-Item $TempDir -Force -Recurse
}

function Invoke-AlCompiler
{
    param(
        [Parameter(Mandatory = $true)]
        [string] $ProjectDir,
        [Parameter(Mandatory = $true)]
        [string] $CompilerPath,
        [Parameter(Mandatory = $true)]
        $OutputDir,
        $AlPackagesDir = $null,
        [Array]$AssemblyDir = $null
    )

    $AppJsonPath = Join-Path $ProjectDir 'app.json'
    $AppJson = Get-Content -Path $AppJsonPath -Raw | ConvertFrom-Json

    $FileName = "$($AppJson.publisher)_$($AppJson.name)_$($AppJson.version).app"
    [System.IO.Directory]::CreateDirectory($OutputDir) | Out-Null

    $FileOutputPath = Join-Path $OutputDir $FileName

    if (!$AlPackagesDir)
    {
        $AlPackagesDir = Join-Path $ProjectDir '.alpackages'
    }

    $Arguments = @("/project:`"$ProjectDir`"", "/packagecachepath:`"$AlPackagesDir`"", "/out:`"$FileOutputPath`"")

    if ($AssemblyDir)
    {
        $Joined = [string]::Join(',', $AssemblyDir)
        $Arguments += "/assemblyprobingpaths:`"$Joined`""
    }

    Write-Verbose "`"$CompilerPath`" $([string]::Join(' ', $Arguments))"

    $Output = & $CompilerPath @Arguments | Out-String

    if ($LASTEXITCODE -ne 0)
    {
        if ($Output)
        {
            Write-Warning $Output
        }
   
        throw "AL Compiler exited with exit code $LASTEXITCODE."
    }
    elseif ($Output)
    {
        Write-Verbose $Output
    }
    $FileOutputPath
}

function Get-AlCompiler
{
    param(
        $InstanceName = 'AlCompiler'
    )

    $PackageId = 'bc-al-compiler'

    $Updates = Get-GocUpdates -Id $PackageId -InstanceName $InstanceName

    if ($Updates)
    {
        Install-GocPackage -Id $PackageId -InstanceName $InstanceName -UpdateInstance | Out-Null
    }

    $InstalledPackage = Get-GocInstalledPackage -InstanceName $InstanceName -Id $PackageId
    return $InstalledPackage.Info.CompilerPath
}

function Remove-IfExists
{
    param([string]$Path)
    if ($Path.EndsWith('*'))
    {
        $Path = Split-Path $Path -Parent
    }
    if (Test-Path $Path)
    {
        Remove-Item $Path -Recurse -Force
    }
}

function New-AlPackage
{
    param(
        [Parameter(Mandatory = $true)]
        $AlProjectFilePath,
        [Parameter(Mandatory = $true)]
        $GocProjectFilePath,
        [Parameter(Mandatory = $false)]
        $AppPath,
        $OutputDir,
        $DefaultOutputDir,
        [string] $Target,
        [string] $BranchName,
        [hashtable] $Variables,
        [switch] $Force
    )
    Import-Module LsPackageTools\AppPackageCreator -Verbose:$false

    $DefaultOutputDir = Split-Path $AlProjectFilePath -Parent
    
    $AlProject = Get-Content -Path $AlProjectFilePath -Raw | ConvertFrom-Json
    $DepdenciesGroup = Get-ProjectFilePackages -Id 'dependencies' -Path $GocProjectFilePath -Target $Target -BranchName $BranchName -Variables $Variables

    $GoCProject = Get-ProjectFile -Path $GocProjectFilePath -Target $Target -BranchName $BranchName -Variables $Variables

    $Files = $GoCProject.InputPath

    if ($AppPath)
    {
        $Files = @($Files | Where-Object { !$_.EndsWith('.app') })
        $Files += $AppPath
    }

    $Dependencies = @()
    foreach ($Dep in $DepdenciesGroup.Packages)
    {
        $NewEntry = @{}
        $Dep.PSObject.properties | ForEach-Object { $NewEntry[$_.Name] = $_.Value }

        $Dependencies += $NewEntry
    }

    $Package = @{
        Id = $GoCProject.Id
        Name = Get-FirstValue $GoCProject.Name, $AlProject.Name
        Description = Get-FirstValue $GoCProject.Description, $AlProject.Description
        Version = Get-FirstValue $GoCProject.Version, $AlProject.Version
        Path = $Files
        OutputDir = Get-FirstValue $OutputDir, $GoCProject.OutputDir, $DefaultOutputDir
        Dependencies = $Dependencies
        SubstituteFor = $GoCProject.SubstituteFor
    }

    if ($GoCProject.DisplayName)
    {
        $Package.DisplayName = $GoCProject.DisplayName
    }

    New-AppPackage @Package -Force:$Force
}

function Get-AlProjectDependencies
{
    param(
        [Parameter(Mandatory)]
        $ProjectDir,
        $BranchName,
        $Target,
        [hashtable] $Variables,
        $PackageCacheDir,
        $AssemblyProbingDir,
        [Array] $CompileModifiers,
        [string[]] $SkipPackageId = @()
    )

    $Verbose = [bool]$PSBoundParameters["Verbose"]

    $ProjectFilePath = Get-GocProjectFilePath -ProjectDir $ProjectDir

    $DependenciesGroup = Get-ProjectFilePackages -Path $ProjectFilePath -Id 'dependencies' -Target $Target -BranchName $BranchName -Variables $Variables
    $DevDependencies = Get-ProjectFilePackages -Path $ProjectFilePath -Id 'devDependencies' -Target $Target -BranchName $BranchName -Variables $Variables

    if (!$PackageCacheDir)
    {
        $PackageCacheDir = (Join-Path $ProjectDir '.alpackages')
    }
    else
    {
        $PackageCacheDir = [System.IO.Path]::Combine($ProjectDir, $PackageCacheDir)
    }

    if (!$AssemblyProbingDir)
    {
        $AssemblyProbingDir = (Join-Path $ProjectDir '.netpackages')
    }
    else
    {
        $AssemblyProbingDir = [System.IO.Path]::Combine($ProjectDir, $AssemblyProbingDir)
    }

    $Dependencies = $DependenciesGroup.Packages
    
    Remove-IfExists -Path $AssemblyProbingDir -Recurse -Force
    Remove-IfExists -Path (Join-Path $PackageCacheDir '*') -Recurse -Force

    Write-Verbose "Dependencies for package:"
    $Dependencies | Format-Table -AutoSize | Out-String | Write-Verbose

    $ModifiedDependencies = $Dependencies    

    if ($DevDependencies -and $DevDependencies.Packages)
    {
        Write-Verbose "Dev dependencies for package:"
        $DevDependencies.Packages | Format-Table -AutoSize | Out-String | Write-Verbose
        $ModifiedDependencies = Get-AlModifiedDependencies -Dependencies $ModifiedDependencies -CompileModifiers $DevDependencies.Packages
    }

    if ($CompileModifiers)
    {
        # We might want to compile with more restricted queries
        $ModifiedDependencies = Get-AlModifiedDependencies -Dependencies $ModifiedDependencies -CompileModifiers $CompileModifiers

        Write-Verbose "Compile Modifiers:"
        $CompileModifiers | Format-Table -AutoSize | Out-String | Write-Verbose
    }

    $ModifiedDependencies = $ModifiedDependencies | Where-Object { !$SkipPackageId.Contains($_.Id) }

    $ModifiedDependencies | Format-Table -AutoSize | Out-String | Write-Verbose

    if (!$ModifiedDependencies)
    {
        return
    }

    Write-Verbose 'Downloading dependencies for app...'
    Get-AlDependencies -Dependencies $ModifiedDependencies -OutputDir $PackageCacheDir -Verbose:$Verbose
    
    Write-Verbose 'Downloading assemblies for app...'
    Get-AlAddinDependencies -Dependencies $ModifiedDependencies -OutputDir $AssemblyProbingDir -IncludeServer -Verbose:$Verbose

    Write-Verbose 'Downloading dev dependencies for app...'
    Get-AlDevDependencies -Dependencies $ModifiedDependencies -ProjectDir $ProjectDir -Verbose:$Verbose
}

function Invoke-AlProjectCompile
{
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        $ProjectDir,
        $CompilerPath,
        $OutputDir = $ProjectDir
    )

    if (!$CompilerPath)
    {
        $CompilerPath = Get-AlCompiler
    }

    $AddinDir = @("C:\WINDOWS\Microsoft.NET\assembly")
    $NetPackagesDir = (Join-Path $ProjectDir '.netpackages')
    if (Test-Path $NetPackagesDir)
    {
        $AddinDir += $NetPackagesDir
    }
    Write-Verbose 'Compiling app...'

    $Arguments = @{
        ProjectDir = $ProjectDir
        CompilerPath = $CompilerPath
        OutputDir = $OutputDir
        AssemblyDir = $AddinDir
    }

    return Invoke-AlCompiler @Arguments
}

function Invoke-ProjectBuild
{
    param(
        [Parameter(Mandatory)]
        [string] $AppId,
        [Parameter(Mandatory)]
        [hashtable] $Projects,
        [string] $CompilerPath,
        [switch] $Force
    )
    $verbose = [bool]$PSBoundParameters["Verbose"]
    Write-Verbose "Building: `"$($Projects[$AppId].ProjectDir)`" `"$AppId`"."

    $Project = $Projects[$AppId]

    $DependencyPackageId = @()
    $DependencyApps = @()

    # Make sure that dependencies are compiled first.
    foreach ($Dependency in $Projects[$AppId].AppJson.dependencies)
    {
        if (!$Projects.ContainsKey($Dependency.id))
        {
            continue
        }
        if (!$Projects[$Dependency.id].AppPath)
        {
            Write-Verbose "Need to compile dependency `"$($Dependency.id)`" first."
            Invoke-ProjectBuild -AppId $Dependency.id -Projects $Projects -CompilerPath $CompilerPath -Verbose:$Verbose -Force:$Force
            Write-Verbose "Continuing with `"$AppId`"."
        }

        if (!$Projects[$Dependency.id].AppPath)
        {
            throw "Something went wrong, no app found for $($Dependency.id)."
        }

        $DependencyApps += $Projects[$Dependency.id].AppPath
        $DependencyPackageId += $Projects[$Dependency.id].Package.Id
    }

    $Arguments = @{
        BranchName = $Project.BranchName 
        Target = $Project.Target
        Variables = $Project.Variables 
    }

    $AllCompileModifiers = Get-ProjectFileCompileModifiers -Path (Get-GocProjectFilePath -ProjectDir $Projects[$AppId].ProjectDir) @Arguments

    if (!$AllCompileModifiers)
    {
        $AllCompileModifiers = ,@(@())
    }

    # Arguments for Get-AlProjectDependencies.
    $Arguments += @{
        ProjectDir = $Project.ProjectDir
    }
    
    foreach ($CompileModifiers in $AllCompileModifiers)
    {
        Get-AlProjectDependencies @Arguments -CompileModifiers $CompileModifiers -SkipPackageId $DependencyPackageId -Verbose:$verbose

        if ($DependencyApps)
        {
            $DestDir = (Join-Path $Projects[$AppId].ProjectDir '.alpackages')
            [IO.Directory]::CreateDirectory($DestDir) | Out-Null
            Copy-Item -Path $DependencyApps -Destination $DestDir
        }

        $Projects[$AppId].AppPath = Invoke-AlProjectCompile -ProjectDir $Projects[$AppId].ProjectDir -Verbose:$verbose
    }

    $Arguments += @{
        AppPath = $Project.AppPath
        OutputDir = $Project.OutputDir
        Force = $Force
    }

    $Projects[$AppId].Package = New-AlProjectPackage @Arguments -Verbose:$verbose 
    $Projects[$AppId].Package
}

function Invoke-AlProjectBuild
{
    <#
        .SYNOPSIS
            Build specified al project
        
        .PARAMETER ProjectDir
            Specify the project directory (or repository directory).
        
        .PARAMETER BranchName
            Specify the Git branch name for you repository (if appropriate).

        .PARAMETER Target
            Specify a target to compile against. Can be used to resolve
            different dependencies for release, release candidate and development.
        
        .PARAMETER Variables
            Specify a hashtable of variables to make available for project file.
            The values specified here, will overwrite any variables specified
            in the project file.

        .PARAMETER OutputDir
            Specifies the output directory for the package and artifacts.
        
        .PARAMETER CompilerPath
            Specifies a path to the AL compiler (alc.exe). If not specified, 
            it will install the bc-al-compiler package and use to compile.
        
        .PARAMETER Force
            If specified, it will overwrite any existing files.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('Dir')]
        [Alias('Path')]
        [string[]] $ProjectDir,
        [Parameter(ValueFromPipelineByPropertyName)]
        $BranchName,
        [Parameter(ValueFromPipelineByPropertyName)]
        $Target,
        [Parameter(ValueFromPipelineByPropertyName)]
        [hashtable] $Variables,
        [Parameter(ValueFromPipelineByPropertyName)]
        [string] $OutputDir,
        $CompilerPath,
        [switch] $Force
    )
    begin
    {
        $Projects = @{}
    }
    process
    {
        foreach ($Dir in $ProjectDir)
        {
            $AppJson = Get-AlAppJson -ProjectDir $dir
            $Projects[$AppJson.id] = @{
                ProjectDir = $Dir
                OutputDir = $Dir
                AppJson = $AppJson
                Variables = $Variables
                BranchName = $BranchName
                Target = $Target
                AppPath = $null
                Package  = $null
            }
            if ($OutputDir)
            {
                $Projects[$AppJson.id].OutputDir = $OutputDir
            }
        }
    }
    end
    {
        $verbose = [bool]$PSBoundParameters["Verbose"]
        foreach ($AppId in $Projects.Keys)
        {
            if (!$Projects.AppPath)
            {
                Invoke-ProjectBuild -AppId $AppId -Projects $Projects -CompilerPath $CompilerPath -Force:$Force -Verbose:$Verbose
            }
        }
    }
}

function New-AlProjectPackage
{
    param(
        [Parameter(Mandatory)]
        $ProjectDir,
        [Parameter(Mandatory = $false)]
        $AppPath,
        $OutputDir,
        [string] $Target,
        [string] $BranchName,
        [hashtable] $Variables,
        [switch] $Force
    )

    $ProjectFilePath = Get-GocProjectFilePath -ProjectDir $ProjectDir

    $Arguments = @{
        AlProjectFilePath = (Join-Path $ProjectDir 'app.json') 
        GocProjectFilePath = $ProjectFilePath 
        AppPath = $AppPath
        OutputDir = $OutputDir 
        Force = $Force
        Target = $Target
        BranchName = $BranchName
        Variables = $Variables
    }

    New-AlPackage @Arguments
}

function Undo-AlVersion
{
    param(
        [Parameter(Mandatory = $true)]
        $ProjectDir
    )

    $ProjectFilePath = (Join-Path $ProjectDir 'app.json')
    $OrigProjectFilePath = (Join-Path $ProjectDir 'app.json.original')

    if (Test-Path $OrigProjectFilePath)
    {
        Move-Item $OrigProjectFilePath $ProjectFilePath -Force
    }
}

function Get-AlModifiedDependencies
{
    param(
        [Array] $Dependencies,
        [Array] $CompileModifiers
    )

    $Used = @()

    foreach ($Dependency in $Dependencies)
    {
        $Modifier = $CompileModifiers | Where-Object { $_.Id -eq $Dependency.Id }

        if ($Modifier)
        {
            $Used += $Modifier
            $Query1 = [LSRetail.GoCurrent.Common.SemanticVersioning.VersionQuery]::Parse($Dependency.version)
            $Query2 = [LSRetail.GoCurrent.Common.SemanticVersioning.VersionQuery]::Parse($Modifier.version)
            $NewQuery = [LSRetail.GoCurrent.Common.SemanticVersioning.VersionQuery]::Intersection(@($Query1, $Query2))
            if (!$NewQuery)
            {
                throw "Got two queries for package `"$($Dependency.Id)`", that do not intersect."
            }
            $Dependency.version = $NewQuery.ToString()
        }
        $Dependency
    }

    foreach ($Item in $CompileModifiers)
    {
        if (!$Used.Contains($Item))
        {
            $Item
        }
    }
}

function Get-GocProjectFilePath
{
    param(
        [Parameter(Mandatory)]
        $ProjectDir
    )
    $PossibleProjectPath = @((Join-Path $ProjectDir '.gocurrent\gocurrent.json'), (Join-Path $ProjectDir 'gocurrent.json'))
    $ProjectFilePath = $PossibleProjectPath | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (!$ProjectFilePath)
    {
        throw "Could not find project file 'gocurrent.json' in project directory."
    }
    return $ProjectFilePath
}

function Get-FirstValue
{
    param(
        [Array] $Values,
        $DefaultValue = $null
    )
    foreach ($Value in $Values)
    {
        if ($Value)
        {
            return $Value
        }
    }
    return $DefaultValue
}

function ConvertTo-HashtableList
{
    param(
        [Array]$Object
    )

    foreach ($Item in $Object)
    {
        if ($Item -is [hashtable])
        {
            $Item
            continue    
        }
        $Hashtable = @{}
        $Item.psobject.Properties | ForEach-Object { $Hashtable[$_.Name] = $_.Value }
        $Hashtable
    }
}

Export-ModuleMember -Function '*-Al*'