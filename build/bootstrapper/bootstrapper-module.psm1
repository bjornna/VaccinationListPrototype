$ErrorActionPreference = "Stop"

$Global:bootstrapperDir = $PSScriptRoot
$Global:buildDir = [System.IO.Path]::GetFullPath((Join-Path $Global:bootstrapperDir '..'))
$Global:rootDir = [System.IO.Path]::GetFullPath((Join-Path $Global:buildDir '..'))

$customBootstrapperScriptPath = Join-Path $Global:bootstrapperDir 'bootstrapper-custom.ps1'
$scriptCsPackagesPath = Join-Path $Global:buildDir 'scriptcs_packages'
$scriptCsPackagesConfigPath = Join-Path $Global:buildDir 'scriptcs_packages.config'

$minimumChocolateyVersion = '0.10.11'
$nugetCommandLineMinimumVersion = '4.5.1'
$scriptCsMinimumVersion = 'Version: 0.17'
$rubyGemsVersion = '2.7.4'
$rubyVersion = '25'
$rubyChocoVersion = '2.5.3.101'
$minimumPesterVersion = '4.4.0'

$chocolateyPath = Join-Path $Env:ProgramData 'chocolatey'
$chocolateyLibPath = Join-Path $chocolateyPath 'lib'
$chocolateyBinPath = Join-Path $chocolateyPath 'bin'

$toolsDir = 'C:\tools'
$rubyPath = "$toolsDir\ruby$rubyVersion"
$rubyBinPath = Join-Path $rubyPath 'bin'
$rubyLibPath = Join-Path $rubyPath 'lib'
$rubyGemsPath = Join-Path $rubyLibPath 'ruby\gems'

$tempDir = 'C:\temp'
$buildsystemTempDir = Join-Path $tempDir 'DIPSBuildsystem'
$bootstrapperTimestampFilePath = Join-Path $buildsystemTempDir 'lastDependencyCheck.txt'
$bootstrapperTimestampMinimumFilePath = Join-Path $buildsystemTempDir 'lastDependencyCheckMinimum.txt'
$bootstrapperTimestampDatabaseFilePath = Join-Path $buildsystemTempDir 'lastDependencyCheckDatabase.txt'

$Global:installSummary = @{}
$Global:installedPackages = @{}

Remove-Module -Name 'bootstrapper-utils' -Force -ErrorAction SilentlyContinue
$bootstrapperUtilsModule = (Join-Path $Global:bootstrapperDir 'bootstrapper-utils.psm1')
Import-Module -Name $bootstrapperUtilsModule

Remove-Module -Name 'bootstrapper-buildsystem' -Force -ErrorAction SilentlyContinue
$bootstrapperBuildsystemModule = (Join-Path $Global:bootstrapperDir 'bootstrapper-buildsystem.psm1')
Import-Module -Name $bootstrapperBuildsystemModule

function Update-InstallSummaryMap([string]$packageType, [string]$packageId, [string]$exitcode) {
    if ($exitcode -ne '0') {
        Write-Warning "$packageType package $packageId install returned exitcode $exitcode"
        $Global:installSummary.add($($packageType.PadRight(8, ' ') + $packageId), $($exitcode))
    }
    else {
        Write-OK "$packageType package $packageId has been installed."
    }
}

function Assert-PowershellVersion {
    $minimumMajorVersion = 4
    $powershellVersion = $PSVersionTable.PSVersion
    if ($powershellVersion.Major -lt $minimumMajorVersion) {
        throw "This script requires at least Powershell version $minimumMajorVersion. Please upgrade Powershell with 'choco install/upgrade powershell', and then rerun this script."
    }

    Write-OK "Powershell is up to date: $powershellVersion"
}

function Assert-Chocolatey {
    $minimumVersion = [System.Version]$minimumChocolateyVersion

    $chocoExePath = Join-Path $chocolateyPath 'choco.exe'
    if (-not (Test-Path $chocoExePath)) {
        $chocoExePath = Join-Path $chocolateyBinPath 'choco.exe'

        if (-not (Test-Path $chocoExePath)) {
            Write-Error 'Chocolatey is not installed. Please install chocolatey before running the bootstrapper.'
            Write-Caption 'You can install Chocolatey by running the following command:'
            Write-Caption "iex ((New-Object System.Net.WebClient).DownloadString('https://chocolatey.org/install.ps1'))"
            exit
        }
    }

    Write-OK 'Chocolatey is already installed.'

    $chocolateyVersionString = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($chocoExePath).FileVersion
    $chocolateyVersion = [System.Version]$chocolateyVersionString

    if ($chocolateyVersion -ge $minimumVersion) {
        Write-OK "Chocolatey is up to date: $chocolateyVersion"
        return
    }
    else {
        if (Test-IsBuildServer) {
            Write-Warning "Chocolatey is not up to date, please ensure Ansible installs the correct version of Chocolatey."
            return
        }

        Write-Caption "DIPS Buildsystem requires at least version $minimumChocolateyVersion of Chocolatey, but current version is $chocolateyVersionString `nRunning upgrade..."

        if ($chocolateyVersion.Minor -lt 10) {
            Update-ChocoPackageLegacy -packageId 'chocolatey'
        }
        else {
            Update-ChocoPackage -packageId 'chocolatey'
        }

        Update-ShellPath

        Write-OK 'Upgraded Chocolatey.'
    }
}

