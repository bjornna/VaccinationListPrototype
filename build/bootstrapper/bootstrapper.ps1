[cmdletbinding()]
param([string]$runType = 'full', [switch]$forceUpdate)

$global:VerbosePreference = $VerbosePreference

$ErrorActionPreference = "Stop"

$stopWatch = [System.Diagnostics.StopWatch]::StartNew()

$runTypeLower = $runType.ToLower();

Remove-Module -Name 'bootstrapper-module' -Force -ErrorAction SilentlyContinue
$bootstrapperModule = (Join-Path $PSScriptRoot 'bootstrapper-module.psm1')
Import-Module -Name $bootstrapperModule

if ($runTypeLower -eq 'checkhost') {
    if (Test-IsBuildServer) {
        Remove-ScriptCsPackages
        $runTypeLower = 'restore'
    }
    else {
        $runTypeLower = 'update'
    }
}

if ($runTypeLower -eq 'initdb') {
    Set-ConfigValue -configKey 'databaseBuild' -value 'true'

    $runTypeLower = 'init'
}

Write-Caption "Running bootstrapper in '$runTypeLower' mode..."

if ($runTypeLower -eq 'iis') {
    Enable-IISFeatures
}
elseif ($runTypeLower -eq 'dotnet') {
    Install-DotNetSDKs
}
elseif ($runTypeLower -ne 'skip') {
    $dependencyCheckRequired = Assert-NewDependencyCheckRequired
    $minimumDependencyCheckRequired = Assert-NewDependencyCheckRequired -Minimum
    $databaseDependencyCheckRequired = Assert-NewDependencyCheckRequired -DatabaseBuild

    if ($minimumDependencyCheckRequired -or $forceUpdate.IsPresent) {
        Write-Caption 'Running minimum dependency check...'

        Assert-PowershellVersion

        Assert-Chocolatey

        Assert-NugetCommandLine

        Assert-GitCommandline

        Register-LastDependencyCheck -Minimum
    }
    else {
        Write-Caption 'Minimum dependencies were checked less than 24 hours ago, skipping new check...'
    }

    if ($runTypeLower -eq 'full' -or $runTypeLower -eq 'update') {
        Update-Bootstrapper

        Import-Module -Name $bootstrapperModule -Force

        Update-Buildsystem -upgrade $true | Out-Null
    }

    if ($runTypeLower -eq 'restore') {
        Update-Buildsystem -upgrade $false | Out-Null
    }

    if ($runTypeLower -eq 'init') {
        Update-Bootstrapper

        Import-Module -Name $bootstrapperModule -Force

        Update-Buildsystem -upgrade $true -init $true | Out-Null
    }

    if ($dependencyCheckRequired -or $databaseDependencyCheckRequired -or $forceUpdate.IsPresent) {
        if (-not $forceUpdate.IsPresent) {
            Initialize-InstalledPackagesList
        }

        $Global:installedPackages | Out-String | Write-Verbose

        if (($runTypeLower -eq 'full' -or $runTypeLower -eq 'restore' -or $runTypeLower -eq 'dependencies') -and ($dependencyCheckRequired -or $forceUpdate.IsPresent)) {
            Write-Caption 'Running full dependency check...'

            Assert-ScriptCS

            Assert-Ruby
            Assert-RubyGems
            Assert-AsciiDoctor
            Assert-AsciiDoctorDiagram
            Assert-AsciiDoctorPdf
            Assert-Coderay

            Assert-Python
            Assert-Pip
            Assert-Mkdocs
            Assert-MkdocsMaterial

            Assert-GitVersion

            Assert-CoverageToXml
            Assert-ReportGenerator

            Assert-VisualStudioXmlConverter

            Assert-PackageManagerCLI

            Assert-Pester

            Assert-OctopusDeployCli
            Assert-JFrogCli

            Assert-NetFx48Dev

            Enable-IISFeatures

            Register-LastDependencyCheck
        }
        else {
            Write-Caption 'Full dependencies were checked less than 24 hours ago, skipping new check...'
        }

        $databaseBuild = Get-BoolConfigValue -configKey 'databaseBuild' -defaultValue $false -warnIfMissing $false
        if ($runTypeLower -eq 'restore' -or $runTypeLower -eq 'dependencies' -and $databaseBuild -and ($databaseDependencyCheckRequired -or $forceUpdate.IsPresent)) {
            Write-Caption 'Running database dependency check...'

            Assert-DupDesigner
            Assert-DupLicense
            Assert-DupProcessor
            Assert-DBUpgrade
            Assert-dwDba
            Assert-DupPowerTools
            Assert-PlSqlDevTestRunner
            Assert-DataDictionaryTests
            Assert-DatamartUpgrade
            Assert-DatabaseReset

            Register-LastDependencyCheck -DatabaseBuild
        }
        else {
            Write-Caption 'Database dependencies were checked less than 24 hours ago, skipping new check...'
        }
    }

    if ($runTypeLower -eq 'fixscriptcs') {
        Repair-ScriptCS
    }

    Invoke-CustomBootstrapper
}

$useDotnetScript = Get-BoolConfigValue -configKey 'useDotnetScript' -defaultValue $true -warnIfMissing $false
if ($useDotnetScript) {
    Initialize-DotnetScript
}
else {
    Install-ScriptCsDependencies
}

if ($Global:installSummary.Count -eq 0) {
    Write-OK $('Finished installing packages for runtype ' + $runType + '.')
}
else {
    Write-Warning "The following package installations returned with exit codes indicating warnings or errors"
    $Global:installSummary | Format-Hashtable -KeyHeader "Package type and Id" -ValueHeader "Exit code" | Out-String | Write-Host -ForegroundColor Yellow
}

$bootstrapperExitCode = 0
foreach ($item in $Global:installSummary.GetEnumerator()) {
    if ($item.value -eq 1) {
        $bootstrapperExitCode = $item.value
        break
    }
    elseif ($item.value -eq 1641 -and $bootstrapperExitCode -ne 1) {
        $bootstrapperExitCode = $item.value
        break
    }
    elseif ($item.value -eq 3010 -and $bootstrapperExitCode -ne 1 -and $bootstrapperExitCode -ne 1640) {
        $bootstrapperExitCode = $item.value
        break
    }
    elseif ($item.value -ne 0) {
        $bootstrapperExitCode = $item.value
    }
}

$stopWatch.Stop()
Write-Host "Bootstrapper finished after $($stopWatch.Elapsed.TotalSeconds)s."

$Global:installSummary = @{}
$Global:installedPackages = @{}
exit $bootstrapperExitCode
