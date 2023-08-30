$ErrorActionPreference = 'stop'

Import-Module GoCurrent
Import-Module (Join-Path $PSScriptRoot '_Utils.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Branch.psm1') -Force

$_VariableRegex = [regex]::new('\$\{(?<Name>[a-zA-Z0-9]*)(:(?<Func>[a-zA-Z0-9]+)(\((?<Args>[a-zA-Z0-9,]*)\))?)?\}')
$_AlAppVersion = 'AlAppVersion'
$_AlAppName = 'AlAppName'
$_AlAppPublisher = 'AlAppPublisher'
$_AlAppId = 'AlAppId'
$_AlAppDescription = 'AlAppDescription'
$_AlAppProjectDir = 'AlAppProjectDir'

$_AlAppVariables = @($_AlAppVersion, $_AlAppName, $_AlAppPublisher, $_AlAppId, $_AlAppDescription, $_AlAppProjectDir)
$_CurrentBranch = 'currentBranch'
$_ProjectDir = 'ProjectDir'
$_ReservedVariables = @($_ProjectDir, $_CurrentBranch) + $_AlAppVariables

$_CircularReferenceMarker = 'CIRCULAR-REFERENCE'

$_ResolveFileModified = @{}

function Get-ProjectFilePackages
{
    param(
        [Parameter(Mandatory = $true)]
        [Alias('ProjectFilePath')]
        $Path,
        [Parameter(Mandatory = $false)]
        [Alias('PackageGroupId')]
        [string] $Id = "dependencies",
        [string] $Target,
        [string] $BranchName,
        [hashtable] $Variables
    )

    $ProjectDir = Split-Path $Path -Parent
    $ProjectFile = Get-Content -Path $Path -Raw | ConvertFrom-Json

    Get-PackageGroupFromObj -ProjectFile $ProjectFile -Id $Id -ProjectDir $ProjectDir -Target $Target -BranchName $BranchName -Variables $Variables
}

function Get-ProjectFile
{
    param(
        [Parameter(Mandatory)]
        $Path,
        [string] $Target,
        [string] $BranchName,
        [hashtable] $Variables
    )

    $ProjectDir = Split-Path $Path -Parent
    $ProjectFile = Get-Content -Path $Path -Raw | ConvertFrom-Json
    $ProjectFileHashTable = Get-Content -Path $Path -Raw | ConvertFrom-JsonToHashTable

    $ResolveContainer = Get-ResolveContainer -ProjectDir $ProjectDir -ProjectFile $ProjectFile -Target $Target -BranchName $BranchName -Variables $Variables

    $ResolveAsVariables = @('id', 'name', 'displayName', 'description', 'outputDir','alAppSourceCopVersionQuery')
    $CopyProperties = @('instance', 'substituteFor', 'windowsUpdateSensitive', 'alIncludeServerAssemblies')

    $Result = @{}

    foreach ($Property in $ResolveAsVariables)
    {
        if ($ProjectFile.$Property)
        {
            $Result[(ConvertTo-Title $Property)] = Resolve-VariablesInString -Value $ProjectFile.$Property @ResolveContainer
        }
    }

    foreach ($Property in $CopyProperties)
    {
        if ($null -ne $ProjectFile.$Property)
        {
            $Result[(ConvertTo-Title $Property)] = $ProjectFile.$Property
        }
    }

    if ($ProjectFile.version)
    {
        $Result.Version = Resolve-Version -Version $ProjectFile.version @ResolveContainer
    }

    if ($ProjectFile.Dependencies)
    {
        $Packages = New-Object -TypeName System.Collections.ArrayList
        $Packages.AddRange($ProjectFile.dependencies) | Out-Null
        $Result.Dependencies = Resolve-PackagesVersions -Packages $Packages @ResolveContainer
        $Result.Dependencies = @()
        foreach ($Dep in $Packages)
        {
            $Entry = @{}
            $Dep.PSObject.Properties | ForEach-Object { $Entry[$_.Name] = $_.Value }
            $Result.Dependencies += $Entry
        }
    }

    if ($ProjectFile.files)
    {
        $Result.InputPath = @()
        foreach ($File in @($ProjectFile.files))
        {
            $File = Resolve-VersionTarget -Value $File -Target $Target
            if ($File -is [string])
            {

                $Result.InputPath += [System.IO.Path]::Combine($ProjectDir, (Resolve-VariablesInString -Value $File @ResolveContainer))
            }
            elseif ($null -eq $File)
            {
                continue
            }
            elseif (('SourcePath' -iin $File.PSobject.Properties.name) -and ('Destination' -iin $File.PSobject.Properties.name))
            {
                $Result.InputPath += Resolve-AdvancedFilePath -Value $File @ResolveContainer
            }
            else
            {
                throw "File paths can only be strings."
            }
        }
    }

    if ($ProjectFileHashTable.parameters)
    {
        $Result.Parameters = $ProjectFileHashTable.parameters
    }

    if ($ProjectFileHashTable.fillParameters)
    {
        $Result.FillParameters = @{}
        foreach ($PackageId in $ProjectFileHashTable.fillParameters.Keys)
        {
            $Result.FillParameters[$PackageId] = @{}
            foreach ($Property in $ProjectFileHashTable.fillParameters[$PackageId].Keys)
            {
                $Result.FillParameters[$PackageId][$Property] = $ProjectFileHashTable.fillParameters[$PackageId][$Property]
            }
        }
    }

    if ($ProjectFileHashTable.commands)
    {
        $Result.Commands = [hashtable] $ProjectFileHashTable.commands
    }

    return $Result
}

