$ErrorActionPreference = 'stop'

Import-Module LsSetupHelper\Utils\Streams

function Export-ArchiveFromApp
{
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,
        [Parameter(Mandatory = $true)]
        [string] $OutputPath
    )

    try 
    {
        $Path = (Resolve-Path $Path | Select-Object -First 1).ProviderPath
        [System.IO.Stream] $InputStream = [System.IO.File]::OpenRead($Path)

        $Offset = Find-StreamSequence -Stream $InputStream -Sequence @(0x50, 0x4b, 0x03, 0x04)

        if (!$Offset)
        {
            throw "Not able to detect archive within the file."
        }

        [System.IO.Stream] $OutputStream = [System.IO.File]::Create($OutputPath)

        Copy-StreamPart -Input $InputStream -Output $OutputStream -Offset $Offset -Length $InputStream.Length
    }
    catch
    {
        throw "Unsupported file format: $Path"
    }
    finally 
    {
        if ($InputStream)
        {
            $InputStream.Dispose()
        }
        if ($OutputStream)
        {
            $OutputStream.Dispose()
        }
    }
}

function Get-AppJsonFromApp
{
    param(
        [Parameter(Mandatory)]
        $Path
    )

    $TempDir = [System.IO.Path]::Combine([IO.Path]::GetTempPath(), [System.IO.Path]::GetRandomFileName())
    [System.IO.Directory]::CreateDirectory($TempDir) | Out-Null

    try 
    {
        $ArchivePath = Join-Path $TempDir 'Archive.zip'

        Export-ArchiveFromApp -Path $Path -OutputPath $ArchivePath
    
        $NavxManifestPath = Join-Path $TempDir 'NavxManifest.xml'
    
        Expand-NavxManifestFromArchive -Path $ArchivePath -OutputPath $NavxManifestPath
    
        ConvertTo-AppJson -Path $NavxManifestPath    
    }
    catch
    {
        $Manifest = Get-AppJsonFromRuntimeApp -Path $Path
        if (!$Manifest)
        {
            throw
        }
        return $Manifest
    }
    finally
    {
        Remove-Item -Path $TempDir -Recurse   
    }
}

function Export-AppJsonFromApp
{
    param(
        [Parameter(Mandatory = $true)]
        $Path,
        [Parameter(Mandatory = $true)]
        $OutputPath
    )
    $AppJson = Get-AppJsonFromApp -Path $Path

    ConvertTo-Json $AppJson -Depth 10 | Set-Content -Path $OutputPath 
}

function Expand-NavxManifestFromArchive
{
    param(
        $Path,
        $OutputPath
    )

    Add-Type -Assembly System.IO.Compression.FileSystem
    try
    {
        $Zip = [IO.Compression.ZipFile]::OpenRead($Path)
        foreach ($Entry in $Zip.Entries)
        {
            if ($Entry.Name -match 'NavxManifest.xml')
            {
                [System.IO.Compression.ZipFileExtensions]::ExtractToFile($Entry, $OutputPath, $true)            
                return
            }
        }        
    }
    finally
    {
        $zip.Dispose()        
    }
    throw "Could not find NavxManifest.xml in: $Path."
}

function ConvertTo-AppJson
{
    <#
        .SYNOPSIS
            Convert NavxManifest.xml to app.json
    #>
    param(
        $Path
    )

    [xml]$Xml = Get-Content -Path $Path
    
    $Content = Convert-AttributesToHashtable -Attributes $Xml.Package.App.Attributes

    $Content.Dependencies = @()
    foreach ($Dependency in $Xml.Package.Dependencies.ChildNodes)
    {
        $Attributes = Convert-AttributesToHashtable -Attributes $Dependency.Attributes
        $Attributes.AppId = $Attributes.Id
        $Attributes.Version = $Attributes.MinVersion
        $Attributes.Remove('MinVersion')
        $Attributes.Remove('Id')
        $Content.Dependencies += $Attributes
    }

    $Content
}

function Convert-AttributesToHashtable
{
    param(
        $Attributes
    )

    $Content = @{}
    foreach ($Item in $Attributes)
    {
        $Content[$Item.Name] = $Item.Value
    }
    $Content
}

function Get-Compiler
{
    param(
        $InstanceName = 'AlCompiler'
    )

    $PackageId = 'bc-al-compiler'

    $InstalledPackage = Get-GocInstalledPackage -InstanceName $InstanceName -Id $PackageId
    return $InstalledPackage.Info.CompilerPath
}

function Get-CodeAnalysisPath
{
    $CompilerPath = Get-Compiler
    if ($CompilerPath)
    {
        return Join-Path (Split-Path ($CompilerPath) -Parent) "Microsoft.Dynamics.Nav.CodeAnalysis.dll"
    }
}

function Get-AppJsonFromRuntimeApp
{
    param(
        [Parameter(Mandatory = $true)]
        $Path
    )

    $codeAnalyisPath = Get-CodeAnalysisPath
    if (!$codeAnalyisPath)
    {
        return $null
    }
    Import-Module $codeAnalyisPath
    
    $stream = [System.IO.File]::OpenRead($Path)
    try
    {
        $navAppPackageReader = [Microsoft.Dynamics.Nav.CodeAnalysis.Packaging.NavAppPackageReader]::Create($stream)
        $manifest = $navAppPackageReader.ReadNavAppManifest()
    }
    catch
    {
        Write-Warning "$_"
        return $null
    }
    finally
    {
        $stream.Dispose()
    }
    
    return @{
        Id = $manifest.AppId.ToString()
        Version = $manifest.AppVersion.ToString()
        Name = $manifest.AppName
        Description = $manifest.AppDescription
        Publisher = $manifest.AppPublisher
        Application = $manifest.Application
        Platform = $manifest.Platform
        Dependencies = @($manifest.Dependencies | Foreach-Object {
            @{ 
                AppId = $_.AppId.ToString();
                Version = $_.Version.ToString()
                Name = $_.Name
                Publisher = $_.Publisher
            }
        })
    }
}