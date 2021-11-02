$bootstrapperPackageId = 'DIPS.Buildsystem.Bootstrapper'
$buildsystemCorePackageId = 'DIPS.Buildsystem.Core'
$buildsystemDatabasePackageId = 'DIPS.Buildsystem.DatabaseBuild'
$buildsystemDatamartPackageId = 'DIPS.Buildsystem.DatamartBuild'
$buildsystemDeliveryPackageId = 'DIPS.Buildsystem.Delivery'
$teamExtensionsPackageId = 'DIPS.Buildsystem.TeamExtensions'

$buildsystemVersionsFile = Join-Path $Global:buildDir 'buildsystem-versions.txt'
$localVersionsFile = Join-Path $Global:buildDir 'buildsystem-versions.local'
$bootstrapperVersionFile = Join-Path $Global:bootstrapperDir 'bootstrapper-version.txt'

$scriptCsDependenciesDir = Join-Path $Global:buildDir 'scriptcs_dependencies'
$commonDir = Join-Path $Global:buildDir 'common'
$templatesDir = Join-Path $Global:buildDir 'templates'
$vsCodeDir = Join-Path $Global:rootDir '.vscode'

$sourceName = 'InternalNugetTools'
$additionalSourceNames = @( 'DIPS-3rdParty' )

function Update-Bootstrapper([bool]$restore = $false) {
    $updateBootstrapper = Get-BoolConfigValue -configKey 'updateBootstrapper' -defaultValue $true -warnIfMissing $false
    if (-not $updateBootstrapper) {
        return
    }

    $currentBootstrapperVersion = Get-CurrentVersion -currentVersionFile $bootstrapperVersionFile
    $allowPrerelease = Get-BoolConfigValue -configKey 'allowPrerelease' -defaultValue $false -warnIfMissing $false

    $upgradeVersion = Test-IsUpgradeAvailable -packageId $bootstrapperPackageId -currentVersion $currentBootstrapperVersion -sourceName $sourceName -allowPrerelease $allowPrerelease

    if (-not [string]::IsNullOrEmpty($upgradeVersion) -and -not $restore) {
        Write-Caption "An update is available for the bootstrapper. Current version is $currentBootstrapperVersion, latest version is $upgradeVersion."

        Install-NugetPackage -packageId $bootstrapperPackageId -version $upgradeVersion -sourceName $sourceName -outputDirectory $Global:bootstrapperDir -allowPrerelase:$allowPrerelease -excludeVersion

        $buildsystemBootstrapperDir = Join-Path $Global:bootstrapperDir $bootstrapperPackageId

        $upgradeScriptPath = Join-Path $buildsystemBootstrapperDir 'upgrade-bootstrapper.ps1'

        & $upgradeScriptPath -bootstrapperDir $Global:bootstrapperDir

        Remove-Item -Path $buildsystemBootstrapperDir -Recurse -Force

        Write-VersionToFile -versionFile $bootstrapperVersionFile -version $upgradeVersion

        Add-ToGit -path $bootstrapperVersionFile

        Write-OK "Updated the bootstrapper to version $upgradeVersion."
    }
    else {
        Write-OK "The bootstrapper is up to date: $currentBootstrapperVersion"
    }
}