function Get-ProjectFileCompileModifiers
{
    param(
        [Parameter(Mandatory = $true)]
        [Alias('ProjectFilePath')]
        $Path,
        [string] $Target,
        [string] $BranchName,
        [hashtable] $Variables,
        [ValidateSet('CompileModifiers', 'CompileOverride')]
        [string] $Property = 'CompileModifiers',
        $Idx = $null
    )
    $ProjectDir = Split-Path $Path -Parent
    $ProjectFile = Get-Content -Path $Path -Raw | ConvertFrom-Json

    $Modifiers = $ProjectFile.$Property

    if (!$Modifiers)
    {
        return
    }

    $ResolveContainer = Get-ResolveContainer -ProjectDir $ProjectDir -ProjectFile $ProjectFile -Target $Target -BranchName $BranchName -Variables $Variables

    if (($Modifiers | Select-Object -First 1) -is [array])
    {
        $CurrIdx = -1;
        $Entries = @()
        foreach ($CompileModifiers in $Modifiers)
        {
            $CurrIdx++
            if (($null -ne $Idx) -and $Idx -ne $CurrIdx)
            {
                continue
            }
            $Packages = New-Object -TypeName System.Collections.ArrayList
            $Packages.AddRange($CompileModifiers) | Out-Null
            Resolve-PackagesVersions -Packages $Packages @ResolveContainer -IgnoreMissingTarget
            if ($Packages.Count -gt 0 -and $null -ne $Idx)
            {
                return , $Packages.ToArray()
            }
            elseif ($Packages.Count -gt 0)
            {
                $Entries += , $Packages.ToArray()
            }
            elseif ($null -ne $Idx)
            {
                return , @()
            }
        }
        if ($null -eq $Idx)
        {
            return , $Entries
        }
    }
    elseif (($null -ne $Idx) -and $Idx -eq 0)
    {
        $Packages = New-Object -TypeName System.Collections.ArrayList
        $Packages.AddRange($Modifiers) | Out-Null
        Resolve-PackagesVersions -Packages $Packages @ResolveContainer -IgnoreMissingTarget
        $Packages.ToArray()
    }
    else
    {
        return , @()
    }
}

