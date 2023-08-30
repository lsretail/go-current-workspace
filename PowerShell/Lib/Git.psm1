$ErrorActionPreference = 'stop'

function Compare-Branches
{
    param(
        [Parameter(Mandatory)]
        $RepositoryDir,
        [Parameter(Mandatory)]
        [string] $BaseBranchName,
        [Parameter(Mandatory)]
        [string] $TargetBranchName
    )

    Push-Location
    Set-Location $RepositoryDir

    $Result = Invoke-Expression -Command "git rev-list --left-right --count $($BaseBranchName)...$($TargetBranchName)"
    $behindCommits, $aheadCommits = $Result.Split("`t")

    Pop-Location
    
    [PSCustomObject]@{
        BaseBranchName   = $BaseBranchName
        TargetBranchName = $TargetBranchName
        Ahead            = [int]$aheadCommits
        Behind           = [int]$behindCommits
    }
}

function Get-FallbackBranch
{
    param(
        [Parameter(Mandatory)]
        [string[]] $BranchCandidates,
        [Parameter(Mandatory)]
        [string] $BranchName,
        [Parameter(Mandatory)]
        $RepositoryDir
    )

    # Check if the branch is one of the fallback branches.
    foreach ($CandidateBranch in $BranchCandidates)
    {
        if ($CandidateBranch -eq $BranchName)
        {
            return $CandidateBranch
        }
    }
    
    if (!(Test-GitBranchExists -RepositoryPath $RepositoryDir -BranchName $BranchName))
    {
        Write-Verbose "Target branch exists, will return first in list."
        return $BranchCandidates | Select-Object -First 1
    }

    $Responses = @()
    
    $RemoteName = Get-PreferredOrFirstGitRemoteName -RepositoryDir $RepositoryDir

    foreach ($CandidateBranch in $BranchCandidates)
    {
        $CandidateBranch = Get-BranchNameWithRemote -BranchName $CandidateBranch -RemoteName $RemoteName
        if (!(Test-GitBranchExists -RepositoryPath $RepositoryDir -BranchName $CandidateBranch))
        {
            continue
        }
        $Response = Compare-Branches -BaseBranchName $CandidateBranch -TargetBranchName $BranchName -RepositoryDir $RepositoryDir
        $Responses += $Response
    }

    if (!$Responses)
    {
        Write-Verbose "No fallback branches exist, will return first in list."
        return $BranchCandidates | Select-Object -First 1
    }
    
    $LowestLength = $null
    $SelectedBranch = $BranchCandidates | Select-Object -First 1
    foreach ($Response in $Responses)
    {
        $Length = [Math]::Sqrt($Response.Ahead*$Response.Ahead + $Response.Behind*$Response.Behind)
        Write-Verbose "Branch $($Response.BaseBranchName) is ahead $($Response.Ahead) and behind $($Response.Behind) with length is $Length."
        if (($null -eq $LowestLength) -or ($Length -lt $LowestLength))
        {
            $LowestLength = $Length
            $SelectedBranch = $Response.BaseBranchName
        }
    }
    
    return $SelectedBranch
}

function Get-PreferredOrFirstGitRemoteName
{
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$RepositoryDir,

        [string]$PreferredRemoteName = 'origin'
    )

    Push-Location
    Set-Location -Path $RepositoryDir

    # Get the remote names using Git command
    $remotes = git remote

    Pop-Location

    # Check if the preferred remote name exists
    if ($remotes -contains $PreferredRemoteName)
    {
        return $PreferredRemoteName
    }

    # Return the first remote name if the preferred one doesn't exist
    return $remotes[0]
}

function Get-BranchNameWithRemote
{
    param(
        [Parameter(Mandatory)]
        $BranchName,
        [Parameter(Mandatory)]
        $RemoteName
    )

    if ($BranchName.StartsWith($RemoteName))
    {
        return $BranchName
    }
    return "$RemoteName/$BranchName"
}

function Test-GitBranchExists
{
    param (
        [Parameter(Mandatory)]
        [string] $RepositoryPath,
        
        [Parameter(Mandatory)]
        [string] $BranchName
    )
    
    try
    {
        Push-Location
        Set-Location -Path $RepositoryPath -ErrorAction Stop
        
        $result = git rev-parse --quiet --verify $BranchName 2>$null
        
        return !!$result
    }
    catch
    {
        Write-Host "An error occurred: $_"
        return $false
    }
    finally
    {
        Pop-Location
    }
}

function Assert-GitOnPath
{
    $gitPath = Get-Command git -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source

    if (!$gitPath)
    {
        throw 'Git must be installed and on the path.'
    }
}

function Assert-GitIsRepository
{
    param(
        [Parameter(Mandatory)]
        $RepositoryDir
    )
    Push-Location
    Set-Location $RepositoryDir
    try
    {
        (git rev-parse --show-toplevel 2>$null) | Out-Null
    }
    catch
    {
        throw 'Specified path is not a Git repository.'
    }
    finally
    {
        Pop-Location
    }
}

Export-ModuleMember -Function Get-FallbackBranch,Assert-GitIsRepository,Assert-GitOnPath