function Update-Buildsystem([bool]$upgrade = $true, [bool]$init = $false) {
    $useDotnetScript = Get-BoolConfigValue -configKey 'useDotnetScript' -defaultValue $true -warnIfMissing $false
    if ($useDotnetScript -and -not $upgrade) {
        Write-Output $false
        return
    }

    $buildsystemUpdated = $false
    $databaseBuildsystemUpdated = $false
    $datamartBuildsystemUpdated = $false
    $deliveryBuildsystemUpdated = $false
    $teamExtensionsUpdated = $false

    if (-not $useDotnetScript -and (Test-Path $scriptCsDependenciesDir)) {
        Get-ChildItem -Path $scriptCsDependenciesDir -Directory | Remove-Item -Recurse -Force
    }

    $datamartBuild = Get-BoolConfigValue -configKey 'datamartBuild' -defaultValue $false -warnIfMissing $false
    if ($datamartBuild) {
        if ($useDotnetScript) {
            if ($init) {
                Copy-BuildScriptTemplate -datamartBuild $true
            }

            $datamartBuildsystemUpdated = Update-BuildsystemVersion -packageId $buildsystemDatamartPackageId
        }
        else {
            $datamartBuildsystemUpdated = Update-BuildsystemPackage -packageId $buildsystemDatamartPackageId -upgrade $upgrade
        }
    }

    $databaseBuild = Get-BoolConfigValue -configKey 'databaseBuild' -defaultValue $false -warnIfMissing $false
    if ($databaseBuild) {
        if ($useDotnetScript) {
            if ($init) {
                Copy-BuildScriptTemplate -databaseBuild $true
            }

            $databaseBuildsystemUpdated = Update-BuildsystemVersion -packageId $buildsystemDatabasePackageId
        }
        else {
            $databaseBuildsystemUpdated = Update-BuildsystemPackage -packageId $buildsystemDatabasePackageId -upgrade $upgrade
        }
    }

    $deliveryBuild = Get-BoolConfigValue -configKey 'deliveryBuild' -defaultValue $false -warnIfMissing $false
    if ($deliveryBuild) {
        if ($useDotnetScript) {
            if ($init) {
                Copy-BuildScriptTemplate -deliveryBuild $true
            }

            $deliveryBuildsystemUpdated = Update-BuildsystemVersion -packageId $buildsystemDeliveryPackageId
        }
        else {
            throw "The 'deliveryBuild' option only works with dotnet script. Please set 'useDotnetScript=true' in your bootstrapper.config"
        }
    }

    $installTeamExtensions = Get-BoolConfigValue -configKey 'installTeamExtensions' -defaultValue $false -warnIfMissing $false
    if ($installTeamExtensions) {
        if ($useDotnetScript) {
            $teamExtensionsUpdated = Update-BuildsystemVersion -packageId $teamExtensionsPackageId
        }
        else {
            $teamExtensionsUpdated = Update-BuildsystemPackage -packageId $teamExtensionsPackageId -upgrade $upgrade
        }
    }

    if ($useDotnetScript) {
        if ($init -and -not $databaseBuild) {
            Copy-BuildScriptTemplate
        }

        $buildsystemUpdated = Update-BuildsystemVersion -packageId $buildsystemCorePackageId
    }
    else {
        $buildsystemUpdated = Update-BuildsystemPackage -packageId $buildsystemCorePackageId -upgrade $upgrade
    }

    if (-not $useDotnetScript) {
        Copy-BuildsystemFiles | Out-Null
    }
    else {
        Initialize-DotnetScript | Out-Null
    }

    $updated = ($buildsystemUpdated -or $databaseBuildsystemUpdated -or $datamartBuildsystemUpdated -or $deliveryBuildsystemUpdated -or $teamExtensionsUpdated)
    if ($updated) {
        Add-ToGitIgnore -useDotnetScript $useDotnetScript | Out-Null
    }

    if ($updated -and $useDotnetScript) {
        nuget locals http-cache -clear
    }

    Write-Output $updated
}