function Get-ProjectFileTargets
{
    <#
        .SYNOPSIS
            Get version targets defined in specified package group or dependencies.

        .NOTES
            Use -UseDevTarget to return the targets specified by the devTarget property
            in the project file.
            This can be handy to simplify the user interface for developers.
    #>
    param(
        [Parameter(Mandatory)]
        $Path,
        $Id = 'dependencies',
        [switch] $UseDevTarget
    )

    if (!$Id)
    {
        $Id = 'dependencies'
    }

    $ProjectDir = Split-Path $Path -Parent
    $ProjectFile = Get-Content -Path $Path -Raw | ConvertFrom-Json

    $GlobalDevTarget = @()
    if ($UseDevTarget -and $ProjectFile.devTarget)
    {
        $GlobalDevTarget = $ProjectFile.devTarget | Sort-Object
    }

    $Set = Get-PackageGroupFromObj -ProjectFile $ProjectFile -Id $Id -ProjectDir $ProjectDir -DoNotResolveVersions

    if ($UseDevTarget)
    {
        foreach ($Group in $ProjectFile.devPackageGroups)
        {
            if ($Group.Id -eq $Id)
            {
                if ($Group.DevTarget)
                {
                    return $Group.DevTarget | Sort-Object
                }
            }
        }
    }

    if ($GlobalDevTarget)
    {
        return $GlobalDevTarget
    }

    $Targets = @('default')

    foreach ($Package in $Set.Packages)
    {
        if (($Package.version -isnot [string]) -and $Package.version.default)
        {
            $Package.version.PSObject.Properties | ForEach-Object {
                if (!($Targets -icontains $_.Name))
                {
                    $Targets += $_.Name
                }
            }
        }
    }
    return $Targets | Sort-Object
}

function Get-ProjectFileVariables
{
    param(
        [Parameter(Mandatory = $true)]
        [Alias('ProjectFilePath')]
        $Path,
        [string] $Target,
        [string] $BranchName,
        [hashtable] $Variables    
    )

    $ProjectDir = Split-Path $Path -Parent
    $ProjectFile = Get-Content -Path $Path -Raw | ConvertFrom-Json

    if (!$ProjectFile.Variables)
    {
        return
    }

    $ResolveContainer = Get-ResolveContainer -ProjectDir $ProjectDir -ProjectFile $ProjectFile -Target $Target -BranchName $BranchName -Variables $Variables

    $Variables = @{}

    foreach ($Variable in $ProjectFile.Variables.PSObject.Properties)
    {
        $Variables[$Variable.Name] = Resolve-VariablesInString -Value "`$`{$($Variable.Name)`}" @ResolveContainer
    }
    return $Variables
}

function Get-ResolveContainer
{
    param(
        [Parameter(Mandatory)]
        $ProjectFile,
        [Parameter(Mandatory)]
        $ProjectDir,
        $Target,
        $BranchName,
        [hashtable] $Variables,
        [hashtable] $ProjectVariables = $null,
        [hashtable] $ResolveCache = @{},
        [hashtable] $BranchToLabelMap = $null
    )

    if ($null -eq $ProjectVariables)
    {
        $ProjectVariables = @{}
        if ($ProjectFile.variables)
        {
            $ProjectFile.variables.PSObject.properties | ForEach-Object { $ProjectVariables[$_.Name] = $_.Value }
        }
        elseif ($ProjectFile.versionVariables)
        {
            $ProjectFile.versionVariables.PSObject.properties | ForEach-Object { $ProjectVariables[$_.Name] = $_.Value }
        }
    }

    if ($Variables)
    {
        foreach ($VariableName in $Variables.Keys)
        {
            if (!$Variables[$VariableName])
            {
                $ProjectVariables[$VariableName] = ''
            }
            else
            {
                $ProjectVariables[$VariableName] = $Variables[$VariableName].ToString()
            }
        }
    }

    if ($BranchToLabelMap -eq $null)
    {
        $BranchToLabelMap = GetBranchLabelMap -ProjectFile $ProjectFile
    }

    return @{
        ProjectVariables = $ProjectVariables
        ResolveCache     = $ResolveCache
        ProjectDir       = $ProjectDir
        ProjectFile      = $ProjectFile
        Target           = $Target
        BranchName       = $BranchName
        BranchToLabelMap = $BranchToLabelMap
    }
}

