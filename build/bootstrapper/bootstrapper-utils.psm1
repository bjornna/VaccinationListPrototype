$bootstrapperConfigFile = Join-Path $Global:bootstrapperDir 'bootstrapper.config'

function Write-OK([string]$message) {
    Write-Host $message -ForegroundColor 'Green'
}

function Write-Caption([string]$message) {
    Write-Host $message -ForegroundColor 'Cyan'
}

function Assert-RunningAsAdmin {
    If (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] 'Administrator')) {
        Write-Output $false
    }
    else {
        Write-Output $true
    }
}

function Start-ProcessAsAdmin($processName, $arguments) {
    Start-Process -FilePath $processName -Verb runAs -ArgumentList $arguments -Wait
}

function Get-DomainName {
    $slBuild = Get-BoolConfigValue -configKey 'slBuild' -defaultValue $false -warnIfMissing $false
    if ($slBuild) {
        Write-Output 'creativesoftware.com'
        return
    }

    if ($PSVersionTable.PSVersion.Major -lt 7) {
        Write-Output (Get-WmiObject Win32_ComputerSystem).Domain
        return
    }

    Write-Output ($env:USERDNSDOMAIN).ToLower()
}

function Assert-IsSLDomain([string]$domainName) {
    $domainNameLower = $domainName.ToLower()
    Write-Output ($domainNameLower -eq 'creativesoftware.com' -or $domainNameLower -eq 'dipscloud.com')
}

function Get-NugetBaseUrl {
    $domainName = Get-DomainName
    if (Assert-IsSLDomain $domainName) {
        Write-Output 'https://artifacts.creativesoftware.com/api'
    }
    else {
        Write-Output 'https://artifacts.dips.local/api'
    }
}

function Get-NugetSourceUrl([string]$sourceName) {
    if ([string]::IsNullOrWhiteSpace($sourceName)) {
        throw "Source name not set, unable to determine NuGet source URL."
    }

    $nugetBaseUrl = Get-NugetBaseUrl

    Write-Output "$nugetBaseUrl/nuget/$sourceName"
}

function Get-VersionFromNuspec([string]$nuspecPath) {
    [xml]$nuspecXml = Get-Content -Path $nuspecPath
    $versionNode = $nuspecXml.SelectSingleNode("/*[local-name()='package']/*[local-name()='metadata']/*[local-name()='version']");
    if ($null -eq $versionNode) {
        Write-Output $null
        return
    }

    Write-Output $versionNode.InnerText
}

function Install-ChocoPackage([string]$packageId, [string]$version, [string]$sourceName = 'ExternalSoftware') {
    if ($global:installedPackages.contains($packageId)) {
        $installed_version = $Global:installedPackages[$packageId]
        Write-OK "$packageId is installed: $installed_version"
        return
    }

    if (Test-IsBuildServer) {
        Write-Warning "$packageId $version is not installed, but skipping install because we're running on a build server. Please ensure this package is installed with Ansible."
        return
    }

    Write-Caption "Installing $packageId"
    $source = Get-NugetSourceUrl -sourceName $sourceName

    if (Assert-RunningAsAdmin) {
        $command = "choco install $packageId --source $source --confirm --no-progress --prerelease"
        if (-not [string]::IsNullOrWhiteSpace($version)) {
            $command = "$command --version $version"
        }

        Invoke-Expression $command
    }
    else {
        $arguments = "install $packageId --source $source --confirm --no-progress --prerelease"
        if (-not [string]::IsNullOrWhiteSpace($version)) {
            $arguments = "$arguments --version $version"
        }

        Start-ProcessAsAdmin -processName 'choco' -arguments $arguments
    }

    Update-InstallSummaryMap -packageType 'choco' -packageId $packageId -exitcode $LASTEXITCODE

    Write-OK "Installed $packageId $version."
}