function Copy-BuildScriptTemplate([bool]$databaseBuild = $false, [bool]$datamartBuild = $false, [bool]$deliveryBuild = $false) {
    $tempDir = Join-Path $Global:buildDir 'temp'
    if ($databaseBuild) {
        Install-NugetPackage -packageId $buildsystemDatabasePackageId -sourceName $sourceName -additionalSourceNames $additionalSourceNames -outputDirectory $tempDir -allowPrerelease:$false -throwOnerror -excludeVersion

        $packagePath = Join-Path $tempDir $buildsystemDatabasePackageId
        $templatesPath = Join-Path $packagePath 'dotnetscript-templates'
        $scriptsPath = Join-Path $packagePath 'scripts'
        $buildScriptTemplateSourcePath = Join-Path $templatesPath 'databasebuild.csx'
        $buildScriptTemplateDestinationPath = Join-Path $Global:buildDir 'databasebuild.csx'

        $buildwindowBatSourcePath = Join-Path $templatesPath 'dbbuildwindow.bat'
        $buildwindowShSourcePath = Join-Path $templatesPath 'dbbuildwindow.sh'
        $buildwindowBatDestinationPath = Join-Path $Global:rootDir 'dbbuildwindow.bat'
        $buildwindowShDestinationPath = Join-Path $Global:rootDir 'dbbuildwindow.sh'
    }
    elseif ($datamartBuild) {
        Install-NugetPackage -packageId $buildsystemDatamartPackageId -sourceName $sourceName -additionalSourceNames $additionalSourceNames -outputDirectory $tempDir -allowPrerelease:$false -throwOnerror -excludeVersion

        $packagePath = Join-Path $tempDir $buildsystemDatamartPackageId
        $templatesPath = Join-Path $packagePath 'dotnetscript-templates'
        $scriptsPath = Join-Path $packagePath 'scripts'
        $buildScriptTemplateSourcePath = Join-Path $templatesPath 'datamartbuild.csx'
        $buildScriptTemplateDestinationPath = Join-Path $Global:buildDir 'datamartbuild.csx'
    }
    elseif ($deliveryBuild) {
        Install-NugetPackage -packageId $buildsystemDeliveryPackageId -sourceName $sourceName -additionalSourceNames $additionalSourceNames -outputDirectory $tempDir -allowPrerelease:$false -throwOnerror -excludeVersion

        $packagePath = Join-Path $tempDir $buildsystemDeliveryPackageId
        $templatesPath = Join-Path $packagePath 'dotnetscript-templates'
        $scriptsPath = Join-Path $packagePath 'scripts'
        $buildScriptTemplateSourcePath = Join-Path $templatesPath 'build.csx'
        $buildScriptTemplateDestinationPath = Join-Path $Global:buildDir 'build.csx'
    }
    else {
        Install-NugetPackage -packageId $buildsystemCorePackageId -sourceName $sourceName -additionalSourceNames $additionalSourceNames -outputDirectory $tempDir -allowPrerelease:$false -throwOnerror -excludeVersion

        $packagePath = Join-Path $tempDir $buildsystemCorePackageId
        $templatesPath = Join-Path $packagePath 'dotnetscript-templates'
        $scriptsPath = Join-Path $packagePath 'scripts'
        $buildScriptTemplateSourcePath = Join-Path $templatesPath 'build.csx'
        $buildScriptTemplateDestinationPath = Join-Path $Global:buildDir 'build.csx'

        $buildwindowBatSourcePath = Join-Path $templatesPath 'buildwindow.bat'
        $buildwindowShSourcePath = Join-Path $templatesPath 'buildwindow.sh'
        $buildwindowBatDestinationPath = Join-Path $Global:rootDir 'buildwindow.bat'
        $buildwindowShDestinationPath = Join-Path $Global:rootDir 'buildwindow.sh'
    }

    $nugetConfigSourcePath = Join-Path $templatesPath 'nuget.config'
    $nugetConfigDestinationPath = Join-Path $Global:rootDir 'nuget.config'

    if ((Test-Path $buildScriptTemplateSourcePath) -and -not (Test-Path $buildScriptTemplateDestinationPath)) {
        Copy-Item -Path $buildScriptTemplateSourcePath -Destination $buildScriptTemplateDestinationPath

        Add-ToGit -path $buildScriptTemplateDestinationPath
    }

    if ((Test-Path $nugetConfigSourcePath) -and -not (Test-Path $nugetConfigDestinationPath)) {
        Copy-Item -Path $nugetConfigSourcePath -Destination $nugetConfigDestinationPath

        Add-ToGit -path $nugetConfigDestinationPath
    }

    if (-not [string]::IsNullOrWhiteSpace($buildwindowBatSourcePath) -and (Test-Path $buildwindowBatSourcePath) -and -not (Test-Path $buildwindowBatDestinationPath)) {
        Copy-Item -Path $buildwindowBatSourcePath -Destination $buildwindowBatDestinationPath

        Add-ToGit -path $buildwindowBatDestinationPath
    }

    if (-not [string]::IsNullOrWhiteSpace($buildwindowShSourcePath) -and (Test-Path $buildwindowShSourcePath) -and -not (Test-Path $buildwindowShDestinationPath)) {
        Copy-Item -Path $buildwindowShSourcePath -Destination $buildwindowShDestinationPath

        Add-ToGit -path $buildwindowShDestinationPath
    }

    if (-not [string]::IsNullOrWhiteSpace($scriptsPath) -and (Test-Path $scriptsPath)) {
        $scripts = Get-ChildItem -Path $scriptsPath
        foreach ($script in $scripts) {
            $fileName = [IO.Path]::GetFileName($script.FullName)
            $destinationPath = Join-Path $Global:rootDir $fileName
            if (-not (Test-Path $destinationPath)) {
                Copy-Item -Path $script.FullName -Destination $destinationPath
            }
        }
    }

    Remove-Item -Path $tempDir -Recurse -Force
}