function GetBranchLabelMap
{
    param(
        [Parameter(Mandatory = $true)]
        $ProjectFile
    )
    $BranchToPreReleaseLabelMap = $null
    if ($null -ne $ProjectFile.branchToPreReleaseLabelMap)
    {
        $BranchToPreReleaseLabelMap = @{}
        $ProjectFile.branchToPreReleaseLabelMap.PSObject.properties | ForEach-Object {
            $Name = $_.Name
            if ($Name -ieq '${currentBranch}')
            {
                $Name = '%BRANCHNAME%'
            }
            $BranchToPreReleaseLabelMap[$Name] = $_.Value -ireplace [regex]::Escape('${currentBranch}'), '%BRANCHNAME%'
        }
    }

    $BranchToPreReleaseLabelMap
}

function Get-PackageGroupFromObj
{
    param(
        [Parameter(Mandatory)]
        $ProjectFile,
        [Parameter(Mandatory)]
        $Id,
        [hashtable] $Variables,
        [hashtable] $ProjectVariables = $null,
        [hashtable] $ResolveCache = @{},
        [hashtable] $BranchToLabelMap = $null,
        $ProjectDir,
        $Target,
        $BranchName,
        [switch] $DoNotResolveVersions
    )
    $ResolveContainer = Get-ResolveContainer -ProjectFile $ProjectFile -Variables $Variables -ProjectVariables $ProjectVariables -ProjectDir $ProjectDir -Target $Target -BranchName $BranchName -ResolveCache $ResolveCache

    if ($Id -ieq 'dependencies')
    {
        return Resolve-Part -Id 'dependencies' -ProjectFile $ProjectFile
    }

    if ($Id -ieq 'devDependencies')
    {
        return Resolve-Part -Id 'devDependencies' -ProjectFile $ProjectFile
    }

    $Packages = New-Object -TypeName System.Collections.ArrayList

    foreach ($Set in $ProjectFile.devPackageGroups)
    {
        if ($Set.Id -ne $Id)
        {
            continue
        }

        foreach ($Entry in $Set.packages)
        {
            if ([bool]($Entry.PSObject.properties.name -contains '$ref'))
            {
                $Out = Get-PackageGroupFromObj -Id $Entry.'$ref' @ResolveContainer -DoNotResolveVersions:$DoNotResolveVersions
                $Packages.AddRange($Out.Packages) | Out-Null
            }
            else
            {
                $Packages.Add($Entry) | Out-Null
            }
        }

        if (!$DoNotResolveVersions)
        {
            Resolve-PackagesVersions -Packages $Packages @ResolveContainer
        }
        $Set.packages = $Packages
        return $Set
    }
}

function Resolve-Part
{
    param(
        [Parameter(Mandatory)]
        $Id,
        [Parameter(Mandatory)]
        $ProjectFile
    )

    $Packages = New-Object -TypeName System.Collections.ArrayList
    if ($ProjectFile.$Id)
    {
        $Packages.AddRange($ProjectFile.$Id) | Out-Null
        if (!$DoNotResolveVersions)
        {
            Resolve-PackagesVersions -Packages $Packages @ResolveContainer
        }
    }

    $Obj = @{
        'id'       = $Id
        'name'     = $Id
        'packages' = $Packages
    }
    $Set = New-Object psobject -Property $Obj


    return $Set
}

