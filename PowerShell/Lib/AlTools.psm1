$ErrorActionPreference = 'stop'

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
    $Server,
    [switch] $Force
    )
    $Verbose = [bool]$PSBoundParameters["Verbose"]
    Get-DependenciesInternal -Dependencies $Dependencies -OutputDir $OutputDir -Force:$Force -SkipPackages ([System.Collections.ArrayList]::new()) -Verbose:$Verbose -Server $Server
}

function Get-DependenciesInternal
{
    param(
    [Parameter(Mandatory)]
    $Dependencies,
    [Parameter(Mandatory)]
    $OutputDir,
    [System.Collections.ArrayList] $SkipPackages,
    $Server,
    [switch] $Force
    )

    $Verbose = [bool]$PSBoundParameters["Verbose"]

    $PackageIds = $Dependencies | ForEach-Object { Get-Value -Values @($_.Id, $_.PackageId) }

    $Deps = ConvertTo-HashtableList $Dependencies

    $AllResolved = $Deps | Get-GocUpdates

    $Resolved = @($AllResolved | Where-Object { $PackageIds.Contains($_.Id)})

    $TempDir = [System.IO.Path]::Combine(([System.IO.Path]::GetTempPath()), "AlTools", [System.IO.Path]::GetRandomFileName())
    [System.IO.Directory]::CreateDirectory($TempDir) | Out-Null
    [System.IO.Directory]::CreateDirectory($OutputDir) | Out-Null

    $PropagateDependencies = @()
    $SubstituteFor = @{}

    try
    {
        foreach ($Package in $Resolved)
        {
            if ($SkipPackages.Contains($Package.Id))
            {
                continue
            }
            $AppPath = Get-AppFromPackage -Package $Package -OutputDir $TempDir -Verbose:$Verbose -Server $Server
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

            # Check for backwards compatibility, if property *SubstituteFor* is not included, we need to fetch the file.
            if (![bool]($Package.PSobject.Properties.name -match "SubstituteFor"))
            {
                # We end up here if backwards compatibility is needed, if *SubstituteFor* is not included, we need to fetch the file.
                $Manifest = Get-JsonFileFromPackage -Id $Package.Id -VersionQuery $Package.Version -FilePath 'Manifest.json'
                if ($Manifest.SubstituteFor)
                {
                    $SubstituteFor[$Manifest.SubstituteFor] = $Manifest.Id
                }
            }
            elseif ($Package.SubstituteFor)
            {
                $SubstituteFor[$Package.SubstituteFor] = $Package.Id
            }

            if ($AppJson -and $AppJson.propagateDependencies)
            {
                $PackageDetails = Get-GocPackage -Id $Package.Id -Version $Package.Version -IncludeDependencies
                foreach ($Dependency in $PackageDetails.Dependencies)
                {
                    $PropagateDependencies += $Dependency
                }
            }
            $DestinationPath = (Join-Path $OutputDir $FileName)
            if ($Force -and (Test-Path $DestinationPath))
            {
                Remove-Item -Path $DestinationPath -Force
            }
            Move-Item $AppPath -Destination $DestinationPath -Force:$Force
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
        # We must use substitute packages, if any.
        foreach ($Dep in $PropagateDependencies)
        {
            if ($SubstituteFor.ContainsKey($Dep.Id))
            {
                $Dep.Id = $SubstituteFor[$Dep.Id]
            }
        }
        Get-DependenciesInternal -Dependencies $PropagateDependencies -OutputDir $OutputDir -Force:$Force -Verbose:$Verbose -SkipPackages $SkipPackages -Server $Server
    }
}

function Get-AlAddinDependencies
{
    param(
    [Parameter(Mandatory = $true)]
    $Dependencies,
    [Parameter(Mandatory = $true)]
    $OutputDir,
    $Server,
    [switch] $IncludeServer,
    [switch] $Force
    )
    $PackageIds = $Dependencies | ForEach-Object { $_.Id}

    $Deps = ConvertTo-HashtableList $Dependencies

    $Resolved = @($Deps | Get-GocUpdates -Server $Server | Where-Object { $PackageIds.Contains($_.Id) -or ($IncludeServer -and $_.Id -eq 'bc-server')})

    $TempDir = [System.IO.Path]::Combine(([System.IO.Path]::GetTempPath()), "AlTools", [System.IO.Path]::GetRandomFileName())

    if (Test-Path $TempDir)
    {
        Remove-Item $TempDir -Recurse -Force
    }

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
        $Package | Get-GocFile -Download -OutputDir $TempDir -Server $Server

        $Dir = [System.IO.Path]::Combine($OutputDir, $Package.Id)

        if (Test-Path $Dir)
        {
            if ($Force)
            {
                Remove-Item $Dir -Recurse -Force
            }
            else
            {
                Write-Error "`"$Dir`" already exists."
                return
            }
        }

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
    $Server,
    $TempDir
    )

    $PackageIds = $Dependencies | ForEach-Object { $_.Id}

    $Deps = ConvertTo-HashtableList $Dependencies

    $Resolved = @($Deps | Get-GocUpdates -Server $Server | Where-Object { $PackageIds.Contains($_.Id)})

    if (!$TempDir)
    {
        $TempDir = Join-Path ([System.IO.Path]::GetTempPath()) 'AlTools'
    }

    [System.IO.Directory]::CreateDirectory($TempDir) | Out-Null

    $ScriptFileName = 'ProjectDeploy.ps1'

    foreach ($Package in $Resolved)
    {
        $Files = $Package | Get-GocFile -Server $Server | Where-Object { $_.FilePath -ieq $ScriptFileName }

        if (!$Files)
        {
            continue
        }

        Write-Verbose "  -> $($Package.Id) v$($Package.version)..."
        $Package | Get-GocFile -Download -OutputDir $TempDir -Server $Server

        $PackageDir = [System.IO.Path]::Combine($TempDir, $Package.Id)

        & (Join-Path $PackageDir $ScriptFileName) -Context @{ProjectDir = $ProjectDir}
    }

    Remove-Item $TempDir -Force -Recurse
}

function Invoke-AlCompiler
{
    param(
    [Parameter(Mandatory)]
    [string] $ProjectDir,
    [Parameter(Mandatory)]
    [string] $CompilerPath,
    [Parameter(Mandatory)]
    $OutputDir,
    $AlPackagesDir = $null,
    [Array] $AssemblyDir = $null,
    [switch] $RunALCops
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
        $AssemblyDir = @($AssemblyDir | Where-Object { Test-Path $_})
        $Joined = [string]::Join(',', $AssemblyDir)
        $Arguments += "/assemblyprobingpaths:`"$Joined`""
    }

    if ($RunALCops)
    {
        if(!(Test-Path (join-path $ProjectDir '.vscode\settings.json')))
        {
            Write-Warning "Settings.json missing for $ProjectDir. It is required for using codecop. Refer to microsoft documentation on how to structure: https://learn.microsoft.com/en-us/dynamics365/business-central/dev-itpro/developer/devenv-using-code-analysis-tool"
        }
        else
        {
            $Rules = (get-content (join-path $ProjectDir '.vscode\settings.json')) | ConvertFrom-Json
            $RulesetFile = join-path $ProjectDir $Rules.'al.ruleSetPath'
            if(!(test-path $RulesetFile) -or $null -eq $Rules.'al.ruleSetPath')
            {
                Write-Warning "Ruleset file specified by al.ruleSetPath not found. Refer to documentation here: https://learn.microsoft.com/en-us/dynamics365/business-central/dev-itpro/developer/devenv-using-code-analysis-tool"
            }
            else
            {
                if($Rules.'al.codeAnalyzers'.Contains('${AppSourceCop}'))
                {
                    $Arguments += @("/analyzer:$(Join-Path (Get-Item $CompilerPath).Directory.Parent.FullName 'Analyzers\Microsoft.Dynamics.Nav.AppSourceCop.dll')")
                }
                if($Rules.'al.codeAnalyzers'.Contains('${UICop}'))
                {
                    $Arguments += @("/analyzer:$(Join-Path (Get-Item $CompilerPath).Directory.Parent.FullName 'Analyzers\Microsoft.Dynamics.Nav.UICop.dll')")
                }
                if($Rules.'al.codeAnalyzers'.Contains('${CodeCop}'))
                {
                    $Arguments += @("/analyzer:$(Join-Path (Get-Item $CompilerPath).Directory.Parent.FullName 'Analyzers\Microsoft.Dynamics.Nav.CodeCop.dll')")
                }
                $Arguments += @("/ruleset:$RulesetFile")
            }
        }
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
    $InstanceName = 'AlCompiler',
    $Server
    )

    $PackageId = 'bc-al-compiler'

    $Updates = Get-GocUpdates -Id $PackageId -InstanceName $InstanceName -Server $Server

    if ($Updates)
    {
        Install-GocPackage -Id $PackageId -InstanceName $InstanceName -UpdateInstance -Server $Server | Out-Null
    }

    $InstalledPackage = Get-GocInstalledPackage -InstanceName $InstanceName -Id $PackageId

    if(test-path (join-path $InstalledPackage.InstanceDirectory 'Compiler\win32\alc.exe'))
    {
        $CompilerPath = (join-path $InstalledPackage.InstanceDirectory 'Compiler\win32\alc.exe')
    }
    else
    {
        $CompilerPath = (join-path $InstalledPackage.InstanceDirectory 'Compiler\alc.exe')
    }
    Write-Verbose "Compiler path: $CompilerPath"
    if(!(Test-Path $CompilerPath))
    {
        throw "Compiler not found at $CompilerPath"
    }
    return $CompilerPath
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
        [Array] $CompileOverride,
        [string[]] $SkipPackageId = @(),
        $Server,
        [switch] $ClearDirs,
        [switch] $Force,
        [switch] $RunALCops
    )

    $Verbose = [bool]$PSBoundParameters["Verbose"]

    $ProjectFilePath = Get-GocProjectFilePath -ProjectDir $ProjectDir

    $DependenciesGroup = Get-ProjectFilePackages -Path $ProjectFilePath -Id 'dependencies' -Target $Target -BranchName $BranchName -Variables $Variables
    $DevDependencies = Get-ProjectFilePackages -Path $ProjectFilePath -Id 'devDependencies' -Target $Target -BranchName $BranchName -Variables $Variables
    $ProjectFile = Get-ProjectFile -Path $ProjectFilePath -Target $Target -BranchName $BranchName -Variables $Variables
    $IncludeServer = $true
    if ($null -ne $ProjectFile.alIncludeServerAssemblies)
    {
        $IncludeServer = $ProjectFile.alIncludeServerAssemblies
    }

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

    if ($ClearDirs)
    {
        Remove-IfExists -Path (Join-Path $PackageCacheDir '*') -Recurse -Force
    }

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

    foreach ($Override in $CompileOverride)
    {
        $Dependency = $ModifiedDependencies | Where-Object { $_.Id -eq $Override.Id }
        if ($Dependency)
        {
            $Dependency.Version = $Override.Version
        }
    }

    $ModifiedDependencies = $ModifiedDependencies | Where-Object { !$SkipPackageId.Contains($_.Id) }

    $ModifiedDependencies | Format-Table -AutoSize | Out-String | Write-Verbose

    if (!$ModifiedDependencies)
    {
        return
    }

    if($RunALCops)
    {
        $AppSourceJsonPath = Join-Path $ProjectDir 'AppSourceCop.json'

        # Get comparison app defined in gocurrent.json with alAppSourceCopVersionQuery
        $ComparisonAppVersion = (Get-GocPackage -Id $ProjectFile.Id -VersionQuery $ProjectFile.alAppSourceCopVersionQuery).Version
        $FilePath = (Get-GocFile -Id $ProjectFile.Id -Version $ComparisonAppVersion | Where-Object {$_.FilePath -like '*.app'}).FilePath
        Write-Verbose "Downloading comparison app file for version $ComparisonAppVersion"
        Get-GocFile -Id $ProjectFile.Id -Version $ComparisonAppVersion -Download -OutputPath (join-path $PackageCacheDir $FilePath) -FilePath $FilePath
        $AppSourceJsonContent = get-content $AppSourceJsonPath | convertfrom-json
        if(($null -eq $AppSourceJsonContent.version) -or $AppSourceJsonContent.version -eq "")
        {
            Write-Debug "No version found in $AppSourceJsonPath"
        }
        else
        {
            # The exact version of the app, in particular the build numer, needs to be injected into appsourcecop.json
            # If the version can not be found, we remove the version line requirement from appsourcecop.json
            $AppVersion = $null
            try # Try to extract correct version from the app file's app.json
            {
                $AppVersion = (Get-AppJsonFromApp (join-path $PackageCacheDir $FilePath)).Version
            }
            catch {
                Write-Warning "Unable to get version information from app file. Error message below:"
                Write-Warning $_
            }
            if(!$AppVersion) # Try to fetch version from the app file name
            {
                try
                {
                    $Regex = '(\d+).(\d+).(\d+).(\d+)'
                    $FilePath -match $Regex | Out-Null
                    $AppVersion = $Matches[0]
                }
                catch
                {
                    Write-Warning "Unable to get version information from app file name: $FilePath"
                }
            }

            if($AppVersion) # If a version has been found, we inject into appsourcecop.json
            {
                $AppSourceJsonContent.version = $AppVersion
            }
            else # Otherwise we remove version requirement from app.json
            {
                $AppSourceJsonContent.version = ""
            }
            $AppSourceJsonContent | ConvertTo-Json | Out-File $AppSourceJsonPath
        }
    }

    Write-Verbose 'Downloading dependencies for app...'
    Get-AlDependencies -Dependencies $ModifiedDependencies -OutputDir $PackageCacheDir -Verbose:$Verbose -Force:$Force -Server $Server

    Write-Verbose 'Downloading assemblies for app...'
    Get-AlAddinDependencies -Dependencies $ModifiedDependencies -OutputDir $AssemblyProbingDir -IncludeServer:$IncludeServer -Verbose:$Verbose -Force:$Force -Server $Server

    Write-Verbose 'Downloading dev dependencies for app...'
    Get-AlDevDependencies -Dependencies $ModifiedDependencies -ProjectDir $ProjectDir -Verbose:$Verbose -Server $Server
}

function Invoke-AlProjectCompile
{
    [CmdletBinding()]
    param (
    [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)]
    [Alias('Dir')]
    [Alias('Path')]
    [string[]] $ProjectDir,
    [Parameter(ValueFromPipelineByPropertyName)]
    [string] $OutputDir,
    $CompilerPath,
    $Server,
    [switch] $Force,
    [switch] $UseDependencyTempDir
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
        if ($UseDependencyTempDir)
        {
            $TempDirBase = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
        }
        $verbose = [bool]$PSBoundParameters["Verbose"]
        foreach ($AppId in $Projects.Keys)
        {
            if (!$Projects.AppPath)
            {
                Invoke-ProjectBuild -AppId $AppId -Projects $Projects -CompilerPath $CompilerPath -Force:$Force -Verbose:$Verbose -TempDirBase $TempDirBase -Server $Server -OnlyCompile
            }
        }
        if ($UseDependencyTempDir -and (Test-Path $TempDirBase))
        {
            Remove-Item $TempDirBase -Force -Recurse
        }
    }
}

