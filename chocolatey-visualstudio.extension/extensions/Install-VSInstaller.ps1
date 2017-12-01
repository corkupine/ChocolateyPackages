function Install-VSInstaller
{
    [CmdletBinding()]
    param(
      [Parameter(Mandatory = $true)] [string] $PackageName,
      [Parameter(Mandatory = $true)] [hashtable] $PackageParameters,
      [PSObject] $ProductReference,
      [string] $Url,
      [string] $Checksum,
      [string] $ChecksumType,
      [Alias('RequiredVersion')] [version] $RequiredInstallerVersion,
      [version] $RequiredEngineVersion,
      [switch] $Force
    )
    Write-Debug "Running 'Install-VSInstaller' for $PackageName with Url:'$Url' Checksum:$Checksum ChecksumType:$ChecksumType RequiredInstallerVersion:'$RequiredInstallerVersion' RequiredEngineVersion:'$RequiredEngineVersion' Force:'$Force'";

    Write-Debug 'Determining whether the Visual Studio Installer needs to be installed/updated/reinstalled'
    $shouldUpdate = $false
    $existing = Get-VisualStudioInstaller
    if ($existing -ne $null)
    {
        Write-Debug 'The Visual Studio Installer is already present'
        if ($existing.Version -ne $null -and $RequiredInstallerVersion -ne $null)
        {
            if ($existing.Version -lt $RequiredInstallerVersion)
            {
                Write-Debug 'The existing Visual Studio Installer version is lower than requested, so it should be updated'
                $shouldUpdate = $true
            }
            elseif ($existing.Version -eq $RequiredInstallerVersion)
            {
                Write-Debug 'The existing Visual Studio Installer version is equal to requested (no update required)'
            }
            else
            {
                Write-Debug 'The existing Visual Studio Installer version is greater than requested (no update required)'
            }
        }

        if ($existing.EngineVersion -ne $null -and $RequiredEngineVersion -ne $null)
        {
            if ($existing.EngineVersion -lt $RequiredEngineVersion)
            {
                Write-Debug 'The existing Visual Studio Installer engine version is lower than requested, so it should be updated'
                $shouldUpdate = $true
            }
            elseif ($existing.EngineVersion -eq $RequiredEngineVersion)
            {
                Write-Debug 'The existing Visual Studio Installer engine version is equal to requested (no update required)'
            }
            else
            {
                Write-Debug 'The existing Visual Studio Installer engine version is greater than requested (no update required)'
            }
        }
    }
    else
    {
        Write-Debug 'The Visual Studio Installer is not present and will be installed'
        $shouldUpdate = $true
    }

    $attemptingRepair = $false
    if (-not $shouldUpdate)
    {
        $existingHealth = $existing | Get-VisualStudioInstallerHealth
        if ($existingHealth -ne $null -and -not $existingHealth.IsHealthy)
        {
            Write-Warning "The Visual Studio Installer is broken (missing files: $($existingHealth.MissingFiles -join ', ')). Attempting to reinstall it."
            $shouldUpdate = $true
            $attemptingRepair = $true
        }
    }

    if (-not $shouldUpdate -and $Force)
    {
        Write-Debug 'The Visual Studio Installer does not need to be updated, but it will be reinstalled because -Force was used'
        $shouldUpdate = $true
    }

    if (-not $shouldUpdate)
    {
        return
    }

    if ($packageParameters.ContainsKey('bootstrapperPath'))
    {
        $installerFilePath = $packageParameters['bootstrapperPath']
        $packageParameters.Remove('bootstrapperPath')
        Write-Debug "User-provided bootstrapper path: $installerFilePath"
    }
    else
    {
        $installerFilePath = $null
        if ($Url -eq '')
        {
            $Url, $Checksum, $ChecksumType = Get-VSBootstrapperUrlFromChannelManifest -PackageParameters $PackageParameters -ProductReference $ProductReference
        }
    }

    $whitelist = @('quiet', 'offline')
    $parametersToRemove = $PackageParameters.Keys | Where-Object { $whitelist -notcontains $_ }
    foreach ($parameterToRemove in $parametersToRemove)
    {
        Write-Debug "Filtering out package parameter not passed to the bootstrapper during VS Installer update: '$parameterToRemove'"
        $PackageParameters.Remove($parameterToRemove)
    }

    # if installing from layout, check for existence of vs_installer.opc and auto add --offline
    if (-not $packageParameters.ContainsKey('offline'))
    {
        $layoutPath = Resolve-VSLayoutPath -PackageParameters $PackageParameters
        if ($layoutPath -ne $null)
        {
            $installerOpcPath = Join-Path -Path $layoutPath -ChildPath 'vs_installer.opc'
            if (Test-Path -Path $installerOpcPath)
            {
                Write-Debug "Using the VS Installer package present in the layout path: $installerOpcPath"
                $packageParameters['offline'] = $installerOpcPath
            }
        }
    }

    # --update must be last
    $packageParameters['quiet'] = $null
    $silentArgs = ConvertTo-ArgumentString -Arguments $packageParameters -FinalUnstructuredArguments @('--update') -Syntax 'Willow'
    $arguments = @{
        packageName = 'Visual Studio Installer'
        silentArgs = $silentArgs
        url = $Url
        checksum = $Checksum
        checksumType = $ChecksumType
        logFilePath = $null
        assumeNewVS2017Installer = $true
        installerFilePath = $installerFilePath
    }
    $argumentsDump = ($arguments.GetEnumerator() | ForEach-Object { '-{0}:''{1}''' -f $_.Key,"$($_.Value)" }) -join ' '

    $attempt = 0
    do
    {
        $retry = $false
        $attempt += 1
        Write-Debug "Install-VSChocolateyPackage $argumentsDump"
        Install-VSChocolateyPackage @arguments

        $updated = Get-VisualStudioInstaller
        if ($updated -eq $null)
        {
            throw 'The Visual Studio Installer is not present even after supposedly successful update!'
        }

        if ($existing -eq $null)
        {
            Write-Verbose "The Visual Studio Installer version $($updated.Version) (engine version $($updated.EngineVersion)) was installed."
        }
        else
        {
            if ($updated.Version -eq $existing.Version -and $updated.EngineVersion -eq $existing.EngineVersion)
            {
                Write-Verbose "The Visual Studio Installer version $($updated.Version) (engine version $($updated.EngineVersion)) was reinstalled."
            }
            else
            {
                if ($updated.Version -lt $existing.Version)
                {
                    Write-Warning "The Visual Studio Installer got updated, but its version after update ($($updated.Version)) is lower than the version before update ($($existing.Version))."
                }
                else
                {
                    if ($updated.EngineVersion -lt $existing.EngineVersion)
                    {
                        Write-Warning "The Visual Studio Installer got updated, but its engine version after update ($($updated.EngineVersion)) is lower than the engine version before update ($($existing.EngineVersion))."
                    }
                    else
                    {
                        Write-Verbose "The Visual Studio Installer got updated to version $($updated.Version) (engine version $($updated.EngineVersion))."
                    }
                }
            }
        }

        if ($updated.Version -ne $null)
        {
            if ($RequiredInstallerVersion -ne $null)
            {
                if ($updated.Version -lt $RequiredInstallerVersion)
                {
                    Write-Warning "The Visual Studio Installer got updated to version $($updated.Version), which is still lower than the requirement of version $RequiredInstallerVersion or later."
                }
                else
                {
                    Write-Verbose "The Visual Studio Installer got updated to version $($updated.Version), which satisfies the requirement of version $RequiredInstallerVersion or later."
                }
            }
        }
        else
        {
            Write-Warning "Unable to determine the Visual Studio Installer version after the update."
        }

        if ($updated.EngineVersion -ne $null)
        {
            if ($RequiredEngineVersion -ne $null)
            {
                if ($updated.EngineVersion -lt $RequiredEngineVersion)
                {
                    Write-Warning "The Visual Studio Installer engine got updated to version $($updated.EngineVersion), which is still lower than the requirement of version $RequiredEngineVersion or later."
                }
                else
                {
                    Write-Verbose "The Visual Studio Installer engine got updated to version $($updated.EngineVersion), which satisfies the requirement of version $RequiredEngineVersion or later."
                }
            }
        }
        else
        {
            Write-Warning "Unable to determine the Visual Studio Installer engine version after the update."
        }

        $updatedHealth = $updated | Get-VisualStudioInstallerHealth
        if (-not $updatedHealth.IsHealthy)
        {
            if ($attempt -eq 1)
            {
                if ($attemptingRepair)
                {
                    $msg = 'is still broken after reinstall'
                }
                else
                {
                    $msg = 'got broken after update'
                }

                Write-Warning "The Visual Studio Installer $msg (missing files: $($updatedHealth.MissingFiles -join ', ')). Attempting to repair it."
                $installerDir = Split-Path -Path $updated.Path
                $newName = '{0}.backup-{1:yyyyMMddHHmmss}' -f (Split-Path -Leaf -Path $installerDir), (Get-Date)
                Write-Verbose "Renaming directory '$installerDir' to '$newName'"
                Rename-Item -Path $installerDir -NewName $newName
                Write-Verbose 'Retrying the installation'
                $retry = $true
            }
            else
            {
                throw "The Visual Studio Installer is still broken even after the attempt to repair it."
            }
        }
        else
        {
            Write-Verbose 'The Visual Studio Installer is healthy (no missing files).'
        }
    }
    while ($retry)
}