function Resolve-PackagesVersions
{
    param(
        [System.Collections.ArrayList] $Packages,
        [hashtable] $ProjectVariables,
        [hashtable] $ResolveCache,
        $ProjectDir,
        $Target,
        $BranchName,
        $BranchToLabelMap,
        [switch] $IgnoreMissingTarget
    )

    $ToRemove = @()

    foreach ($Package in $Packages)
    {
        if ($Package.Path)
        {
            $Package.Path = Resolve-VariablesInString -Value $Package.Path -ProjectVariables $ProjectVariables -ResolveCache $ResolveCache -ProjectDir $ProjectDir -Target $Target -BranchName $BranchName -BranchToLabelMap $BranchToLabelMap
            $Package.Path = [IO.Path]::Combine($ProjectDir, $Package.Path)
            continue
        }
        $Package.Version = Resolve-Version -Version $Package.Version -ProjectVariables $ProjectVariables -ResolveCache $ResolveCache -ProjectDir $ProjectDir -Target $Target -BranchName $BranchName -BranchToLabelMap $BranchToLabelMap -PackageId $Package.id -IgnoreMissingTarget:$IgnoreMissingTarget

        if ($null -eq $Package.Version)
        {
            $ToRemove += $Package
            continue
        }
    }

    foreach ($Package in $ToRemove)
    {
        $Packages.Remove($Package)
    }
}