function Assert-ScriptCS {
    try {
        $scriptcsVersion = & scriptcs -v | Out-String

        Write-OK 'ScriptCS is already installed.'

        if ($scriptcsVersion -match $scriptCsMinimumVersion) {
            Write-OK "ScriptCS is up to date: `n$scriptcsVersion"
            return
        }
        else {
            Write-Caption "DIPS Buildsystem requires version 0.17.x of ScriptCS, but current version is `n$scriptcsVersion `nRunning upgrade..."
        }
    }
    catch {
        Write-Caption 'ScriptCS is not installed, installing...'
    }

    Update-ChocoPackage -packageId 'scriptcs'

    Write-OK 'Installed ScriptCS.'

    Repair-ScriptCS
}

function Repair-ScriptCS {
    if (-not (Assert-RunningAsAdmin)) {
        throw "You must run this script with administrator privileges."
    }

    $packageId = 'Microsoft.Web.Xdt'
    $version = '2.1.1'

    $packageDir = Join-Path $tempDir $packageId
    if (Test-Path $packageDir) {
        Remove-Item $packageDir -Recurse -Force
    }

    Install-NugetPackage -packageId $packageId -version $version -sourceName 'DIPS-3rdParty' -outputDirectory $packageDir -excludeVersion

    $fileName = 'Microsoft.Web.XmlTransform.dll'

    $sourcePath = [System.IO.Path]::Combine($packageDir, $packageId, 'lib', 'net40', $fileName)
    $destinationPath = [System.IO.Path]::Combine($chocolateyLibPath, 'scriptcs', 'tools', $fileName)

    Copy-Item -Path $sourcePath -Destination $destinationPath -Force
}

function Assert-NugetCommandLine {
    try {
        $nugetHelp = & nuget ?
        $nugetVersionLine = ($nugetHelp -split '\n')[0]
        $nugetVersionString = $nugetVersionLine -replace 'NuGet Version: ', ''

        $nugetVersion = [System.Version]$nugetVersionString
        $minimumVersion = [System.Version]$nugetCommandLineMinimumVersion

        if ($nugetVersion -ge $minimumVersion) {
            Write-OK "NuGet.CommandLine is up to date: $nugetVersion"
            return
        }

        Write-Caption 'NuGet.CommandLine is outdated, updating...'

        Update-ChocoPackage -packageId 'NuGet.CommandLine'

        Write-OK 'Updated NuGet.CommandLine.'
    }
    catch {
        Install-ChocoPackage -packageId 'NuGet.CommandLine'
    }
}

function Assert-Ruby {
    try {
        $rubyVersion = & ruby -v
        Write-OK "Ruby is already installed: $rubyVersion"
    }
    catch {
        Install-ChocoPackage -packageId 'Ruby' -version $rubyChocoVersion

        Update-ShellPath

        Add-ToPath $rubyBinPath
    }
}

