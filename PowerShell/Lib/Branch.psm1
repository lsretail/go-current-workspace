$ErrorActionPreference = 'stop'

function ConvertTo-BranchPreReleaseLabel
{
    <#
        .SYNOPSIS
            Convert a branch name to a pre-release label.

        .PARAMETER BranchName
            Branch name to convert.
        
        .PARAMETER Map
            A hashtable that defines the conversion map.
            Key: Specify a branch name.
            Value: Specify output string, %BRANCHNAME% will be replace with the name specified with -BranchName. 
            Adding "%BRANCHNAME%" as key will catch all branches not defined in the hashtable map.
        
        .PARAMETER Strategy
            Specify a strategy to use for branch to pre-release label conversion.

        .EXAMPLE
            PS> ConvertTo-BranchPreReleaseLabel -BranchName 'master'
            dev.0.master

            PS> ConvertTo-BranchPreReleaseLabel -BranchName 'qwerty'
            dev.branch.qwerty
    #>
    param(
        [Parameter(Mandatory)]
        $BranchName,
        [Alias('BranchToLabelMap')]
        [hashtable] $Map,
        [string] $Strategy
    )

    if (!$Map)
    {
        $Map = Get-BranchPreReleaseLabelMap -Strategy $Strategy
    }

    if ($Map.Contains($BranchName))
    {
        $Label = $Map[$BranchName]
    }
    elseif (!$Map.Contains("%BRANCHNAME%"))
    {
        throw "Specified map must include `"%BRANCHNAME%`" key."
    }
    else 
    {
        $Label = $Map["%BRANCHNAME%"]
    }

    if (!$Label)
    {
        return $null
    }

    $BranchName = $BranchName.ToLower()
    $Label = $Label.Replace("%BRANCHNAME%", $BranchName)
    $Label = [regex]::Replace($Label, "[^a-zA-Z0-9-.+]", "-")  
    return [regex]::Replace($Label, "[-]{2,}", "-").ToLower()
}

function Get-BranchPreReleaseLabelMap
{
    <#
        .SYNOPSIS
            Get a hashtable that defines the conversion map for branch to pre-release label conversion.
        
        .PARAMETER Strategy
            Specify a strategy to use for branch to pre-release label conversion.
    #>
    param(
        [string] $Strategy
    )

    if (!$Strategy)
    {
        $Strategy = 'alpha-beta-rc-release'
    }

    if ($Strategy -eq 'lsc-dev')
    {
        return @{
            "master" = "alpha.0"
            "develop" = "alpha.1"
            "%BRANCHNAME%" = "alpha-branch.%BRANCHNAME%"
        }
    }
    elseif ($Strategy -eq 'alpha-beta-rc-release')
    {
        return @{
            "master" = "alpha"
            "main" = "alpha"
            "beta" = "beta"
            "rc" = "rc"
            "release" = $null
            "%BRANCHNAME%" = "alpha-branch.%BRANCHNAME%"
        }
    }
    elseif ($Strategy -eq 'legacy')
    {
        return @{
            "master" = "dev.0.%BRANCHNAME%"
            "%BRANCHNAME%" = "dev.branch.%BRANCHNAME%"
        }
    }
    throw "Unknown strategy for branch pre-release: $Strategy"
}

function ConvertTo-PreReleaseLabel
{
    <#
        .SYNOPSIS
            Convert specified label to pre-release label.
        
        .DESCRIPTION
            A utility function to format a pre-release label.

        .EXAMPLE
            PS> ConvertTo-PreReleaseLabel -Label 'this is a beta'
            this-is-a-beta

            PS> ConvertTo-PreReleaseLabel -Label 'alpha'
            alpha
    #>
    param(
        [Parameter(Mandatory)]
        [string] $Label
    )

    return [regex]::Replace($Label, "[^a-zA-Z0-9-.+]", "-")  
}

function ConvertTo-BranchPriorityPreReleaseFilter
{
    param(
        [Parameter(Mandatory)]
        [Array] $BranchName,
        [Alias('BranchToLabelMap')]
        $Map,
        $Strategy
    )
                                         
    $Labels = @()
    foreach ($Branch in $BranchName)
    {
        if (!$Branch)
        {
            continue
        }

        if ($Branch -match '\d+\.\d+(\.\d+(\.\d+)?)?|\*-.*')
        {
            $Labels += $Branch
            continue
        }

        $Label = ConvertTo-BranchPreReleaseLabel -BranchName $Branch.Trim() -Map $Map -Strategy $Strategy
        if (!$Label)
        {
            $Labels += '>=0.0.1'
            continue
        }
        $Label = $Label.Trim()
        $Filter = "*-$Label."
        if (!$Labels.Contains($Filter))
        {
            $Labels += $Filter
        }
    }
    
    "$([string]::Join(' >> ', $Labels))"
}