function Resolve-VariablesInString
{
    param(
        $Value,
        [hashtable] $ProjectVariables,
        [hashtable] $ResolveCache,
        $ProjectDir,
        $Target,
        $BranchName,
        $BranchToLabelMap
    )

    $MatchList = $_VariableRegex.Matches($Value)

    for ($Idx = $MatchList.Count - 1; $Idx -ge 0; $Idx--)
    {
        $Match = $MatchList[$Idx]
        $VariableName = $Match.Groups['Name'].Value
        if ($Match.Groups['Func'])
        {
            $FuncName = $Match.Groups['Func'].Value
        }

        $ArgsList = @()
        if ($Match.Groups['Args'])
        {
            $ArgsList = $Match.Groups['Args'].Value.Split(',')
        }
        $Replacement = $null

        if ($ResolveCache.Keys -icontains $VariableName)
        {
            $Replacement = $ResolveCache[$VariableName]
            if ($Replacement -eq $_CircularReferenceMarker)
            {
                throw "Circular reference to variable `"$VariableName`"."
            }
        }
        elseif ($_AlAppVariables -icontains $VariableName)
        {
            Resolve-AlAppVariables -ProjectDir $ProjectDir -ResolveCache $ResolveCache
            $Replacement = $ResolveCache[$VariableName]
        }
        elseif ($VariableName -eq $_CurrentBranch)
        {
            $Replacement = $BranchName
        }
        elseif ($VariableName -eq $_ProjectDir)
        {
            $Replacement = $ProjectDir
        }
        elseif ($ProjectVariables.ContainsKey($VariableName))
        {
            $ResolveCache[$VariableName] = $_CircularReferenceMarker
            $Replacement = Resolve-VersionWithFunction -VersionValue $ProjectVariables[$VariableName] -Target $Target -ProjectDir $ProjectDir -VariableName $VariableName -BranchName $BranchName -BranchToLabelMap $BranchToLabelMap -ResolveCache $ResolveCache -ProjectVariables $ProjectVariables
            $ResolveCache[$VariableName] = $Replacement
        }
        elseif($VariableName.ToLower() -eq 'alAppSourceCopVersion'.ToLower())
        {
            $Replacement = (Get-Content (Join-Path ((Get-Item $ProjectDir).Parent.FullName) 'AppSourceCop.json') | ConvertFrom-Json).Version
            $ResolveCache[$VariableName] = $Replacement
        }

        # Resolve and execute a function of a function, ${variable:function}
        if ($null -ne $Replacement)
        {
            $FromIdx = $Match.Index + $Match.Length
            if ($FuncName -ieq 'Parts')
            {
                $Replacement = Get-VersionParts -Version $Replacement @ArgsList
            }
            if ($FuncName -ieq 'PreReleaseLabel')
            {
                $Replacement = ConvertTo-PreReleaseLabel -Label $Replacement
            }
            if ($FuncName -ieq 'BranchLabel')
            {
                $Replacement = ConvertTo-BranchPreReleaseLabel -BranchName $Replacement -BranchToLabelMap $BranchToLabelMap
            }
            if ($FuncName -ieq 'MaxLength')
            {
                $Replacement = Get-MaxLength -Value $Replacement @ArgsList
            }
            $Value = $Value.Substring(0, $Match.Index) + $Replacement + $Value.Substring($FromIdx, $Value.Length - $FromIdx)
        }
    }
    return $Value
}

function Resolve-Version
{
    param(
        [Parameter(Mandatory)]
        $Version,
        $PackageId,
        [hashtable] $ProjectVariables,
        [hashtable] $ResolveCache,
        $ProjectDir,
        $Target,
        $BranchName,
        $BranchToLabelMap,
        [switch] $IgnoreMissingTarget,
        [Parameter(ValueFromRemainingArguments)]
        $Remaning
    )

    $Version = Resolve-VersionTarget -Version $Version -Target $Target

    if ($null -eq $Version)
    {
        return $null
    }

    if ($Version -is [string])
    {
        return Resolve-VariablesInString -Value $Version -ProjectVariables $ProjectVariables -ResolveCache $ResolveCache -ProjectDir $ProjectDir -Target $Target -BranchName $BranchName -BranchToLabelMap $BranchToLabelMap
    }
    else
    {
        return Resolve-VersionWithFunction -VersionValue $Version -Target $Target -ProjectDir $ProjectDir -PackageId $PackageId -BranchName $BranchName -BranchToLabelMap $BranchToLabelMap -ResolveCache $ResolveCache -ProjectVariables $ProjectVariables -IgnoreMissingTarget $IgnoreMissingTarget
    }
}

function Resolve-VersionTarget
{
    param(
        [Alias('Version')]
        $Value,
        $Target
    )

    if ($Value -is [string])
    {
        return $Value
    }

    if ($Target -and ($Target -in $Value.PSobject.Properties.name))
    {
        return $Value.$Target
    }
    elseif ($Value.PSobject.Properties.name -match 'default')
    {
        return $Value.default
    }
    else
    {
        return $Value
    }
}

function Resolve-VersionWithFunction
{
    param(
        $PackageId,
        $VersionValue,
        $ProjectDir,
        $Target,
        $BranchName,
        $BranchToLabelMap,
        [hashtable] $ProjectVariables,
        [hashtable] $ResolveCache,
        [switch] $IgnoreMissingTarget
    )

    $ResolveContainer = @{
        ProjectVariables = $ProjectVariables
        ResolveCache = $ResolveCache
        ProjectDir = $ProjectDir
        Target = $Target
        BranchName = $BranchName
        BranchToLabelMap = $BranchToLabelMap
    }

    if ($VersionValue.GetType() -eq [string])
    {
        return (Resolve-VariablesInString -Value $VersionValue @ResolveContainer)
    }

    if ($null -ne $VersionValue.AlAppId)
    {
        $Arguments = @{
            AlAppId      = $VersionValue.AlAppId
            AlAppIdType  = $VersionValue.AlAppIdType
            AlAppIdParts = $VersionValue.AlAppIdParts
            ProjectDir   = $ProjectDir
        }
        if (!$Arguments.AlAppIdType)
        {
            $Arguments.AlAppIdType = 'fromMinor'
        }
        return Resolve-VariableAlAppJson @Arguments
    }
    elseif ($null -ne $VersionValue.Id)
    {
        $Arguments = @{
            Id               = $VersionValue.Id
            Version          = (Resolve-VariablesInString -Value $VersionValue.Version -ProjectVariables $ProjectVariables -ResolveCache $ResolveCache -ProjectDir $ProjectDir -Target $Target -BranchName $BranchName -BranchToLabelMap $BranchToLabelMap)
            ResolverPath     = $VersionValue.ResolverPath
            ResolverFunction = $VersionValue.ResolverFunction
            ProjectDir       = $ProjectDir
            Target           = $Target
        }
        return Resolve-Variable @Arguments
    }
    elseif ($null -ne $VersionValue.BranchPriorityFilter)
    {
        return Resolve-VariableBranchFilter -BranchName $BranchName -BranchPriorityFilter $VersionValue.BranchPriorityFilter -BranchToLabelMap $BranchToLabelMap
    }
    elseif ($null -ne $VersionValue.closestCandidateBranches)
    {
        Import-Module (Join-Path $PSScriptRoot 'Git.psm1')
        Assert-GitIsRepository -RepositoryDir $ProjectDir
        Assert-GitOnPath

        if ($VersionValue.closestCandidateBranches -isnot [array])
        {
            throw 'The property "closestCandidateBranches" must contain array of branch names.'
        }

        $closestCandidateBranches = $VersionValue.closestCandidateBranches | ForEach-Object { Resolve-VariablesInString -Value $_ @ResolveContainer }
        $ClosestToBranch = $BranchName
        if ($VersionValue.closestToBranch)
        {
            $ClosestToBranch = Resolve-VariablesInString -Value $VersionValue.closestToBranch @ResolveContainer
        }
        return Get-FallbackBranch -BranchCandidates $closestCandidateBranches -BranchName $ClosestToBranch -RepositoryDir $ProjectDir
    }
    elseif ($null -ne $VersionValue.resolveVersionFromPackageId)
    {
        $VersionValue.resolvePackageId = Resolve-VariablesInString -Value $VersionValue.resolvePackageId @ResolveContainer
        $VersionValue.resolvePackageVersion = Resolve-VariablesInString -Value $VersionValue.resolvePackageVersion @ResolveContainer
        $VersionValue.resolveVersionFromPackageId = Resolve-VariablesInString -Value $VersionValue.resolveVersionFromPackageId @ResolveContainer

        $Result = Get-GocUpdates -Id $VersionValue.resolvePackageId -Version $VersionValue.resolvePackageVersion | Where-Object { $_.Id -eq $VersionValue.resolveVersionFromPackageId} | Select-Object -First 1
        if (!$Result)
        {
            return "ERROR: Could not resolve version for package `"$($VersionValue.resolveVersionFromPackageId)`" from `"$($VersionValue.resolvePackageId)`" v$($VersionValue.resolvePackageVersion)."
        }
        return $Result.Version
    }
    else
    {
        if (!$PackageId)
        {
            throw "Could not resolve version for variable `"$($VersionValue)`"."
        }
        if (!$IgnoreMissingTarget)
        {
            if ($Target)
            {
                throw "Package `"$($PackageId)`" does not have a version for selected target `"$Target`" nor `"default`"."
            }
            else
            {
                throw "Package `"$($PackageId)`" does not have a version for target `"default`"."
            }
        }
        else
        {
            return $null
        }
    }
}