function Initialize-DotnetScript {
    if (Test-Path $vsCodeDir) {
        return
    }

    $previousLocation = Get-Location
    Set-Location $Global:rootDir

    dotnet-script init

    $defaultScriptPath = Join-Path $Global:rootDir 'main.csx'
    if (Test-Path $defaultScriptPath) {
        Remove-Item -Path $defaultScriptPath
    }

    Add-ToGit -path (Join-Path $Global:rootDir 'omnisharp.json')

    Set-Location $previousLocation
}

function Get-CurrentVersionFromCsxFile([string]$csxPath, [string]$packageId) {
    $escapedPackageId = [Regex]::Escape($packageId)

    $csxContent = Get-Content -Path $csxPath -Raw
    $packageVersionRegexPattern = "#r `"nuget:[\s]*$escapedPackageId,[\s]*(.+?)`""
    $versionMatch = [Regex]::Match($csxContent, $packageVersionRegexPattern)
    if (-not $versionMatch.Success) {
        Write-Verbose "Found no reference to '$packageId' in '$csxPath'."
        return
    }

    Write-Output $versionMatch.Groups[1].Value
}

function Update-BuildsystemVersion([string]$packageId) {
    $allowPrerelease = Get-BoolConfigValue -configKey 'allowPrerelease' -defaultValue $false -warnIfMissing $false
    $scriptName = Get-ConfigValue -configKey 'scriptName' -defaultValue '' -warnIfMissing $false

    if ([string]::IsNullOrWhiteSpace($scriptName)) {
        $csxFiles = Get-ChildItem -File -Path $Global:buildDir -Filter '*.csx' | Select-Object -Property 'FullName' -ExpandProperty 'FullName'
    }
    else {
        $csxFiles = @( (Join-Path $Global:buildDir $scriptName) )
    }

    $lowestCurrentVersion = '0.0.0'
    $csxFilesWithReference = [System.Collections.ArrayList]@()
    foreach ($filePath in $csxFiles) {
        $currentVersion = Get-CurrentVersionFromCsxFile -csxPath $filePath -packageId $packageId
        if ([string]::IsNullOrWhiteSpace($currentVersion)) {
            continue
        }

        $csxFilesWithReference.Add($filePath) | Out-Null

        $comparison = Compare-Versions -firstVersion $lowestCurrentVersion -secondVersion $currentVersion
        if ($comparison -eq -1) {
            $lowestCurrentVersion = $currentVersion
        }
    }

    if ($csxFilesWithReference.Count -eq 0) {
        Write-Warning "Found no reference to '$packageId' in any of the discovered .csx files."
        Write-Output $false
        return
    }

    $latestVersion = Test-IsUpgradeAvailable -packageId $packageId -currentVersion $lowestCurrentVersion -sourceName $sourceName -allowPrerelease $allowPrerelease -throwOnerror

    if ($null -ne $latestVersion -and $lowestCurrentVersion -ne $latestVersion) {
        Write-Caption "Updating '$packageId' to version '$latestVersion'..."

        foreach ($filePath in $csxFilesWithReference) {
            $escapedPackageId = [Regex]::Escape($packageId)
            $escapedVersion = [Regex]::Escape($lowestCurrentVersion)

            $csxContent = Get-Content -Path $filePath -Raw
            $replacementRegexPattern = "$escapedPackageId,[\s]*$escapedVersion"
            $replacementValue = "$packageId, $latestVersion"
            $csxContent = $csxContent -replace $replacementRegexPattern, $replacementValue

            Set-Content -Path $filePath -Value $csxContent | Out-Null

            Add-ToGit -path $filePath | Out-Null
        }

        Write-Output $true
    }
    else {
        Write-Ok "$packageId is up to date: $lowestCurrentVersion"

        Write-Output $false
    }
}

function Update-BuildsystemPackage([string]$packageId, [bool]$upgrade = $false) {
    $framework = 'net48'

    if (-not (Test-Path $scriptCsDependenciesDir)) {
        New-Item $scriptCsDependenciesDir -ItemType 'Directory'
    }

    if (Test-Path $buildsystemVersionsFile) {
        $currentVersion = Get-CurrentVersion -currentVersionFile $buildsystemVersionsFile -key $packageId
    }
    else {
        $currentVersion = ''
    }

    $allowPrerelease = Get-BoolConfigValue -configKey 'allowPrerelease' -defaultValue $false -warnIfMissing $false

    $shouldRestore = Test-ShouldRestoreBuildsystemPackage -packageId $packageId -currentVersion $currentVersion
    if ($shouldRestore -and -not $upgrade) {
        Write-Host "Restoring '$packageId' to version '$currentVersion'..."

        Install-NugetPackage -packageId $packageId -sourceName $sourceName -additionalSourceNames $additionalSourceNames -version $currentVersion -outputDirectory $scriptCsDependenciesDir -framework $framework -allowPrerelease:$allowPrerelease -throwOnerror

        Write-VersionToFile -versionFile $localVersionsFile -key $packageId -version $currentVersion

        Write-Output $true
        return
    }
    elseif (-not $upgrade) {
        Write-Ok "$packageId is up to date: $currentVersion"

        Write-Output $false
        return
    }

    $latestVersion = Test-IsUpgradeAvailable -packageId $packageId -currentVersion $currentVersion -sourceName $sourceName -allowPrerelease $allowPrerelease -throwOnerror

    if ($null -ne $latestVersion -and $currentVersion -ne $latestVersion) {
        Write-Host "Updating '$packageId' to version '$latestVersion'..."

        Install-NugetPackage -packageId $packageId -sourceName $sourceName -additionalSourceNames $additionalSourceNames -version $latestVersion -outputDirectory $scriptCsDependenciesDir -framework $framework -allowPrerelease:$allowPrerelease -throwOnerror

        Remove-OldNugetVersions -packageId $packageID -currentVersion $latestVersion -sourceDirectory $scriptCsDependenciesDir

        Write-VersionToFile -versionFile $buildsystemVersionsFile -key $packageId -version $latestVersion
        Write-VersionToFile -versionFile $localVersionsFile -key $packageId -version $latestVersion

        Add-ToGit -path $buildsystemVersionsFile

        Write-Ok "Updated '$packageId' to version '$latestVersion'."

        Write-Output $true
    }
    elseif ($shouldRestore) {
        Write-Host "Restoring '$packageId' to version '$currentVersion'..."

        Install-NugetPackage -packageId $packageId -sourceName $sourceName -additionalSourceNames $additionalSourceNames -version $currentVersion -outputDirectory $scriptCsDependenciesDir -framework $framework -allowPrerelease:$allowPrerelease -throwOnerror

        Write-VersionToFile -versionFile $localVersionsFile -key $packageId -version $currentVersion

        Write-Output $true
        return
    }
    else {
        Write-Ok "$packageId is up to date: $currentVersion"

        Write-Output $false
    }
}

function Test-IsUpgradeAvailable(
    [string]$packageId,
    [string]$currentVersion,
    [string]$sourceName = 'InternalNugetTools',
    [bool]$allowPrerelease = $false) {
    $upgradeMajor = Get-BoolConfigValue -configKey 'upgradeMajor' -defaultValue $false -warnIfMissing $false

    $latestVersion = Get-LatestVersionOfPackage -packageId $packageId -sourceName $sourceName -allowPrerelease $allowPrerelease

    if ([string]::IsNullOrWhiteSpace($latestVersion)) {
        throw "Unable to find latest version of '$pacakgeId' in '$sourceName'"
    }

    if ([String]::IsNullOrWhiteSpace($currentVersion)) {
        Write-Output $latestVersion
        return
    }

    $current = ConvertTo-ComparableVersion $currentVersion
    $latest = ConvertTo-ComparableVersion $latestVersion

    if (-not $upgradeMajor -and $latest['MAJOR'] -gt $current['MAJOR']) {
        Write-Warning "A new MAJOR version exists for package $packageId, but upgradeMajor is $upgradeMajor."

        $allVersions = Get-AllVersionsOfPackage -packageId $packageId -sourceName $sourceName -allowPrerelease $allowPrerelease

        $matchingMajorVersions = $allVersions | Where-Object { (ConvertTo-ComparableVersion $_)['MAJOR'] -eq $current['MAJOR'] }
        if ($matchingMajorVersions.Count -gt 0) {
            $latestVersion = Get-HighestVersion $matchingMajorVersions
            $latest = ConvertTo-ComparableVersion $latestVersion
        }
        else {
            Write-Host "Found no newer version for package $packageId within the current MAJOR version."
            Write-Output $null
            return
        }
    }

    $comparison = Compare-Versions -firstVersion $latestVersion -secondVersion $currentVersion
    if ($comparison -eq 1) {
        Write-Output $latestVersion
    }
    else {
        Write-Output $null
    }
}

function Test-ShouldRestoreBuildsystemPackage([string]$packageId, [string]$currentVersion) {
    if ([string]::IsNullOrWhiteSpace($currentVersion)) {
        Write-Output $false
        return
    }

    $dllPath = Join-Path $scriptCsDependenciesDir "$packageId.dll"
    if (-not (Test-Path $dllPath)) {
        Write-Output $true
        return
    }

    $alwaysRestore = Get-BoolConfigValue -configKey 'alwaysRestore' -defaultValue $false -warnIfMissing $false
    if ($alwaysRestore) {
        Write-Output $true
        return
    }

    if (-not (Test-Path $localVersionsFile)) {
        Write-Output $true
        return
    }

    $localPackageVersion = Get-CurrentVersion -currentVersionFile $localVersionsFile -key $packageId
    $comparison = Compare-Versions -firstVersion $currentVersion -secondVersion $localPackageVersion
    if ($comparison -ne 0) {
        Write-Output $true
    }
    else {
        Write-Output $false
    }
}

function Copy-BuildsystemFiles {
    $copyTemplates = Get-BoolConfigValue -configKey 'copyTemplates' -defaultValue $true -warnIfMissing $false
    $updateScripts = Get-BoolConfigValue -configKey 'updateScripts' -defaultValue $true -warnIfMissing $false

    $installedPackages = Get-ChildItem -Path $scriptCsDependenciesDir -Directory
    foreach ($installedPackage in $installedPackages) {
        $packageDir = Join-Path $scriptCsDependenciesDir $installedPackage

        $libDir = Find-LibDir -packageDir $packageDir
        if ($null -ne $libDir) {
            Get-ChildItem -Path $libDir -Filter '*.dll' | Copy-Item -Destination "$scriptCsDependenciesDir/" -Force
        }

        $scriptCsDir = Join-Path $packageDir 'scriptcs'
        if (Test-Path $scriptCsDir) {
            if (-not (Test-Path $commonDir)) {
                New-Item -Path $commonDir -ItemType 'Directory'
            }

            Get-ChildItem -Path $scriptCsDir -Filter '*' | Copy-Item -Destination "$commonDir/" -Force
        }

        $scriptCsTemplatesDir = Join-Path $packageDir 'scriptcs-templates'
        if ((Test-Path $scriptCsTemplatesDir) -and $copyTemplates) {
            if (-not (Test-Path $templatesDir)) {
                New-Item -Path $templatesDir -ItemType 'Directory'
            }

            Get-ChildItem -Path $scriptCsTemplatesDir -Filter '*' | Copy-Item -Destination "$templatesDir/" -Force
        }

        $scriptsDir = Join-Path $packageDir 'scripts'
        if ((Test-Path $scriptsDir) -and $updateScripts) {
            $scriptFiles = Get-ChildItem -Path $scriptsDir -Filter '*'
            foreach ($scriptFile in $scriptFiles) {
                Copy-Item -Path $scriptFile.FullName -Destination "$Global:rootDir/" -Force
                Add-ToGit -path (Join-Path $Global:rootDir $scriptFile.Name)
            }
        }
    }
}

function Find-LibDir([string]$packageDir) {
    $libDir = Join-Path $packageDir 'lib'

    $netFrameworks = Get-ChildItem -Path $libDir -Directory | Where-Object { $_.Name.StartsWith('net4') }
    $netStandardFrameworks = Get-ChildItem -Path $libDir -Directory | Where-Object { $_.Name.StartsWith('netstandard') }

    $net48Dir = Join-Path $libDir 'net48'
    if (Test-Path $net48Dir) {
        Write-Debug 'Using dlls from net48'

        Write-Output $net48Dir
        return
    }

    if ($null -ne $netStandardFrameworks) {
        $latestNetStandardFramework = $netStandardFrameworks | Sort-Object -Descending | Select-Object -First 1
        $latestNetStandardFrameworkDir = Join-Path $libDir $latestNetStandardFramework
        Write-Debug "Using dlls from $latestNetStandardFramework"
        Write-Output $latestNetStandardFrameworkDir
        return
    }

    if ($null -ne $netFrameworks) {
        $latestNetFramework = $netFrameworks | Sort-Object -Descending | Select-Object -First 1
        $latestNetFrameworkDir = Join-Path $libDir $latestNetFramework

        Write-Debug "Using dlls from $latestNetFramework"

        Write-Output $latestNetFrameworkDir
    }

    Write-Debug "Found no compatible frameworks in '$libDir', skipping..."
    Write-Output $null
    return
}

function Get-CurrentVersion([string]$currentVersionFile, [string]$key) {
    $currentVersion = ''
    if (Test-Path $currentVersionFile) {
        if ([string]::IsNullOrWhiteSpace($key)) {
            $currentVersion = [IO.File]::ReadAllText($currentVersionFile)
        }
        else {
            $versions = [IO.File]::ReadAllLines($currentVersionFile)
            foreach ($line in $versions) {
                if ($line.StartsWith($key)) {
                    $currentVersion = $line -replace "$key=", ''
                    break
                }
            }
        }
    }

    Write-Output $currentVersion
}

function Write-VersionToFile([string]$versionFile, [string]$key, [string]$version) {
    Write-Debug "Writing version $version to $versionFile..."

    if ([string]::IsNullOrWhiteSpace($key)) {
        [IO.File]::WriteAllText([string]$versionFile, [string]$version) | Out-Null
    }
    elseif (-not (Test-Path $versionFile)) {
        [IO.File]::WriteAllText([string]$versionFile, "$key=$version") | Out-Null
    }
    else {
        $found = $false
        $newLines = [System.Collections.ArrayList]@()
        $currentVersions = [IO.File]::ReadAllLines($versionFile)
        foreach ($line in $currentVersions) {
            if ($line.StartsWith($key)) {
                $newLines.Add("$key=$version") | Out-Null
                $found = $true
            }
            else {
                $newLines.Add($line) | Out-Null
            }
        }

        if (-not $found) {
            $newLines.Add("$key=$version") | Out-Null
        }

        [IO.File]::WriteAllLines($versionFile, $newLines) | Out-Null
    }
}

function Add-ToGitIgnore([bool]$useDotnetScript) {
    $gitIgnorePath = Join-Path $Global:rootDir '.gitignore'
    if (Test-Path $gitIgnorePath) {
        $gitIgnoreContent = [IO.File]::ReadAllText($gitIgnorePath)
    }
    else {
        $gitIgnoreContent = ''
    }

    if (-not $useDotnetScript) {
        $gitIgnoreContent = Add-GitIgnoreLine -gitIgnoreContent $gitIgnoreContent -line 'build/common/'
        $gitIgnoreContent = Add-GitIgnoreLine -gitIgnoreContent $gitIgnoreContent -line 'build/scriptcs_packages/'
        $gitIgnoreContent = Add-GitIgnoreLine -gitIgnoreContent $gitIgnoreContent -line 'build/scriptcs_dependencies/'
        $gitIgnoreContent = Add-GitIgnoreLine -gitIgnoreContent $gitIgnoreContent -line 'build/templates/'
        $gitIgnoreContent = Add-GitIgnoreLine -gitIgnoreContent $gitIgnoreContent -line 'build/buildsystem-versions.local'
    }
    else {
        $gitIgnoreContent = Add-GitIgnoreLine -gitIgnoreContent $gitIgnoreContent -line '.vscode/'
    }

    $gitIgnoreContent = Add-GitIgnoreLine -gitIgnoreContent $gitIgnoreContent -line 'build/bootstrapper/upgrade-bootstrapper.ps1'

    [IO.File]::WriteAllText($gitIgnorePath, $gitIgnoreContent)

    Add-ToGit -path $gitIgnorePath
}

function Add-GitIgnoreLine([string]$gitIgnoreContent, [string]$line) {
    $escapedLine = [Regex]::Escape($line)
    if ($gitIgnoreContent -match "$escapedLine[\s]?[\r]?[\n]{1}") {
        Write-Verbose "Already present in .gitignore: '$line'"
        Write-Output $gitIgnoreContent
        return
    }

    Write-Verbose "Adding the following to .gitignore: '$line'"

    $newContent = "$gitIgnoreContent`n$line"
    Write-Output $newContent
}

function Add-ToGit([string]$path) {
    & git add -f $path
}