function Assert-RubyGems {
    $minimumVersion = [System.Version]$rubyGemsVersion
    try {
        $rubyGemsVersionOutput = & gem --version
        $rubyGemsVersion = [System.Version]$rubyGemsVersionOutput

        Write-OK "rubygems is installed: $rubyGemsVersionOutput"

        if ($rubyGemsVersion -ge $minimumVersion) {
            Write-OK "rubygems is up to date with the required minimum version ($minimumVersion)."
            return
        }
        else {
            if (Test-IsBuildServer) {
                Write-Warning 'rubygems is outdated. Please ensure this Ruby tool is installed by Ansible.'
                return
            }

            Write-Caption 'rubygems is outdated, updating...'
            Write-Warning 'If you keep seeing this update, you may have 2 different versions of Ruby installed. Try uninstalling both, and then run this again.'

            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

            $rubyGems = Join-Path $tempDir "rubygems-update-$rubyGemsVersion.gem"
            Invoke-WebRequest "https://rubygems.org/downloads/rubygems-update-$rubyGemsVersion.gem" -OutFile $rubyGems -UseBasicParsing

            try {
                & gem install --local $rubyGems
                & gem update --system
            }
            catch {
                Write-Error 'Could not find rubygems on the command line. If Ruby/rubygems has been installed, you may have to close and reopen your shell.'
                throw
            }

            Remove-Item $rubyGems

            Write-OK 'Updated rubygems.'
        }
    }
    catch {
        if (Test-IsBuildServer) {
            Write-Warning 'rubygems is not installed. Please ensure this Ruby tool is installed by Ansible.'
            return
        }

        Write-Caption 'rubygems is not installed, installing...'

        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

        $rubyGemsZip = Join-Path $tempDir "rubygems-$rubyGemsVersion.zip"
        Invoke-WebRequest "https://rubygems.org/rubygems/rubygems-$rubyGemsVersion.zip" -OutFile $rubyGemsZip -UseBasicParsing

        $rubyGems = Join-Path $tempDir 'rubygems'
        if (Test-Path $rubyGems) {
            Remove-Item $rubyGems -Recurse -Force
        }

        try {
            Add-Type -AssemblyName 'System.IO.Compression.FileSystem'
            [System.IO.Compression.ZipFile]::ExtractToDirectory($rubyGemsZip, $rubyGems)
        }
        catch {
            Write-Error 'Unable to unzip rubygems. Try closing and reopening your shell, and then run this again.'
            throw
        }

        $currentLocation = Get-Location
        Set-Location $rubyGems

        if (Assert-RunningAsAdmin) {
            & ruby setup.rb
        }
        else {
            Start-ProcessAsAdmin -processName 'ruby' -arguments 'setup.rb'
        }

        Set-Location $currentLocation

        Update-ShellPath

        Write-OK 'Installed rubygems.'
    }
}

function Assert-AsciiDoctor {
    $gemName = 'asciidoctor'
    $installedVersionString = Get-InstalledGemVersion -gemName $gemName
    $latestVersionString = Get-LatestGemVersion -gemName $gemName

    if ([string]::IsNullOrEmpty($latestVersionstring)) {
        Write-Warning "Unable to determine latest available version of $gemName."
        return
    }

    $latestVersion = [System.Version]$latestVersionString

    if ([string]::IsNullOrEmpty($installedVersionString)) {
        Install-Gem -gemName $gemName
    }
    else {
        $installedVersion = [System.Version]$installedVersionString
        if ($installedVersion -ge $latestVersion) {
            Write-Ok "$gemName is up to date: $latestVersionString"
        }
        else {
            Write-Caption "$gemName is outdated, updating..."

            Update-Gem -gemName $gemName

            Write-Ok "Updated $gemName to version $latestVersionString."
        }
    }

    if ($latestVersion -lt ([System.Version]'2.0.0')) {
        Repair-Asciidoctor -gemName $gemName
    }
}

function Repair-Asciidoctor([string]$gemName) {
    $fileName = 'path_resolver.rb'
    $tempPath = Join-Path 'C:\temp' $fileName

    if (-not (Test-Path $tempPath)) {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

        Invoke-WebRequest "https://raw.githubusercontent.com/mojavelinux/asciidoctor/75a6fea540784ee58aba77f8ac9d2acd1487c7b6/lib/asciidoctor/$fileName" -OutFile $tempPath -UseBasicParsing
    }

    $asciidoctorPath = Find-GemPath -gemName $gemName
    $asciidoctorLibPath = Join-Path $asciidoctorPath 'lib'
    $asciidoctorLibFilesPath = Join-Path $asciidoctorLibPath $gemName
    $destinationPath = Join-Path $asciidoctorLibFilesPath $fileName

    $newContent = Get-Content $tempPath
    $oldContent = Get-Content $destinationPath
    if ($newContent.Length -ne $oldContent.Length) {
        Write-Warning 'Applying asciidoctor path resolver hotfix...'
        Copy-Item -Path $tempPath -Destination $destinationPath -Force
    }
}

function Find-GemPath([string]$gemName) {
    $rubyVersionPath = Find-RubyVersion
    $gemsDirectory = Join-Path $rubyVersionPath 'gems'

    $gemDirectory = Get-ChildItem -Path $gemsDirectory -Directory | Where-Object { $_.Name -match "$gemName-[0-9]\.[0-9]\.[0-9]" } | Select-Object -Last 1
    Join-Path $gemsDirectory $gemDirectory | Write-Output
}