function Resolve-Variable
{
    param(
        [Parameter(Mandatory = $false)]
        $Id,
        $Version = "",
        $ResolverPath,
        $ResolverFunction,
        $ProjectDir,
        [Parameter(Mandatory = $false)]
        $Target
    )

    if (!$ResolverPath)
    {
        $Version = Get-GocUpdates -Id $Id -Version $Version -InstanceName 'this-instance-should-not-exists-at-any-point' | Where-Object { $_.Id -eq $Id } | Select-Object -First 1
        $Version.Version
    }
    else
    {
        $Path = [System.IO.Path]::Combine($ProjectDir, $ResolverPath)

        $FileInfo = Get-Item -Path $Path

        $Force = ($_ResolveFileModified.ContainsKey($Path) -and ($_ResolveFileModified[$Path] -ne $FileInfo.LastWriteTime))

        $Block = {
            param($Force)
            Import-Module $Path -Force:$Force
            . $ResolverFunction -ProjectDir $ProjectDir -Id $Id -Version $Version -Target $Target
        }
        & $Block -Force $Force
        $_ResolveFileModified[$Path] = $FileInfo.LastWriteTime
    }
}
function Resolve-VariableAlAppJson
{
    param(
        $AlAppId,
        [ValidateSet('version', 'fromMinor', 'fromMajor', 'fromMinorToNextMajor', 'fromMajorToNextMajor', '')]
        [string]$AlAppIdType,
        $AlAppIdParts,
        $ProjectDir
    )

    if (!$AlAppIdType)
    {
        $AlAppIdType = 'fromMinor'
    }
    if (!$AlAppIdParts)
    {
        $AlAppIdParts = 4
    }

    $AppJsonPath = Get-AlAppJsonPath -ProjectDir $ProjectDir
    $Version = Get-VersionFromAppDependency -AppJsonPath $AppJsonPath -AppId $AlAppId
    if (!$Version)
    {
        throw "Could not locate dependency with app id `"$AlAppId`" in `"$AppJsonPath`"."
    }

    if ($AlAppIdType -eq 'version')
    {
        $Version = Get-VersionParts -Version $Version -Places $AlAppIdParts
        return $Version
    }

    $Arguments = @{
        FromMajor   = ($AlAppIdType -ieq 'fromMajor') -or ($AlAppIdType -ieq 'fromMajorToNextMajor')
        ToNextMajor = ($AlAppIdType -ieq 'fromMinorToNextMajor') -or ($AlAppIdType -ieq 'fromMajorToNextMajor')
    }

    return Get-VersionRangeFromVersion -Version $Version -Places $AlAppIdParts @Arguments
}