function Invoke-ProjectBuild
{
    param(
    [Parameter(Mandatory)]
    [string] $AppId,
    [Parameter(Mandatory)]
    [hashtable] $Projects,
    [string] $CompilerPath,
    $Server,
    [switch] $Force,
    $TempDirBase,
    [switch] $OnlyCompile,
    [string] $SignToolPath,
    [array] $SignToolArgumentList,
    [switch] $RunALCops    )
    $verbose = [bool]$PSBoundParameters["Verbose"]
    Write-Verbose "Building: `"$($Projects[$AppId].ProjectDir)`" `"$AppId`"."
    if ($Projects[$AppId].Package)
    {
        return
    }
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
            Invoke-ProjectBuild -AppId $Dependency.id -Projects $Projects -CompilerPath $CompilerPath -Verbose:$Verbose -Force:$Force -TempDirBase $TempDirBase -Server $Server -OnlyCompile:$OnlyCompile -SignToolPath $SignToolPath -SignToolArgumentList $SignToolArgumentList -RunALCops:$RunALCops
            Write-Verbose "Continuing with `"$AppId`"."
        }

        if (!$Projects[$Dependency.id].AppPath)
        {
            throw "Something went wrong, no app found for $($Dependency.id)."
        }

        $DependencyApps += $Projects[$Dependency.id].AppPath
        $DependencyPackageId += $Projects[$Dependency.id].Package.Id

        if ($Projects[$Dependency.id].AppJson.propagateDependencies)
        {
            foreach ($PropDependency in $Projects[$Dependency.id].AppJson.dependencies)
            {
                if (!$Projects.ContainsKey($PropDependency.id))
                {
                    continue
                }

                $DependencyApps += $Projects[$PropDependency.id].AppPath
                $DependencyPackageId += $Projects[$PropDependency.id].Package.Id
            }
        }
    }

    $Arguments = @{
        BranchName = $Project.BranchName
        Target = $Project.Target
        Variables = $Project.Variables
    }

    $AllCompileModifiers = Get-ProjectFileCompileModifiers -Path (Get-GocProjectFilePath -ProjectDir $Projects[$AppId].ProjectDir) @Arguments
    $ProjectFile = Get-ProjectFile -Path (Get-GocProjectFilePath -ProjectDir $Projects[$AppId].ProjectDir) @Arguments

    if (!$AllCompileModifiers)
    {
        $AllCompileModifiers = ,@(@())
    }

    $CompileOverride = Get-ProjectFileCompileModifiers -Path (Get-GocProjectFilePath -ProjectDir $Projects[$AppId].ProjectDir) -Property 'CompileOverride' @Arguments -Idx 0

    # Arguments for Get-AlProjectDependencies.
    $Arguments += @{
        ProjectDir = $Project.ProjectDir
    }

    $AlPackagesDir = $null
    $NetPackagesDir = $null
    if ($TempDirBase)
    {
        $ProjectDirName = [System.IO.Path]::GetFileName($Project.ProjectDir)
        $ProjectTempDir = Join-Path $TempDirBase $ProjectDirName
        $AlPackagesDir = Join-Path $ProjectTempDir '.alpackages'
        $NetPackagesDir = Join-Path $ProjectTempDir '.netpackages'
    }

    if (!$CompilerPath)
    {
        $CompilerPath = Get-AlCompiler -Server $Server
    }

    $AssemblyDir = @("C:\WINDOWS\Microsoft.NET\assembly")
    if ($NetPackagesDir)
    {
        $AssemblyDir += $NetPackagesDir
    }
    else
    {
        $AssemblyDir += (Join-Path $Projects[$AppId].ProjectDir '.netpackages')
    }

    if($RunALCops)
    {
        $AppSourceJsonPath = Join-Path $ProjectDir 'AppSourceCop.json'
        if(!(Test-Path $AppSourceJsonPath))
        {
            Write-Warning "AppSourceCop.json not found at location: $AppSourceJsonPath"
            Write-Warning "Can not run AL cop."
            $RunALCops = $false
        }
        elseif ($null -eq $ProjectFile.alAppSourceCopVersionQuery)
        {
            Write-Warning "alAppSourceCopVersionQuery variable not defined in project file in project folder: $ProjectDir"
            Write-Warning "Unable to run AL Cop."
            $RunALCops = $false
        }
    }

    foreach ($CompileModifiers in $AllCompileModifiers)
    {
        Get-AlProjectDependencies @Arguments `
            -CompileModifiers $CompileModifiers `
            -CompileOverride $CompileOverride `
            -SkipPackageId $DependencyPackageId `
            -PackageCacheDir $AlPackagesDir `
            -AssemblyProbingDir $NetPackagesDir `
            -Server $Server `
            -Verbose:$verbose `
            -ClearDirs `
            -Force `
            -RunALCops:$RunALCops

        if ($DependencyApps)
        {
            # Copy any dependencies that are included in this build.
            if ($AlPackagesDir)
            {
                $DestDir = $AlPackagesDir
            }
            else
            {
                $DestDir = (Join-Path $Projects[$AppId].ProjectDir '.alpackages')
            }
            [IO.Directory]::CreateDirectory($DestDir) | Out-Null
            Copy-Item -Path $DependencyApps -Destination $DestDir
        }

        $CompileArguments = @{
            ProjectDir = $Projects[$AppId].ProjectDir
            CompilerPath = $CompilerPath
            OutputDir = $Projects[$AppId].ProjectDir
            AssemblyDir = $AssemblyDir
            AlPackagesDir = $AlPackagesDir
            Verbose = $Verbose
            RunALCops = $RunALCops
        }

        if ($OnlyCompile -and $Projects[$AppId].OutputDir)
        {
            $CompileArguments.OutputDir = $Projects[$AppId].OutputDir
        }

        $Projects[$AppId].AppPath = Invoke-AlCompiler @CompileArguments
    }

    # Signing apps
    if ($SignToolPath)
    {
        $app = $Projects[$AppId].AppPath
        Write-Verbose "File being signed: $app"
        & $SignToolPath $SignToolArgumentList $app
        $SignStatus = (Get-AuthenticodeSignature $app).status
        Write-Verbose "Signing status of $app : $SignStatus"
        if ($SignStatus -ne 'Valid')
        {
            Write-Error Signed failed
        }
    }

    if ($ProjectTempDir -and (Test-Path $ProjectTempDir))
    {
        Remove-Item $ProjectTempDir -Force -Recurse
    }

    if (!$OnlyCompile)
    {
        $Arguments += @{
            AppPath = $Project.AppPath
            OutputDir = $Project.OutputDir
            Force = $Force
        }

        $Projects[$AppId].Package = New-AlProjectPackage @Arguments -Verbose:$verbose
        $Projects[$AppId].Package
    }
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

        .PARAMETER SignToolPath
            Specifies a path to the sign tool that will be used to sign apps.
            If not specified, the apps will not be signed.

        .PARAMETER SignToolArgumentList
            Specifies arguments for signing apps. The list should look like this:
            @('sign', '/f', 'pfxCertificatePath', '/p', 'pfxCertificatePassword',
            '/tr', "http://timestamp.digicert.com")
            Refer here for more clarification on signtool paramater list:
            https://learn.microsoft.com/en-us/windows/win32/seccrypto/signtool

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
    $Server,
        [string] $SignToolPath,
        [array] $SignToolArgumentList,
    [switch] $Force,
    [switch] $UseDependencyTempDir,
    [switch] $RunALCops
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
        if ($UseDependencyTempDir)
        {
            $TempDirBase = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
        }
        $Verbose = [bool]$PSBoundParameters["Verbose"]
        foreach ($AppId in $Projects.Keys)
        {
            if (!$Projects[$AppId].AppPath)
            {
                Invoke-ProjectBuild -AppId $AppId -Projects $Projects -CompilerPath $CompilerPath -Force:$Force -Verbose:$Verbose -TempDirBase $TempDirBase -Server $Server -SignToolPath $SignToolPath -SignToolArgumentList $SignToolArgumentList -RunALCops:$RunALCops
            }
        }
        if ($UseDependencyTempDir -and (Test-Path $TempDirBase))
        {
            Remove-Item $TempDirBase -Force -Recurse
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
            if ($Modifier.version -eq 'skip')
            {
                continue
            }
            
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