function Install-NugetPackage(
    [string]$packageId,
    [string]$version = "",
    [string]$sourceName = 'DIPS-Nuget',
    [array]$additionalSourceNames = $null,
    [string]$outputDirectory,
    [string]$framework = "",
    [switch]$allowPrerelease,
    [switch]$excludeVersion,
    [switch]$throwOnError) {
    $source = Get-NugetSourceUrl -sourceName $sourceName

    if ($null -ne $additionalSourceNames) {
        foreach ($additionalSourceName in $additionalSourceNames) {
            $additionalSource = Get-NugetSourceUrl -sourceName $additionalSourceName
            $source = "$source;$additionalSource"
        }
    }

    $command = "nuget install $packageId -Source '$source' -OutputDirectory '$outputDirectory' -NoCache -NonInteractive"

    if (-not [string]::IsNullOrWhiteSpace($version)) {
        $command = "$command -Version $version"
    }

    if (-not [string]::IsNullOrWhiteSpace($framework)) {
        $command = "$command -Framework $framework"
    }

    if ($excludeVersion.IsPresent) {
        $command = "$command -ExcludeVersion"
    }

    if ($allowPrerelease.IsPresent) {
        $command = "$command -PreRelease"
    }

    Invoke-Expression -Command $command

    if ($LASTEXITCODE -and $throwOnError.IsPresent) {
        throw "Failed to install $packageId $version from $source"
    }

    Update-InstallSummaryMap -packageType 'nuget' -packageId $packageId -exitcode $LASTEXITCODE
}

function Update-NugetPackage([string]$packageId, [string]$sourceName, [string]$currentVersion, [string]$outputDirectory, [string]$framework = "", [switch]$allowPrerelease) {
    $latestVersion = Get-LatestVersionOfPackage -packageId $packageId -sourceName $sourceName -allowPrerelease $allowPrerelease

    if ($currentVersion -eq $latestVersion) {
        Write-Ok "$packageId is up to date: $currentVersion"
        return
    }

    $source = Get-NugetSourceUrl -sourceName $sourceName
    $command = "nuget install $packageId -Source '$source' -Version $latestVersion -OutputDirectory '$outputDir' -PackageSaveMode 'nuspec;nupkg' -NoCache -NonInteractive"
    if (-not [string]::IsNullOrWhiteSpace($framework)) {
        $command = "$command -Framework $framework"
    }

    if ($allowPrerelease.IsPresent) {
        $command = "$command -PreRelease"
    }

    Invoke-Expression -Command $command
}

function Remove-OldNugetVersions([string]$packageId, [string]$currentVersion, [string]$sourceDirectory) {
    $matchingPackages = Get-ChildItem -Path $sourceDirectory -Filter "$packageId.*"
    if ($null -eq $matchingPackages) {
        return
    }

    foreach ($matchingPackage in $matchingPackages) {
        if ($matchingPackage.Name -like "$packageId.$currentVersion") {
            continue
        }

        if ($matchingPackage.Name.EndsWith('.nupkg') -or $matchingPackage.Name.EndsWith('.dll')) {
            continue
        }

        Remove-Item -Path $matchingPackage.FullName -Recurse -Force
    }
}

function Update-ChocoPackage([string]$packageId, [string]$sourceName = 'ExternalSoftware') {
    if ($global:installedPackages.contains($packageId)) {
        $latestVersion = Get-LatestVersionOfPackage -packageId $packageId -sourceName $sourceName
        $installedVersion = $Global:installedPackages[$packageId]
        if ($latestVersion -eq $installedVersion) {
            Write-OK "$packageId is up to date: $installedVersion"
            return
        }
    }

    if (Test-IsBuildServer) {
        Write-Warning "Skipping update of $packageId because we're running on a build server. Please ensure the correct version of this package is installed with Ansible."
        return
    }

    $source = Get-NugetSourceUrl -sourceName $sourceName

    if (Assert-RunningAsAdmin) {
        Invoke-Expression "choco upgrade $packageId --source $source -y --no-progress"
    }
    else {
        Start-ProcessAsAdmin -processName 'choco' -arguments "upgrade $packageId --source $source -y --no-progress"
    }

    Update-InstallSummaryMap -packageType 'choco' -packageId $packageId -exitcode $LASTEXITCODE

    Write-OK "Updated $packageId."
}

function Update-ChocoPackageLegacy([string]$packageId, [string]$sourceName = 'ExternalSoftware') {
    if (Test-IsBuildServer) {
        Write-Warning "Skipping update of $packageId because we're running on a build server. Please ensure the correct version of this package is installed with Ansible."
        return
    }

    $source = Get-NugetSourceUrl -sourceName $sourceName

    if (Assert-RunningAsAdmin) {
        Invoke-Expression "choco upgrade $packageId -s $source -y"
    }
    else {
        Start-ProcessAsAdmin -processName 'choco' -arguments "upgrade $packageId -s $source -y"
    }

    Update-InstallSummaryMap -packageType 'choco' -packageId $packageId -exitcode $LASTEXITCODE

    Write-OK "Updated $packageId."
}

