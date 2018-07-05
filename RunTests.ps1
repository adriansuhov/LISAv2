##############################################################################################
# RunTests.ps1
# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.
# Description : 
# Operations :
#              
## Author : v-shisav@microsoft.com, lisasupport@microsoft.com
###############################################################################################
[CmdletBinding()]
Param(
    # Mandatory parameters
    [parameter(Mandatory=$true)]
    [ValidateSet("Azure", "HyperV")]
    [string] $TestPlatform,

    # One of these params are mandatory
    [parameter(Mandatory=$false)]
    [string] $TestCategory,
    [parameter(Mandatory=$false)]
    [string] $TestArea,
    [parameter(Mandatory=$false)]
    [string] $TestTag,
    [parameter(Mandatory=$false)]
    [string] $TestNames,

    # Do not use. Reserved for Jenkins use.
    # Note(v-advlad): This parameter's default value might not be enough
    #   to allow for unique builds
    [parameter(Mandatory=$false)]
    [string] $BuildNumber = $env:BUILD_NUMBER,

    # Required for Hyper-V platform
    # Required for Azure platform if ARMImageName is not provided
    [parameter(Mandatory=$false)]
    [string] $OsVHD,

    # Required for Azure platform
    [parameter(Mandatory=$false)]
    [string] $TestLocation,
    # Required for Hyper-V platform too ??
    [parameter(Mandatory=$false)]
    [string] $RGIdentifier,
    [parameter(Mandatory=$false)]
    [string] $ARMImageName,
    [parameter(Mandatory=$false)]
    [string] $StorageAccount,

    # Parameters for image preparation before running tests
    [parameter(Mandatory=$false)]
    [string] $CustomKernel,
    [parameter(Mandatory=$false)]
    [string] $CustomLIS,

    # Parameters for changing framework behaviour
    [parameter(Mandatory=$false)]
    [string] $CoreCountExceededTimeout,
    [parameter(Mandatory=$false)]
    [int] $TestIterations,
    [parameter(Mandatory=$false)]
    [string] $TiPSessionId,
    [parameter(Mandatory=$false)]
    [string] $TiPCluster,
    [parameter(Mandatory=$false)]
    [string] $XMLSecretFile,
    [parameter(Mandatory=$false)]
    [switch] $EnableTelemetry,
    [parameter(Mandatory=$false)]
    [switch] $ExitWithZero,

    # Parameters for dynamically updating XML config files
    [parameter(Mandatory=$false)]
    [switch] $UpdateGlobalConfigurationFromSecretsFile,
    [parameter(Mandatory=$false)]
    [switch] $UpdateXMLStringsFromSecretsFile,

    # Parameters for overriding VM Configuration on Azure platform
    [parameter(Mandatory=$false)]
    [string] $OverrideVMSize,
    [parameter(Mandatory=$false)]
    [switch] $EnableAcceleratedNetworking,
    [parameter(Mandatory=$false)]
    [string] $OverrideHyperVDiskMode,
    [parameter(Mandatory=$false)]
    [switch] $ForceDeleteResources,
    [parameter(Mandatory=$false)]
    [switch] $UseManagedDisks,
    [parameter(Mandatory=$false)]
    [switch] $DoNotDeleteVMs,

    # Parameters for database results logging
    [parameter(Mandatory=$false)]
    [string] $ResultDBTable,
    [parameter(Mandatory=$false)]
    [string] $ResultDBTestTag
)

$WorkingDirectory = Split-Path -Parent $MyInvocation.MyCommand.Definition