function Find-RubyVersion {
    $rubyVersion = Get-ChildItem -Path $rubyGemsPath -Directory | Select-Object -Last 1
    Join-Path $rubyGemsPath $rubyVersion | Write-Output
}

function Assert-AsciiDoctorDiagram {
    Install-Gem -gemName 'asciidoctor-diagram'
}

function Assert-AsciiDoctorPdf {
    Install-Gem -gemName 'asciidoctor-pdf' -prerelease $true
}

function Assert-Coderay {
    Install-Gem -gemName 'coderay'
}

function Get-InstalledGemVersion([string]$gemName) {
    $result = & gem list $gemName --exact --local

    if ([string]::IsNullOrWhiteSpace($result)) {
        Write-Output $null
        return
    }

    $versionMatch = [Regex]::Match($result, "$gemName \((.*)\)")
    if ($versionMatch.Success) {
        $versionSplit = $versionMatch.Groups[1].Value -split ' '
        $installedVersion = $versionSplit[0].Trim(',')
        Write-OK "$gemName is installed: $installedVersion"
        Write-Output $installedVersion
    }
}

function Install-Gem([string]$gemName, [bool]$prerelease = $false) {
    if ($Global:installedPackages.contains($gemName)) {
        $version = $Global:installedPackages[$gemName]
        Write-OK "$gemName is installed: $version"
        return
    }

    if (Test-IsBuildServer) {
        Write-Warning "$gemName is not installed. Please ensure Ansible installs the correct version of this Ruby gem."
        return
    }

    Write-Caption "$gemName is not installed, installing..."
    if ($prerelease) {
        & gem install $gemName --pre
    }
    else {
        & gem install $gemName
    }

    Update-InstallSummaryMap -packageType 'gem' -packageId $gemName -exitcode $LASTEXITCODE

    Write-Ok "Installed $gemName."
}

function Update-Gem([string]$gemName, [bool]$prerelease = $false) {
    if (Test-IsBuildServer) {
        Write-Warning "Skipping update of $gemName because we're running on a build server. Please ensure Ansible installs the correct version of this Ruby gem."
        return
    }

    if ($prerelease) {
        & gem update $gemName
    }
    else {
        & gem update $gemName
    }

    Update-InstallSummaryMap -packageType 'gem' -packageId $gemName -exitcode $LASTEXITCODE

    Write-Ok "Updated $gemName."
}

function Get-LatestGemVersion([string]$gemName, [bool]$prerelease = $false) {
    if ($prerelease) {
        $result = & gem list $gemName --exact --remote --pre
    }
    else {
        $result = & gem list $gemName --exact --remote
    }

    if ([string]::IsNullOrWhiteSpace($result)) {
        Write-Output $null
        return
    }

    $versionMatch = [Regex]::Match($result, "$gemName \(([0-9]+\.[0-9]+\.[0-9]*).*\)")
    if ($versionMatch.Success) {
        Write-Output $versionMatch.Groups[1].Value
    }
}

function Assert-Python {
    $skipMkdocs = Get-BoolConfigValue -configKey 'skipMkdocs' -defaultValue $true -warnIfMissing $false
    if ($skipMkdocs) {
        return
    }

    try {
        $pythonVersion = & python --version
        if ([string]::IsNullOrWhiteSpace($pythonVersion)) {
            Install-ChocoPackage -domainName $domainName -packageId 'Python'
            Update-ShellPath
        }
        else {
            Write-OK "Python is installed: $pythonVersion"
        }
    }
    catch {
        Install-ChocoPackage -packageId 'Python'

        Update-ShellPath
    }
}

function Assert-Pip {
    $skipMkdocs = Get-BoolConfigValue -configKey 'skipMkdocs' -defaultValue $true -warnIfMissing $false
    if ($skipMkdocs) {
        return
    }

    try {
        $pipVersion = & pip --version
        Write-OK "pip is installed: $pipVersion"
    }
    catch {
        if (Test-IsBuildServer) {
            Write-Warning 'pip is not installed. Please ensure this Python module is installed by Ansible'
            return
        }

        Write-Caption 'pip is not installed, installing...'
        Write-Warning 'If you keep seeing this update, you may have 2 different versions of Python installed. Try uninstalling both, and then run this again.'

        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

        $getPip = Join-Path $tempDir 'get-pip.py'
        Invoke-WebRequest 'https://bootstrap.pypa.io/get-pip.py' -OutFile $getPip -UseBasicParsing

        try {
            & python $getPip
        }
        catch {
            Write-Error 'Could not find python on the command line. If Python has been installed, you may have to close and reopen your shell.'
            throw
        }

        Write-OK 'Installed pip.'
    }
}