function Install-OnlineChocoPackage([string]$packageId) {
    if (Test-IsBuildServer) {
        Write-Warning "$packageId is not installed, but skipping install because we're running on a build server. Please ensure this package is installed with Ansible."
        return
    }

    if ($Global:installedPackages.contains($packageId)) {
        $version = $Global:installedPackages[$packageId]
        Write-OK "$packageId is installed: $version"
    }
    else {
        if (Assert-RunningAsAdmin) {
            Invoke-Expression "choco install $packageId --confirm --no-progress"
        }
        else {
            Start-ProcessAsAdmin -processName 'choco' -arguments "install $packageId --confirm --no-progress"
        }

        Update-InstallSummaryMap -packageType 'choco' -packageId $packageId -exitcode $LASTEXITCODE

        Write-OK "Installed $packageId."
    }
}

function Update-ShellPath([switch]$Silent) {
    if (-not $Silent.IsPresent) {
        Write-Warning 'Attempting to reload environment, but if something fails, you may have to close and reopen your shell, and then run this script again.'
    }

    $shell = Get-Shell
    if ($shell -eq 'CMD') {
        & refreshenv
    }
    elseif ($shell -eq 'PowerShell') {
        Import-Module "$env:ChocolateyInstall\helpers\chocolateyInstaller.psm1" -Force
        Update-SessionEnvironment
    }
    else {
        throw "Unknown shell: $shell"
    }
}

function Get-Shell {
    if (Get-Content 2>&1 -ea ig .) {
        Write-Output 'CMD'
    }
    else {
        Write-Output 'PowerShell'
    }
}

function Add-ToPath([string]$dir) {
    $path = [Environment]::GetEnvironmentVariable('PATH', 'machine')
    $escaped = [Regex]::Escape($dir)
    if (-not ($path -match "$escaped`$" -or $path -match "$escaped;")) {
        [Environment]::SetEnvironmentVariable('PATH', "$dir;$path", 'machine')
        $Env:Path = "$dir;$($Env:Path)"

        Update-ShellPath
    }
}

function Test-IsBuildServer {
    # check if we are running on a build server
    $buildServerEnvVar = $Env:TEAMCITY_VERSION
    if (-not [string]::IsNullOrEmpty($buildServerEnvVar)) {
        Write-Output $true
        return
    }

    $buildServerEnvVar = $Env:TF_BUILD
    if (-not [string]::IsNullOrEmpty($buildServerEnvVar)) {
        Write-Output $true
    }
    else {
        Write-Output $false
    }
}

function Get-ConfigValue([string]$configKey, [string]$defaultValue = $null, [bool]$warnIfMissing = $true) {
    if (Test-Path $bootstrapperConfigFile) {
        $configLines = [IO.File]::ReadAllLines($bootstrapperConfigFile)
        foreach ($line in $configLines) {
            $split = $line.Split('=')
            if ($split[0].ToLower() -like $configKey.ToLower()) {
                $configValue = $split[1]
                Write-Verbose "Config key '$configKey' found with value '$configValue'."
                Write-Output $configValue
                return
            }
        }

        if ($warnIfMissing) {
            Write-Warning "Could not find key '$configKey' in '$bootstrapperConfigFile', using default value '$defaultValue'."
        }
    }
    else {
        Write-Warning "Could not find '$bootstrapperConfigFile', please verify that this file exists."
    }

    Write-Output "$defaultValue"
}

function Get-BoolConfigValue([string]$configKey, [bool]$defaultValue, [bool]$warnIfMissing = $false) {
    $configValue = Get-ConfigValue -configKey $configKey -defaultValue $defaultValue -warnIfMissing $warnIfMissing
    if ([string]::IsNullOrWhiteSpace($configValue)) {
        Write-Output $defaultValue
        return
    }

    $boolValue = $null
    if (-not [bool]::TryParse($configValue, [ref]$boolValue)) {
        Write-Warning "The configured value for '$configKey' is not a valid bool: '$configValue'. Using default value '$defaultValue'."
        Write-Output $defaultValue
    }
    else {
        Write-Output $boolValue
    }
}

function Set-ConfigValue([string]$configKey, [string]$value) {
    if (-not (Test-Path $bootstrapperConfigFile)) {
        Write-Warning "Could not find '$bootstrapperConfigFile', please verify that this file exists."
        return
    }

    $existingValue = Get-ConfigValue -configKey $configKey -warnIfMissing $false
    if (-not [string]::IsNullOrWhiteSpace($existingValue)) {
        Write-Warning "'$configKey' already exists with value '$existingValue'"
    }

    $found = $false
    $configLines = [IO.File]::ReadAllLines($bootstrapperConfigFile)
    $updatedConfigLines = [System.Collections.ArrayList]@()
    foreach ($configLine in $configLines) {
        if ($configLine.StartsWith($configKey)) {
            $updatedConfigLines.Add("$configKey=$value") | Out-Null
            $found = $true
            continue
        }

        $updatedConfigLines.Add($configLine) | Out-Null
    }

    if (-not $found) {
        $updatedConfigLines.Add("$configKey=$value") | Out-Null
    }

    [IO.File]::WriteAllLines($bootstrapperConfigFile, $updatedConfigLines)
}