# Import common functions
Get-ChildItem (Join-Path $WorkingDirectory  "Libraries") -Recurse | Where-Object { $_.FullName.EndsWith(".psm1") } `
    | ForEach-Object { Import-Module $_.FullName -Force -Global }


# Local functions

function Get-ShortRandomNumber {
  return (Get-Random -Maximum 99999 -Minimum 11111)
}

function Get-ShortRandomWord {
  return (-join ((65..90) | Get-Random -Count 4 | ForEach-Object {[char]$_}))
}


# Start running testing framework
try {
    # Clean the PowerShell environment variables
    $parameterList = (Get-Command -Name $PSCmdlet.MyInvocation.InvocationName).Parameters
    foreach ($parameter in $parameterList.keys) {
        $var = Get-Variable -Name $parameter -ErrorAction SilentlyContinue
        if ($var) {
            Set-Variable -Name $($var.name) -Value $($var.value) -Scope Global -Force
        }
    }

    # Create required folders
    $LogDir = Join-Path $WorkingDirectory ("TestResults\{0}" -f @(Get-Date -Format "yyyy-dd-MM-HH-mm-ss-ffff"))
    Set-Variable -Name "LogDir" -Value $LogDir -Scope Global -Force
    Set-Variable -Name "RootLogDir" -Value $LogDir -Scope Global -Force
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $WorkingDirectory "Temp") -Force `
             -ErrorAction SilentlyContinue | Out-Null
    LogMsg "Created LogDir: $LogDir"

    # Set static global variables
    Set-Variable -Name "WorkingDirectory" -Value $WorkingDirectory  -Scope Global
    Set-Variable -Name "shortRandomNumber" -Value (Get-ShortRandomNumber) -Scope Global
    Set-Variable -Name "shortRandomWord" -Value (Get-ShortRandomWord) -Scope Global

    # Set runtime global variables
    if ($Verbose) {
        $VerboseCommand = "-Verbose"
        Set-Variable -Name "VerboseCommand" -Value $VerboseCommand -Scope Global
    } else {
        Set-Variable -Name "VerboseCommand" -Value "" -Scope Global
    }

    # Note(v-advlad): why not put the params' validation before anything else?
    ValidateParameters

    # Note(v-advlad): Fix typo
    ValiateXMLs -ParentFolder $WorkingDirectory

    UpdateGlobalConfigurationXML

    UpdateXMLStringsFromSecretsFile


    #region Local Variables
    $testXMLs = Get-ChildItem -Path "$WorkingDirectory\XML\TestCases\*.xml"
    $setupTypeXMLs = Get-ChildItem -Path "$WorkingDirectory\XML\VMConfigurations\*.xml"

    # Note(v-advlad): Why are you exploding arm image params? Are there more than one?
    # This should be done only for Azure platform
    $armImage = $ARMImageName.Split(" ")
    $xmlFile = "$WorkingDirectory\TestConfiguration.xml"

    # Note(v-advlad): This part makes no sense
    if ( $TestCategory -eq "All")
    {
        $TestCategory = ""
    }
    if ( $TestArea -eq "All")
    {
        $TestArea = ""
    }
    if ( $TestNames -eq "All")
    {
        $TestNames = ""
    }
    if ( $TestTag -eq "All")
    {
        $TestTag = ""
    }

    # Collect all XML files from working directory
    $allTests = CollectTestCases -TestXMLs $TestXMLs

    #region Create Test XML
    $SetupTypes = $allTests.SetupType | Sort-Object | Get-Unique

    # Note(v-advlad): This part makes no sense, with tabs and all
    # The PowerShell XML parser should be used instead
    $tab = CreateArrayOfTabs

    $TestCycle = "TC-{0}" -f @($shortRandomNumber)

    $GlobalConfiguration = [xml](Get-content .\XML\GlobalConfigurations.xml)
    <##########################################################################
    We're following the Indentation of the XML file to make XML creation easier.
    ##########################################################################>
    $xmlContent =  ("$($tab[0])" + '<?xml version="1.0" encoding="utf-8"?>')
    $xmlContent += ("$($tab[0])" + "<config>`n") 
    $xmlContent += ("$($tab[0])" + "<CurrentTestPlatform>$TestPlatform</CurrentTestPlatform>`n")


    # Azure platform specific code
    if ($TestPlatform -eq "Azure") {
        $xmlContent += ("$($tab[1])" + "<Azure>`n") 

        #region Add Subscription Details
        $xmlContent += ("$($tab[2])" + "<General>`n")
        foreach ( $line in $GlobalConfiguration.Global.$TestPlatform.Subscription.InnerXml.Replace("><",">`n<").Split("`n")) {
            $xmlContent += ("$($tab[3])" + "$line`n")
        }
        $xmlContent += ("$($tab[2])" + "<Location>$TestLocation</Location>`n")
        $xmlContent += ("$($tab[2])" + "</General>`n")
        #endregion

        #region Database details
        $xmlContent += ("$($tab[2])" + "<database>`n")
        foreach ( $line in $GlobalConfiguration.Global.$TestPlatform.ResultsDatabase.InnerXml.Replace("><",">`n<").Split("`n")) {
            $xmlContent += ("$($tab[3])" + "$line`n")
        }
        $xmlContent += ("$($tab[2])" + "</database>`n")
        #endregion

        #region Deployment details
        $xmlContent += ("$($tab[2])" + "<Deployment>`n")
        $xmlContent += ("$($tab[3])" + "<Data>`n")
        $xmlContent += ("$($tab[4])" + "<Distro>`n")
        $xmlContent += ("$($tab[5])" + "<Name>$RGIdentifier</Name>`n")
        $xmlContent += ("$($tab[5])" + "<ARMImage>`n")
        $xmlContent += ("$($tab[6])" + "<Publisher>" + "$($ARMImage[0])" + "</Publisher>`n")
        $xmlContent += ("$($tab[6])" + "<Offer>" + "$($ARMImage[1])" + "</Offer>`n")
        $xmlContent += ("$($tab[6])" + "<Sku>" + "$($ARMImage[2])" + "</Sku>`n")
        $xmlContent += ("$($tab[6])" + "<Version>" + "$($ARMImage[3])" + "</Version>`n")
        $xmlContent += ("$($tab[5])" + "</ARMImage>`n")
        $xmlContent += ("$($tab[5])" + "<OsVHD>" + "$OsVHD" + "</OsVHD>`n")
        $xmlContent += ("$($tab[4])" + "</Distro>`n")
        $xmlContent += ("$($tab[4])" + "<UserName>" + "$($GlobalConfiguration.Global.$TestPlatform.TestCredentials.LinuxUsername)" + "</UserName>`n")
        $xmlContent += ("$($tab[4])" + "<Password>" + "$($GlobalConfiguration.Global.$TestPlatform.TestCredentials.LinuxPassword)" + "</Password>`n")
        $xmlContent += ("$($tab[3])" + "</Data>`n")

        foreach ($file in $SetupTypeXMLs.FullName) {
            foreach ( $SetupType in $SetupTypes ) {
                $CurrentSetupType = ([xml]( Get-Content -Path $file)).TestSetup
                if ($CurrentSetupType.$SetupType -ne $null) {
                    $SetupTypeElement = $CurrentSetupType.$SetupType
                    $xmlContent += ("$($tab[3])" + "<$SetupType>`n")
                    foreach ( $line in $SetupTypeElement.InnerXml.Replace("><",">`n<").Split("`n")) {
                        $xmlContent += ("$($tab[4])" + "$line`n")
                    }
                    $xmlContent += ("$($tab[3])" + "</$SetupType>`n")
                }
            }
        }
        $xmlContent += ("$($tab[2])" + "</Deployment>`n")
        #endregion

        $xmlContent += ("$($tab[1])" + "</Azure>`n")
    } elseif ($TestPlatform -eq "HyperV") {
        $xmlContent += ("$($tab[1])" + "<Hyperv>`n") 

        #region Add Subscription Details
        $xmlContent += ("$($tab[2])" + "<Host>`n")
        foreach ( $line in $GlobalConfiguration.Global.HyperV.Host.InnerXml.Replace("><",">`n<").Split("`n")) {
            $xmlContent += ("$($tab[3])" + "$line`n")
        }
        $xmlContent += ("$($tab[2])" + "</Host>`n")
        #endregion

        #region Database details
        $xmlContent += ("$($tab[2])" + "<database>`n")
        foreach ( $line in $GlobalConfiguration.Global.HyperV.ResultsDatabase.InnerXml.Replace("><",">`n<").Split("`n")) {
          $xmlContent += ("$($tab[3])" + "$line`n")
        }
        $xmlContent += ("$($tab[2])" + "</database>`n")
        #endregion

        #region Deployment details
        $xmlContent += ("$($tab[2])" + "<Deployment>`n")
        $xmlContent += ("$($tab[3])" + "<Data>`n")
        $xmlContent += ("$($tab[4])" + "<Distro>`n")
        $xmlContent += ("$($tab[5])" + "<Name>$RGIdentifier</Name>`n")
        $xmlContent += ("$($tab[5])" + "<ARMImage>`n")
        $xmlContent += ("$($tab[6])" + "<Publisher>" + "$($ARMImage[0])" + "</Publisher>`n")
        $xmlContent += ("$($tab[6])" + "<Offer>" + "$($ARMImage[1])" + "</Offer>`n")
        $xmlContent += ("$($tab[6])" + "<Sku>" + "$($ARMImage[2])" + "</Sku>`n")
        $xmlContent += ("$($tab[6])" + "<Version>" + "$($ARMImage[3])" + "</Version>`n")
        $xmlContent += ("$($tab[5])" + "</ARMImage>`n")
        $xmlContent += ("$($tab[5])" + "<OsVHD>" + "$OsVHD" + "</OsVHD>`n")
        $xmlContent += ("$($tab[4])" + "</Distro>`n")
        $xmlContent += ("$($tab[4])" + "<UserName>" + "$($GlobalConfiguration.Global.$TestPlatform.TestCredentials.LinuxUsername)" + "</UserName>`n")
        $xmlContent += ("$($tab[4])" + "<Password>" + "$($GlobalConfiguration.Global.$TestPlatform.TestCredentials.LinuxPassword)" + "</Password>`n")
        $xmlContent += ("$($tab[3])" + "</Data>`n")

        foreach ($file in $SetupTypeXMLs.FullName) {
            foreach ($SetupType in $SetupTypes) {
                $CurrentSetupType = ([xml]( Get-Content -Path $file)).TestSetup
                if ( $CurrentSetupType.$SetupType -ne $null) {
                    $SetupTypeElement = $CurrentSetupType.$SetupType
                    $xmlContent += ("$($tab[3])" + "<$SetupType>`n")
                    foreach ( $line in $SetupTypeElement.InnerXml.Replace("><",">`n<").Split("`n")) {
                        $xmlContent += ("$($tab[4])" + "$line`n")
                    }
                    $xmlContent += ("$($tab[3])" + "</$SetupType>`n")
                }
            }
        }
        $xmlContent += ("$($tab[2])" + "</Deployment>`n")
        #endregion

        $xmlContent += ("$($tab[1])" + "</Hyperv>`n")
    }

    #region TestDefinition
    $xmlContent += ("$($tab[1])" + "<testsDefinition>`n")
    foreach ($currentTest in $allTests) {
        if ($currentTest.Platform.Contains($TestPlatform)) {
            $xmlContent += ("$($tab[2])" + "<test>`n")
            foreach ($line in $currentTest.InnerXml.Replace("><",">`n<").Split("`n")) {
                $xmlContent += ("$($tab[3])" + "$line`n")
            }
            $xmlContent += ("$($tab[2])" + "</test>`n")
        } else {
            LogErr "*** UNSUPPORTED TEST *** : $currentTest. Skipped."
        }
    }
    $xmlContent += ("$($tab[1])" + "</testsDefinition>`n")
    #endregion

    #region TestCycle
    $xmlContent += ("$($tab[1])" + "<testCycles>`n")
    $xmlContent += ("$($tab[2])" + "<Cycle>`n")
    $xmlContent += ("$($tab[3])" + "<cycleName>$TestCycle</cycleName>`n")
    foreach ($currentTest in $allTests) {
        $line = $currentTest.TestName
        $xmlContent += ("$($tab[3])" + "<test>`n")
        $xmlContent += ("$($tab[4])" + "<Name>$line</Name>`n")
        $xmlContent += ("$($tab[3])" + "</test>`n")
    }
    $xmlContent += ("$($tab[2])" + "</Cycle>`n")
    $xmlContent += ("$($tab[1])" + "</testCycles>`n")
    #endregion

    $xmlContent += ("$($tab[0])" + "</config>`n") 
    Set-Content -Value $xmlContent -Path $xmlFile -Force

    try {
        $xmlConfig = [xml](Get-Content $xmlFile)
        $xmlConfig.Save("$xmlFile")
        LogMsg "Auto created $xmlFile validated successfully."
    } catch {
        throw "Framework error: $xmlFile is not valid. Please report to lisasupport@microsoft.com"
    }
    #endregion

    #region Prepare execution command

    $command = ".\AutomationManager.ps1 -xmlConfigFile '{0}' -cycleName '{1}' -RGIdentifier '{2}' -runtests -UseAzureResourceManager" `
        -f @($xmlFile, $TestCycle, $RGIdentifier)

    if ($CustomKernel) {
        $command += " -CustomKernel '$CustomKernel'"
    }
    if ($OverrideVMSize) {
        $command += " -OverrideVMSize $OverrideVMSize"
    }
    if ($EnableAcceleratedNetworking) {
        $command += " -EnableAcceleratedNetworking"
    }
    if ($ForceDeleteResources) {
        $command += " -ForceDeleteResources"
    }
    if ($DoNotDeleteVMs) {
        $command += " -DoNotDeleteVMs"
    }
    if ($CustomLIS) {
        $command += " -CustomLIS $CustomLIS"
    }
    if ($CoreCountExceededTimeout) {
        $command += " -CoreCountExceededTimeout $CoreCountExceededTimeout"
    }
    if ($TestIterations -gt 1) {
        $command += " -TestIterations $TestIterations"
    }
    if ($TiPSessionId) {
        $command += " -TiPSessionId $TiPSessionId"
    }
    if ($TiPCluster) {
        $command += " -TiPCluster $TiPCluster"
    }
    if ($UseManagedDisks) {
        $command += " -UseManagedDisks"
    }
    if ($XMLSecretFile) {
        $command += " -XMLSecretFile '$XMLSecretFile'"
    }

    LogMsg $command
    Invoke-Expression -Command $command

    $zipFile = "$TestPlatform"
    if ( $TestCategory ) {
        $zipFile += "-$TestCategory"
    }
    if ($TestArea) {
        $zipFile += "-$TestArea"
    }
    if ($TestTag) {
        $zipFile += "-$($TestTag)"
    }
    $zipFile += "-$shortRandomNumber-buildlogs.zip"
    $out = ZipFiles -zipfilename $zipFile -sourcedir $LogDir

    try {
        if (Test-Path -Path ".\report\report_$(($TestCycle).Trim()).xml" ) {
            $resultXML = [xml](Get-Content ".\report\report_$(($TestCycle).Trim()).xml" `
                               -ErrorAction SilentlyContinue)
            Copy-Item -Path ".\report\report_$(($TestCycle).Trim()).xml" `
                      -Destination ".\report\report_$(($TestCycle).Trim())-junit.xml" `
                      -Force -ErrorAction SilentlyContinue
            LogMsg "Copied: .\report\report_$(($TestCycle).Trim()).xml --> .\report\report_$(($TestCycle).Trim())-junit.xml"
            LogMsg "Analysing results.."
            LogMsg "PASS: $($resultXML.testsuites.testsuite.tests - $resultXML.testsuites.testsuite.errors - $resultXML.testsuites.testsuite.failures)"
            LogMsg "FAIL: $($resultXML.testsuites.testsuite.failures)"
            LogMsg "ABORT: $($resultXML.testsuites.testsuite.errors)"
            if ( ( $resultXML.testsuites.testsuite.failures -eq 0 ) `
                   -and ( $resultXML.testsuites.testsuite.errors -eq 0 ) `
                   -and ( $resultXML.testsuites.testsuite.tests -gt 0 )) {
                $ExitCode = 0
            } else {
                $ExitCode = 1
            }
        } else {
            LogMsg "Summary file: .\report\report_$(($TestCycle).Trim()).xml does not exist. Exiting with 1."
            $ExitCode = 1
        }
    } catch {
        LogMsg "$($_.Exception.GetType().FullName, " : ",$_.Exception.Message)"
        $ExitCode = 1
    } finally {
        if ($ExitWithZero -and ($ExitCode -ne 0)) {
            LogMsg "Changed exit code from 1 --> 0. (-ExitWithZero mentioned.)"
            $ExitCode = 0
        }
        LogMsg "Exiting with code : $ExitCode"
    }
} catch {
    $line = $_.InvocationInfo.ScriptLineNumber
    $scriptName = ($_.InvocationInfo.ScriptName).Replace($WorkingDirectory, ".")
    $ErrorMessage =  $_.Exception.Message
    LogMsg "EXCEPTION : ${ErrorMessage}"
    LogMsg "Source: Line $line in script ${scriptName}."
    $ExitCode = 1
} finally {
    Get-Variable -Scope Global | Remove-Variable -Force -ErrorAction SilentlyContinue
    exit $ExitCode
}