function Assert-Mkdocs {
    $skipMkdocs = Get-BoolConfigValue -configKey 'skipMkdocs' -defaultValue $true -warnIfMissing $false
    if ($skipMkdocs) {
        return
    }

    try {
        $mkdocsVersion = & mkdocs --version
        Write-OK "mkdocs is installed: $mkdocsVersion"
    }
    catch {
        if (Test-IsBuildServer) {
            Write-Warning 'mkdocs is not installed. Please ensure this Python module is installed by Ansible'
            return
        }

        Write-Caption 'mkdocs is not installed, installing...'

        & pip install mkdocs

        Write-OK 'Installed mkdocs.'
    }
}

function Assert-MkdocsMaterial {
    $skipMkdocs = Get-BoolConfigValue -configKey 'skipMkdocs' -defaultValue $true -warnIfMissing $false
    if ($skipMkdocs) {
        return
    }

    $pipPackages = & pip list --format=columns --disable-pip-version-check
    if ($pipPackages -match 'mkdocs-material') {
        Write-OK 'mkdocs-material is installed.'
    }
    else {
        if (Test-IsBuildServer) {
            Write-Warning 'mkdocs-material is not installed. Please ensure this Python module is installed by Ansible'
            return
        }

        Write-Caption 'mkdocs-material is not installed, installing...'

        & pip install mkdocs-material
        & pip install pygments

        Update-ShellPath

        Write-OK 'Installed mkdocs-material.'
    }
}

function Assert-GitCommandline {
    try {
        $gitVersion = & git --version

        Write-OK 'Git commandline is installed.'
    }
    catch {
        Install-ChocoPackage -packageId 'git.install'
        Write-Warning 'You may have to close any open ssh shell sessions!'
        Update-ShellPath
    }
}

function Assert-GitVersion {
    Install-ChocoPackage -packageId 'GitVersion.Portable'
}

function Assert-CoverageToXml {
    Install-ChocoPackage -packageId 'CoverageToXml'
}

function Assert-VisualStudioXmlConverter {
    Install-ChocoPackage -packageId 'VisualStudioXmlConverter'
}

function Assert-DupDesigner {
    Update-ChocoPackage -packageId 'dup-designer' -sourceName 'InternalSoftware'
}

function Assert-DupProcessor {
    Update-ChocoPackage -packageId 'dup-processor' -sourceName 'DIPS-RC'
}

function Assert-DatabaseReset {
    Update-ChocoPackage -packageId 'dips-databasereset' -sourceName 'InternalSoftware'
}

function Assert-DupLicense {
    Update-ChocoPackage -packageId 'dupsoft-dips-license' -sourceName 'InternalSoftware'
}

function Assert-DBUpgrade {
    Update-ChocoPackage -packageId 'dips-dbupgrade' -sourceName 'DIPS-RC'
}

function Assert-dwDba {
    Update-ChocoPackage -packageId 'dips-dwdba' -sourceName 'DIPS-RC'
}

function Assert-DupPowerTools {
    Update-ChocoPackage -packageId 'dips.dup_powertools' -sourceName 'DIPS-Nuget'
}

function Assert-PlSqlDevTestRunner {
    Update-ChocoPackage -packageId 'plsqldev-test-runner' -sourceName 'DIPS-Nuget'
}

function Assert-DataDictionaryTests {
    Update-ChocoPackage -packageId 'dips.data_dictionary_tests' -sourceName 'DIPS-Nuget'
}

function Assert-DatamartUpgrade {
    Install-ChocoPackage -packageId 'dips-datamartupgrade' -sourceName 'InternalSoftware'
}

function Assert-ReportGenerator {
    Install-ChocoPackage -packageId 'ReportGenerator'
}

function Assert-OctopusDeployCli {
    Install-ChocoPackage -packageId 'octopustools'
}

function Assert-NetFx48Dev {
    Install-ChocoPackage -packageId 'netfx-4.8-devpack'
}

function Assert-JFrogCli {
    try {
        $jfrogOutput = & jfrog help
        Write-Ok 'JFrog CLI is installed.'
        return
    }
    catch {
        Write-Warning 'JFrog CLI is not installed.'
    }

    if (Test-IsBuildServer) {
        return
    }

    if (-not (Test-Path $toolsDir)) {
        New-Item -Path $toolsDir -ItemType 'Directory'
    }

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    Invoke-WebRequest 'https://api.bintray.com/content/jfrog/jfrog-cli-go/$latest/jfrog-cli-windows-amd64/jfrog.exe?bt_package=jfrog-cli-windows-amd64' -OutFile "$toolsDir\jfrog.exe"

    Add-ToPath $toolsDir

    Write-Ok 'Installed JFrog CLI.'
}