function Get-LatestVersionOfPackage([string]$packageId, [bool]$allowPrerelease, [string]$sourceName = 'DIPS-Nuget') {
    $allVersions = Get-AllVersionsOfPackage -sourceName $sourceName -packageId $packageId -allowPrerelease $allowPrerelease
    if ($null -eq $allVersions -or $allVersions.Length -eq 0) {
        throw "Found no versions of '$packageId' in '$sourceName' (allowPrerelease was '$allowPrerelease')"
    }

    $latestVersion = Get-HighestVersion -versions $allVersions -includePrereleases:$allowPrerelease

    Write-Output $latestVersion
}

function Get-AllVersionsOfPackage([string]$packageId, [bool]$allowPrerelease, [string]$sourceName = 'DIPS-Nuget') {
    $source = Get-NugetSourceUrl -sourceName $sourceName

    $nextUrl = "$($source)/FindPackagesById()?id='$($packageId)'&semVerLevel=2.0.0&%24orderby=Version desc"

    do {
        $result = Invoke-WebRequest -Uri $nextUrl -UseBasicParsing

        $resultXml = [xml]$result

        $nsManager = Get-XmlNamespaceManager -xmlDocument $resultXml

        $feedNode = $resultXml.SelectSingleNode('//ns:feed', $nsManager)

        $entryNodes = $feedNode.SelectNodes('ns:entry', $nsManager)
        $versions = $entryNodes | ForEach-Object {
            $idNode = $_.SelectSingleNode('ns:id', $nsManager)
            $id = $idNode.InnerText
            $versionMatch = [Regex]::Match($id, "Version='(.*)'")
            if ($versionMatch.Success) {
                $version = $versionMatch.Groups[1].Value
                $isPrereleaseVersion = Test-IsPrereleaseVersion -version $version
                if ($isPrereleaseVersion -and -not $allowPrerelease) {
                    # continue
                }
                else {
                    Write-Output $version
                }
            }
        }

        if ($entryNodes.Count -eq 1) {
            Write-Output $versions
            return
        }
        elseif ($null -eq $versions -or $versions.Length -eq 0) {
            return
        }
        else {
            foreach ($version in $versions) {
                Write-Output $version
            }
        }

        $nextLinkNode = $feedNode.SelectNodes('ns:link', $nsManager) | Where-Object { $_.Attributes['rel'].Value -eq 'next' } | Select-Object -First 1
        if ($null -eq $nextLinkNode) {
            return
        }

        $nextUrl = $nextLinkNode.Attributes['href'].Value

    } while (-not [string]::IsNullOrWhiteSpace($nextUrl))
}

function Get-XmlNamespaceManager {
    Param(
        [Parameter(
            ParameterSetName = 'XmlElement'
        )]
        [System.Xml.XmlElement]$xmlElement,
        [Parameter(
            ParameterSetName = 'XmlDocument'
        )]
        [System.Xml.XmlDocument]$xmlDocument
    )

    if ($PSCmdlet.ParameterSetName -eq 'XmlElement') {
        $xmlDocument = $xmlElement.OwnerDocument
    }

    $xmlNamespace = $xmlDocument.DocumentElement.NamespaceURI
    $namespaceManager = New-Object System.Xml.XmlNamespaceManager($xmlDocument.NameTable)

    $namespaceManager.AddNamespace('ns', $xmlNamespace) | Out-Null

    Write-Output $namespaceManager -NoEnumerate
}

function Get-HighestVersion([array]$versions, [switch]$includePrereleases) {
    $highestVersion = '0.0.0'
    foreach ($version in $versions) {
        if ((Test-IsPrereleaseVersion -version $version) -and -not $includePrereleases.IsPresent) {
            continue
        }

        $comparison = Compare-Versions -firstVersion $version -secondVersion $highestVersion
        if ($comparison -eq 1) {
            $highestVersion = $version
        }
    }

    Write-Output $highestVersion
}