function Resolve-AlAppVariables
{
    param(
        [Parameter(Mandatory = $true)]
        [hashtable] $ResolveCache,
        [Parameter(Mandatory = $true)]
        $ProjectDir
    )

    $AppJsonPath = Get-AlAppJsonPath -ProjectDir $ProjectDir

    $AppJson = Get-Content -Raw -Path $AppJsonPath | ConvertFrom-Json
    $ResolveCache[$_AlAppId] = $AppJson.id
    $ResolveCache[$_AlAppVersion] = $AppJson.version
    $ResolveCache[$_AlAppPublisher] = $AppJson.publisher
    $ResolveCache[$_AlAppName] = $AppJson.name
    $ResolveCache[$_AlAppDescription] = $AppJson.description
    $ResolveCache[$_AlAppProjectDir] = ([System.IO.Path]::GetDirectoryName($AppJsonPath))
}

function Resolve-VariableBranchFilter
{
    param(
        $BranchName,
        [Array] $BranchPriorityFilter,
        $BranchToLabelMap
    )

    $List = @()

    foreach ($Branch in $BranchPriorityFilter)
    {
        if ($Branch -icontains '${currentBranch}')
        {
            $List += $Branch -ireplace [regex]::Escape('${currentBranch}'), $BranchName
        }
        else
        {
            $List += $Branch
        }
    }

    $Arguments = @{
        BranchName = $List
    }
    if ($BranchToLabelMap)
    {
        $Arguments.BranchToLabelMap = $BranchToLabelMap
    }
    ConvertTo-BranchPriorityPreReleaseFilter @Arguments
}

function Resolve-AdvancedFilePath
{
    param(
        $Value,
        [hashtable] $ProjectVariables,
        [hashtable] $ResolveCache,
        $ProjectDir,
        $Target,
        $BranchName,
        $BranchToLabelMap
    )

    $ResolveContainer = @{
        ProjectVariables = $ProjectVariables
        ResolveCache     = $ResolveCache
        ProjectDir       = $ProjectDir
        Target           = $Target
        BranchName       = $BranchName
        BranchToLabelMap = $BranchToLabelMap
    }

    if (('SourcePath' -iin $Value.PSobject.Properties.name) -and ('Destination' -iin $Value.PSobject.Properties.name))
    {
        $Hashtable = @{
            SourcePath  = @()
            Destination = $Value.Destination
        }
        foreach ($Item in $Value.SourcePath)
        {
            $Hashtable.SourcePath += [System.IO.Path]::Combine($ProjectDir, (Resolve-VariablesInString -Value $Item @ResolveContainer))
        }

        return $Hashtable
    }
    else
    {
        return $Value
    }
}

Export-ModuleMember -Function '*-ProjectFile*'