function Get-InstalledModuleVersions([string]$moduleName) {
    $installedVersion = Get-Module -ListAvailable -Name $moduleName | Select-Object -ExpandProperty 'version'
    Write-Output $installedVersion
}

function Assert-Pester {
    $wasInstalled = $Global:installedPackages.contains('Pester')
    Update-ChocoPackage -packageId 'Pester'
    if (-Not $wasInstalled -and $Global:installedPackages.contains('Pester')) {
        Update-ShellPath
    }
}

function Assert-PackageManagerCLI {
    Install-ChocoPackage -packageId 'dips-arena-packagemanager-cli' -sourceName 'InternalSoftware'
}

function Install-ScriptCsDependencies {
    if ((Test-Path $scriptCsPackagesPath) -or -not (Test-Path $scriptCsPackagesConfigPath)) {
        return
    }
}

function Install-Dependencies([bool]$buildsystemUpdated) {
    $scriptCsPackagesPath = Join-Path $buildDir 'scriptcs_packages'
    if ((Test-Path $scriptCsPackagesPath) -and -not $buildsystemUpdated) {
        return
    }

    Write-Caption 'Installing all ScriptCS Buildsystem dependencies...'
    $currentDir = Get-Location
    Set-Location $Global:buildDir
    & scriptcs -install
    Set-Location $currentDir
    Write-OK 'Finished installing ScriptCS dependencies.'
}

function Invoke-CustomBootstrapper {
    if (Test-Path $customBootstrapperScriptPath) {
        Write-Host 'Running custom bootstrapper script...'
        & $customBootstrapperScriptPath
    }
    else {
        Write-Host 'No custom bootstrapper script found.'
    }
}

function Enable-IISFeature([string]$FeatureName) {
    $currentState = (Get-WindowsOptionalFeature -FeatureName $FeatureName -Online).State
    if ($currentState -ne 'Enabled') {
        if (Test-IsBuildServer) {
            Write-Warning "$FeatureName is not enabled. Please ensure this feature is enabled by Ansible."
            return
        }

        Enable-WindowsOptionalFeature -FeatureName $FeatureName -Online -All
        Write-OK "$FeatureName has been enabled."
    }
}

function Enable-IISFeatures {
    if (Test-IsBuildServer) {
        Write-Warning "On Buildserver. Please ensure necessary IIS features are enabled by Ansible."
        return
    }

    $elevated = Assert-RunningAsAdmin
    if ($elevated) {
        Write-Caption 'Enabling IIS features as necessary...'

        Enable-IISFeature -FeatureName 'IIS-WebServer'
        Enable-IISFeature -FeatureName 'IIS-CommonHttpFeatures'
        Enable-IISFeature -FeatureName 'IIS-ApplicationDevelopment'
        Enable-IISFeature -FeatureName 'IIS-NetFxExtensibility45'
        Enable-IISFeature -FeatureName 'IIS-ASPNET'
        Enable-IISFeature -FeatureName 'IIS-ASPNET45'
        Enable-IISFeature -FeatureName 'IIS-ClientCertificateMappingAuthentication'
        Enable-IISFeature -FeatureName 'WCF-HTTP-Activation'

        Install-OnlineChocoPackage -packageId 'urlrewrite'
        Install-OnlineChocoPackage -packageId 'iis-arr'

        Enable-IISFeature -FeatureName 'IIS-HttpRedirect'

        Set-WebConfigurationProperty -pspath 'MACHINE/WEBROOT/APPHOST' -filter "system.webServer/proxy" -name "enabled" -value "True"
    }
    else {
        Write-Warning 'Not running as administrator. Skipping IIS setup'
    }
}

function Install-DotNetSDKs {
    Write-Caption 'Installing .NET SDKs...'

    $dotnetPackagIds = 'netfx-4.6.2-devpack', 'netfx-4.7.1-devpack', 'netfx-4.8-devpack', 'dotnetcore-sdk', 'dotnetcore-windowshosting', 'dotnet-5.0-sdk'
    foreach ($packageId in $dotnetPackagIds) {
        Install-OnlineChocoPackage -packageId $packageId
    }

    Write-Caption 'Installing dotnet-script'

    Invoke-Expression 'dotnet tool install -g dotnet-script'
}