function Compare-Versions([string]$firstVersion, [string]$secondVersion) {
    $firstParsedVersion = ConvertTo-ComparableVersion -version $firstVersion
    $secondParsedVersion = ConvertTo-ComparableVersion -version $secondVersion

    if ($firstParsedVersion['MAJOR'] -eq $secondParsedVersion['MAJOR'] -and
        $firstParsedVersion['MINOR'] -eq $secondParsedVersion['MINOR'] -and
        $firstParsedVersion['BUILD'] -eq $secondParsedVersion['BUILD'] -and
        $firstParsedVersion['REVISION'] -eq $secondParsedVersion['REVISION'] -and
        $firstParsedVersion['SpecialVersion'] -eq $secondParsedVersion['SpecialVersion']) {
        Write-Output 0
        return
    }

    if ($firstParsedVersion['MAJOR'] -gt $secondParsedVersion['MAJOR']) {
        Write-Output 1
        return
    }
    elseif ($firstParsedVersion['MAJOR'] -lt $secondParsedVersion['MAJOR']) {
        Write-Output -1
        return
    }

    if ($firstParsedVersion['MINOR'] -gt $secondParsedVersion['MINOR']) {
        Write-Output 1
        return
    }
    elseif ($firstParsedVersion['MINOR'] -lt $secondParsedVersion['MINOR']) {
        Write-Output -1
        return
    }

    if ($firstParsedVersion['BUILD'] -gt $secondParsedVersion['BUILD']) {
        Write-Output 1
        return
    }
    elseif ($firstParsedVersion['BUILD'] -lt $secondParsedVersion['BUILD']) {
        Write-Output -1
        return
    }

    if ($firstParsedVersion['REVISION'] -gt $secondParsedVersion['REVISION']) {
        Write-Output 1
        return
    }
    elseif ($firstParsedVersion['REVISION'] -lt $secondParsedVersion['REVISION']) {
        Write-Output -1
        return
    }

    if ([string]::IsNullOrWhiteSpace($firstParsedVersion['SpecialVersion']) -and -not [string]::IsNullOrWhiteSpace($secondParsedVersion['SpecialVersion'])) {
        Write-Output 1
        return
    }
    elseif ([string]::IsNullOrWhiteSpace($secondParsedVersion['SpecialVersion']) -and -not [string]::IsNullOrWhiteSpace($firstParsedVersion['SpecialVersion'])) {
        Write-Output -1
        return
    }

    if ($firstParsedVersion['SpecialVersion'] -gt $secondParsedVersion['SpecialVersion']) {
        Write-Output 1
    }
    else {
        Write-Output -1
    }
}

function ConvertTo-ComparableVersion([string]$version) {
    $parsedVersion = @{}
    $parsedVersion.Add('MAJOR', 0)
    $parsedVersion.Add('MINOR', 0)
    $parsedVersion.Add('BUILD', 0)
    $parsedVersion.Add('REVISION', 0)
    $parsedVersion.Add('SpecialVersion', '')

    if ([string]::IsNullOrWhiteSpace($version)) {
        Write-Output $parsedVersion
        return
    }

    $specialVersionSplit = $version.Split('-')
    if ($specialVersionSplit.Length -gt 1) {
        $parsedVersion['SpecialVersion'] = $specialVersionSplit[1]
    }
    else {
        $specialVersionSplit = $version.Split('+')
    }

    $versionSplit = $specialVersionSplit[0].Split('.')
    $parsedVersion['MAJOR'] = [int]$versionSplit[0]

    if ($versionSplit.Length -gt 1) {
        $parsedVersion['MINOR'] = [int]$versionSplit[1]
    }

    if ($versionSplit.Length -gt 2) {
        $parsedVersion['BUILD'] = [int]$versionSplit[2]
    }

    if ($versionSplit.Length -gt 3) {
        $parsedVersion['REVISION'] = [int]$versionSplit[3]
    }

    Write-Output $parsedVersion
}

function Test-IsPrereleaseVersion([string]$version) {
    $parsedVersion = ConvertTo-ComparableVersion -version $version

    $isPrerelease = -not [string]::IsNullOrWhiteSpace($parsedVersion['SpecialVersion'])
    Write-Output $isPrerelease
}



function Format-Hashtable {
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [hashtable]$Hashtable,

        [ValidateNotNullOrEmpty()]
        [string]$KeyHeader = 'Name',

        [ValidateNotNullOrEmpty()]
        [string]$ValueHeader = 'Value'
    )

    $Hashtable.GetEnumerator() | Select-Object @{ Label = $KeyHeader; Expression = { $_.Key } }, @{ Label = $ValueHeader; Expression = { $_.Value } }
}