function Remove-ScriptCsPackages {
    if (Test-Path $scriptCsPackagesPath) {
        Remove-Item $scriptCsPackagesPath -Recurse -Force
    }
}

function Add-ToInstalledListIfValidVersion([string]$packageId, [string]$cmdLineResult, $packages) {
    $splitresult = $cmdLineResult.split(' ')
    $version = $splitresult[$splitresult.Count - 1]
    $versionPattern = '[0-9]*\.[0-9]*\.[0-9]'
    if ($version -match $versionPattern) {
        $packages.add($packageId, $version)
    }
}

function Get-LocallyInstalledChocoPackages {

    $Null = @(
        $packages = @{}
        $temp = Invoke-Expression -command 'choco list --local-only --limit-output --prerelease'

        foreach ($installedPackage in $temp) {
            $values = $installedPackage.Split("|", [System.StringSplitOptions]::RemoveEmptyEntries)
            $package = $values[0]
            $version = $values[1]
            $packages.add($package, $version)
        }
        #Special cases: These packages may be installed by other means. Check if they are not allready in the list and add if found anyway.
        try {
            $package = 'GitVersion.Portable'
            if (-Not $packages.contains($package)) {
                $version = & gitversion /version
                Add-ToInstalledListIfValidVersion -packageId $package  -cmdLineResult $version -packages $packages
            }
        }
        catch { Write-Verbose "Validation of $package failed. Assuming not installed. Bootstrapper will try to force install package." }

        try {
            $package = 'git.install'
            if (-Not $packages.contains($package)) {
                $version = & git --version
                Add-ToInstalledListIfValidVersion -packageId $package  -cmdLineResult $version -packages $packages
            }
        }
        catch { Write-Verbose "Validation of $package failed. Assuming not installed. Bootstrapper will try to force install package." }

        try {
            $package = 'Python'
            if (-Not $packages.contains($package)) {
                $version = & python --version
                Add-ToInstalledListIfValidVersion -packageId $package  -cmdLineResult $version -packages $packages
            }
        }
        catch { Write-Verbose "Validation of $package failed. Assuming not installed. Bootstrapper will try to force install package." }

        try {
            $package = 'dips-arena-packagemanager-cli'
            if (-Not $packages.contains($package)) {
                $version = & pm.exe --version
                Add-ToInstalledListIfValidVersion -packageId $package  -cmdLineResult $version -packages $packages
            }
        }
        catch { Write-Verbose "Validation of $package failed. Assuming not installed. Bootstrapper will try to force install package." }

        try {
            $package = 'octopustools'
            if (-Not $packages.contains($package)) {
                $version = & octo version
                Add-ToInstalledListIfValidVersion -packageId $package  -cmdLineResult $version -packages $packages
            }
        }
        catch { Write-Verbose "Validation of $package failed. Assuming not installed. Bootstrapper will try to force install package." }

        try {
            $package = 'ReportGenerator'
            if (-Not $packages.contains($package)) {
                $version = & ReportGenerator
                Add-ToInstalledListIfValidVersion -packageId $package  -cmdLineResult $version -packages $packages
            }
        }
        catch { Write-Verbose "Validation of $package failed. Assuming not installed. Bootstrapper will try to force install package." }

        try {
            [int]$comparison = Compare-Versions $packages[$package] $minimumPesterVersion
            $package = 'Pester'
            if ($packages.contains($package)) {

                $comparison = Compare-Versions $packages[$package] $minimumPesterVersion
                if ($comparison -lt 0) {
                    $installedVersions = Get-InstalledModuleVersions -moduleName $package
                    foreach ($installedVersion in $installedVersions) {
                        $comparison = Compare-Versions $installedVersion $minimumPesterVersion
                        if ($comparison -gt 0) {
                            $packages[$package] = $installedVersion
                            break
                        }
                    }

                    if ($packages.contains($package)) {
                        #No valid version found. Remove package with too old version from list.
                        $packages.remove($package)
                    }
                }
            }
        }
        catch { Write-Verbose "Validation of $package failed. Assuming not installed. Bootstrapper will try to force install package." }


        try {
            $package = 'dup-designer'
            if (-Not $packages.contains($package)) {
                New-PSDrive -Name TempHKCR -PSProvider Registry -Root HKEY_CLASSES_ROOT

                [bool]$DupDesignerInstalled = $false

                if (Test-Path "TempHKCR:DupSoft AS.Dup Designer") {
                    $DupDesignerInstalled = $true
                }

                Remove-PSDrive TempHKCR
                if ($DupDesignerInstalled) {
                    $version = "0.0.0"
                    Add-ToInstalledListIfValidVersion -packageId $package  -cmdLineResult $version -packages $packages
                }
            }
        }
        catch { Write-Verbose "Validation of $package failed. Assuming not installed. Bootstrapper will try to force install package." }



    )
    return $packages
}

function Get-LocallyInstalledGems {
    $null = @(
        $temp = Invoke-Expression -command 'gem search -l'

        $packages = @{}
        foreach ($installedPackage in $temp) {
            $values = $installedPackage.Split(" ", [System.StringSplitOptions]::RemoveEmptyEntries)
            $package = $values[0]
            $version = $values[1]
            if (($values.length -gt 2) -and ($version -eq "(default:")) {
                $version = $values[2]
            }
            $version = $version.replace('(default:', '')
            $version = $version.replace('(', '')
            $version = $version.replace(')', '')
            $version = $version.replace(',', '')
            $packages.add($package, $version)
        }
    )
    $packages
}

function Get-LocallyInstalledPips {
    $null = @(
        $temp = Invoke-Expression -command 'pip freeze -l'

        $packages = @{}
        foreach ($installedPackage in $temp) {
            $values = $installedPackage.Split("==", [System.StringSplitOptions]::RemoveEmptyEntries)
            $package = $values[0]
            $version = $values[1]
            $packages.add($package, $version)
        }
    )
    $packages
}

function Add-ToGlobalHashmap($newHashmap) {

    $newHashmap.GetEnumerator() | ForEach-Object {
        if ($Global:installedPackages.ContainsKey($_.key)) {
            $oldElement = $Global:installedPackages[$_.key]
            $comparison = Compare-Versions $oldElement $_.value
            if ($comparison -eq -1) {
                $Global:installedPackages[$_.key] = $_.value
            }
        }
        else {
            $Global:installedPackages.Add($_.key, $_.value)
        }
    }
}

function Initialize-InstalledPackagesList {
    $Global:installedPackages = @{}
    $Global:installedPackages += Get-LocallyInstalledChocoPackages
    try {
        $rubyVersion = & ruby -v
        $rubyGemsVersionOutput = & gem --version
        Write-Verbose "Ruby and Ruby gems installed. Adding gem packages to list"
        $packages = Get-LocallyInstalledGems
        Add-ToGlobalHashmap $packages
    }
    catch {
        Write-Verbose "Ruby and Ruby gems not installed. Won't check for installed ruby gem packages"
    }
    try {
        $pythonVersion = & python --version
        $pipVersion = & pip --version
        Write-Verbose "Python and pip installed. Adding pip packages to list"
        $packages = Get-LocallyInstalledPips
        Add-ToGlobalHashmap $packages
    }
    catch {
        Write-Verbose "Python and/or pip not installed. Won't check for installed pip packages"
    }
    $packages = @{}
}

function Register-LastDependencyCheck([switch]$DatabaseBuild, [switch]$Minimum) {
    if (-not (Test-Path $buildsystemTempDir)) {
        New-Item -Path $buildsystemTempDir -ItemType Directory
    }

    if ($DatabaseBuild.IsPresent) {
        $timestampFilePath = $bootstrapperTimestampDatabaseFilePath
    }
    elseif ($Minimum.IsPresent) {
        $timestampFilePath = $bootstrapperTimestampMinimumFilePath
    }
    else {
        $timestampFilePath = $bootstrapperTimestampFilePath
    }

    $now = (Get-Date).ToString("yyyy-MM-dd HH:mm")
    [IO.File]::WriteAllText([string]$timestampFilePath, [string]$now)
}

function Assert-NewDependencyCheckRequired([switch]$DatabaseBuild, [switch]$Minimum) {
    if ($DatabaseBuild.IsPresent) {
        $timestampFilePath = $bootstrapperTimestampDatabaseFilePath
    }
    elseif ($Minimum.IsPresent) {
        $timestampFilePath = $bootstrapperTimestampMinimumFilePath
    }
    else {
        $timestampFilePath = $bootstrapperTimestampFilePath
    }

    if (-not (Test-Path $timestampFilePath)) {
        Write-Output $true
        return
    }

    $previous = New-Object DateTime
    $lastDependencyCheck = Get-Content -Path $timestampFilePath -Raw

    if ([string]::IsNullOrWhiteSpace($lastDependencyCheck) -or -not [DateTime]::TryParseExact($lastDependencyCheck, "yyyy-MM-dd HH:mm", [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeLocal, [ref]$previous)) {
        Write-Output $true
        return
    }

    $now = (Get-Date).AddHours(-23)

    $newCheckRequired = $now -gt $previous

    Write-Output $newCheckRequired
}