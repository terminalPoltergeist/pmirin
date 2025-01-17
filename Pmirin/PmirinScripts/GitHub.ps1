<#
    .SYNOPSIS
        Installs a module from a GitHub repository.

    .DESCRIPTION
        Installs a module from a GitHub repository.

        Relevant Dependency metadata:
            DependencyName (Key): The key for this dependency is used as Name, if none is specified
            Name: Used to specify the GitHub repository name to download
            Version: Used to identify existing installs meeting this criteria, and as RequiredVersion for installation.  Defaults to 'latest'
            Target: The folder to download repo to. Created if it doesn't exist.
                "AllUsers" resolves to:
                    Windows: the system's program files folder.
                    Other: the platform's SHARED_MODULES folder.
                "CurrentUser" resolves to:
                    Windows: the user's (My)Documents folder.
                    Other: the platform's USER_MODULES folder.
                It defaults to "AllUsers" on Windows in an elevated session and to "CurrentUser" otherwise.
                PowerShell uses the "WindowsPowerShell\Modules" folder hierarchy while PowerShell Core uses "PowerShell\Modules".


    .NOTES
        Initial idea and some code by Doug Finke. Rewrite by Jonas Thelemann for tag support and PowerShell Core compatibility.
        A huge thanks to both!
            https://github.com/dfinke/InstallModuleFromGitHub
            https://github.com/dargmuesli

    .PARAMETER PmirinAction
        Test, install or import the module. Defaults to "Install".

        Test: Return true or false on whether the dependency is in place.
        Install: Install the dependency.
        Import: Import the dependency.

    .PARAMETER ExtractPath
        Limit extraction of file(s) and folder(s).

    .PARAMETER ExtractProject
        Parse the GitHub repository for a common PowerShell project hierarchy and extract only the project folder.

        Example:  ramblingcookiemonster/psslack looks like this:
                  PSSlack/            Repo root
                    PSSlack/          Module root
                      PSSlack.psd1    Module manifest
                  Tests/

                  In this case, we would extract PSSlack/PSSlack only.

        Example:  bundyfx/vamp looks like this:
                  vamp/          Repo root (also, module root)
                    vamp.psd1    Module manifest

                  In this case, we would extract the whole root vamp folder.

    .PARAMETER TargetType
        How the target is interpreted:
            Standard: Extract to "target\name" [Default].
            Exact:    Extract to "target\".
            Parallel: Extract to "target\name\version" or "target\name\branch\name" depending on the version specified.

    .PARAMETER Force
        If specified, delete an already existing target folder (as defined by TargetType).
        Default: False / not specified. Files are copied to the target folder without any file or folder removal.

    .EXAMPLE
        Imagine a GitHub repository containing a PowerShell module with git tags named "1.0.0" and "0.1.0".

        @{
            'Dargmuesli/powershell-lib' = '1.0.0'
        }
        @{
            'Dargmuesli/powershell-lib' = 'latest'
        }
        @{
            'Dargmuesli/powershell-lib' = ''
        }
        These download version 1.0.0 to "powershell-lib\1.0.0"

        @{
            'Dargmuesli/powershell-lib' = '0.1.0'
        }
        This downloads version 0.1.0 to "powershell-lib\0.1.0"

        @{
            'Dargmuesli/powershell-lib' = 'master'
        }
        This downloads branch "master" (most recent commit version) to "powershell-lib"

    .EXAMPLE
        Imagine a GitHub repository containing a PowerShell module with no git tags.

        @{
            'Dargmuesli/powershell-lib' = 'latest'
        }
        @{
            'Dargmuesli/powershell-lib' = ''
        }
        @{
            'Dargmuesli/powershell-lib' = 'master'
        }
        These download branch "master" (most recent commit version) to "powershell-lib"

        @{
            'Dargmuesli/powershell-lib' = @{
                Version = 'latest'
                Parameters @{
                    TargetType = 'Parallel'
                }
            }
        }
        @{
            'Dargmuesli/powershell-lib' = @{
                Parameters @{
                    TargetType = 'Parallel'
                }
            }
        }
        @{
            'Dargmuesli/powershell-lib' = @{
                Version = 'master'
                Parameters @{
                    TargetType = 'Parallel'
                }
            }
        }
        These download branch "master" (most recent commit version) to "powershell-lib\master\powershell-lib"

        @{
            'Dargmuesli/powershell-lib' = @{
                Version = 'feature'
                Parameters @{
                    TargetType = 'Parallel'
                }
            }
        }
        This downloads branch "feature" (most recent commit version) to "powershell-lib\feature\powershell-lib"

    .EXAMPLE
        @{
            'powershell/demo_ci' = @{
                Version = 'latest'
                DependencyType = 'GitHub'
                Target = 'C:\T'
                Parameters = @{
                    ExtractPath = 'Assets/DscPipelineTools',
                                  'InfraDNS/Configs/DNSServer.ps1'
                    TargetType = 'Exact'
                }
            }
        }

        # This downloads the latest version of demo_ci by powershell from GitHub.
        # Then it extracts "repo-root/Assets/DscPipelineTools" and "repo-root/InfraDNS/Configs/DNSServer.ps1" to the target.
#>
[cmdletbinding()]
param(
    [PSTypeName('Pmirin.Dependency')]
    [psobject[]]$Dependency,

    [ValidateSet('Test', 'Install', 'Import')]
    [string[]]$PmirinAction = @('Install'),

    [string[]]$ExtractPath,

    [bool]$ExtractProject = $true,

    [ValidateSet('Parallel', 'Standard', 'Exact')]
    [string]$TargetType = 'Standard',

    [switch]$Force
)

$script:IsWindows = (-not (Get-Variable -Name "IsWindows" -ErrorAction "Ignore")) -or $IsWindows
$script:IsCoreCLR = $PSVersionTable.ContainsKey("PSEdition") -and $PSVersionTable.PSEdition -eq "Core"

Write-Verbose -Message "Am I on Windows? [$script:IsWindows]! Am I PS Core? [$script:IsCoreCLR]!"

# Extract data from dependency
$DependencyID = $Dependency.DependencyName
$DependencyVersion = $Dependency.Version
$DependencyTarget = $Dependency.Target
# if an alternative name is specified for the module, use that, otherwise use the dependency id name
if ($Dependency.Name) {
    $DependencyName = $Dependency.Name
} else {
    $DependencyName = $DependencyID.Split("/")[1]
}

# defaults to the latest version of the dependency
if($DependencyVersion -eq "") {
    $DependencyVersion = "latest"
}

# check if dependency version is a semantic version, with or without a 'v' prefix
#  NOTE: for the remainder of this script $DependencyVersion will be exactly when the user listed in the dependency file.
# ie. if the user specifies a dependency version of 'v1.0.0', $DependencyVersion will include the 'v'. This is necessary for retrieving the correct tag from GitHub.
# $SemanticVersion will be a System.Version type with only a major.minor.patch value. This distinction is made for easier comparison of versions.
if($DependencyVersion -match "^v?\d+(?:\.\d+)+$") {
    $match = $DependencyVersion | Select-String -Pattern "^v?(\d+(?:\.\d+)+)$"
    # extract and cast the version number from the dependency version
    $SemanticVersion = [System.Version]($match.Matches.Groups | Where-Object Name -eq 1).Value
}

if ($script:IsCoreCLR) {
    $ModuleChildPath = "PowerShell\Modules"
} else {
    $ModuleChildPath = "WindowsPowerShell\Modules"
}

# Get system installation path
if($script:IsWindows) {
    $AllUsersPath = Join-Path -Path $env:ProgramFiles -ChildPath $ModuleChildPath
} else {
    $AllUsersPath = [System.Management.Automation.Platform]::SelectProductNameForDirectory('SHARED_MODULES')
}

# Check if the MyDocuments folder path is accessible
try {
    $MyDocumentsFolderPath = [Environment]::GetFolderPath("MyDocuments")
} catch {
    $MyDocumentsFolderPath = $null
}

# Get user installation path
if($script:IsWindows) {
    if($MyDocumentsFolderPath) {
        $CurrentUserPath = Join-Path -Path $MyDocumentsFolderPath -ChildPath $ModuleChildPath
    } else {
        $CurrentUserPath = Join-Path -Path $HOME -ChildPath "Documents\$ModuleChildPath"
    }
} else {
    $CurrentUserPath = [System.Management.Automation.Platform]::SelectProductNameForDirectory('USER_MODULES')
}

# Set target path
if($DependencyTarget) {
    # Resolve scope keywords
    if($DependencyTarget -Eq "CurrentUser") {
        $TargetPath = $CurrentUserPath
    } elseif($DependencyTarget -Eq "AllUsers") {
        $TargetPath = $AllUsersPath
    } else {
        $TargetPath = $DependencyTarget
    }
} else {
    # Set default target depending on admin permissions
    if(($script:IsWindows) -And (([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator"))) {
        $TargetPath = $AllUsersPath
    } else {
        $TargetPath = $CurrentUserPath
    }
}

Write-Verbose -Message "Dependency id: [$DependencyID]"
Write-Verbose -Message "Dependency version: [$DependencyVersion]"
Write-Verbose -Message "Dependency semantic version: [$SemanticVersion]"
Write-Verbose -Message "Dependency target: [$DependencyTarget]"
Write-Verbose -Message "Dependency name: [$DependencyName]"
Write-Verbose -Message "Target Path: [$TargetPath]"

# Search for an already existing version of the dependency
$Module = Get-Module -ListAvailable -Name $DependencyName -ErrorAction SilentlyContinue
$ModuleExisting = $null
$ModuleExistingMatches = $false
$ExistingVersions = $null
$ShouldInstall = $false
$RemoteAvailable = $false
$URL = $null

if($Module) {
    $ModuleExisting = $true
} else {
    $ModuleExisting = $false
}

if($ModuleExisting) {
    Write-Verbose "Found existing module [$DependencyName]"
    [System.Version[]]$ExistingVersions = $Module | Select-Object -ExpandProperty "Version"

    if($null -ne $SemanticVersion) {
        :versionslocal foreach($ExistingVersion in $ExistingVersions) {
            switch($ExistingVersion.CompareTo($SemanticVersion)) {
                {@(-1, 1) -contains $_} {
                    Write-Verbose "For [$DependencyName], the version you specified [$SemanticVersion] does not match the already existing version [$ExistingVersion]"
                    $ShouldInstall = $true
                    break
                }
                0 {
                    Write-Verbose "For [$DependencyName], the version you specified [$SemanticVersion] matches the already existing version [$ExistingVersion]"
                    $ShouldInstall = $false
                    $ModuleExistingMatches = $true
                    break versionslocal
                }
            }
        }
    } else {
        # The version that is to be used is probably a GitHub branch name
        $ShouldInstall = $true
    }
} else {
    Write-Verbose "Did not find existing module [$DependencyName]"
    $ShouldInstall = $true
}

# Skip the case when the version that is to be used already exists
if($ShouldInstall) {
    # API-fetch the tags on GitHub
    $GitHubVersion = $null
    $GitHubTag = $null
    $Page = 0

    try {
        :nullcheck while($GitHubVersion -Eq $null) {
            $Page++
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
            try {
                $GitHubTags = Invoke-RestMethod -Uri "https://api.github.com/repos/$DependencyID/tags?per_page=100&page=$Page"
            } catch {
                if ($Dependency.Credential){
                    Write-Verbose -Message "Detected credential. Attempting to authenticate with GitHub."
                    $GitHubTags = Invoke-RestMethod -Uri "https://api.github.com/repos/$DependencyID/tags?per_page=100&page=$Page" -Headers @{"Authorization" = "Bearer $((New-Object pscredential 0,$Dependency.Credential).GetNetworkCredential().Password)"}
                } else {
                    throw $_
                }
            }

            if($GitHubTags) {
                foreach($GitHubTag in $GitHubTags) {
                    if($GitHubTag.name -match "^v?\d+(?:\.\d+)+$" -and ($SemanticVersion -or ($DependencyVersion -eq "latest"))) {
                        $match = $GitHubTag.Name | Select-String -Pattern "^v?(\d+(?:\.\d+)+)$"
                        $GitHubSemanticVersion = [System.Version]($match.Matches.Groups | Where-Object Name -eq 1).Value
                        $GitHubVersion = $GitHubTag.name

                        if($DependencyVersion -Eq "latest") {
                            $SemanticVersion = $GitHubSemanticVersion
                            $DependencyVersion = $GitHubVersion
                        }

                        switch($SemanticVersion.CompareTo($GitHubSemanticVersion)) {
                            -1 {
                                # Version is older compared to the GitHub version, continue searching
                                break
                            }
                            0 {
                                Write-Verbose "For [$DependencyName], a version matching [$DependencyVersion] has been found in the GitHub tags"
                                $RemoteAvailable = $true
                                break nullcheck
                            }
                            1 {
                                # Version is newer compared to the GitHub version, which means we can stop searching (given version history is reasonable)
                                break nullcheck
                            }
                        }
                    }
                }
            } else {
                break nullcheck
            }
        }
    } catch {
        # Repository does not seem to exist or a branch is the target
        $ShouldInstall = $false
        Write-Warning "Could not find module on GitHub: $_"
    }

    if($RemoteAvailable) {
        # Use the tag's link
        $URL = $GitHubTag.zipball_url
        if($ExistingVersions) {
            :versionsremote foreach($ExistingVersion in $ExistingVersions) {
                # Because a remote and a local version exist
                # Prevent a module from getting installed twice
                switch($ExistingVersion.CompareTo($GitHubSemanticVersion)) {
                    {@(-1, 1) -contains $_} {
                        Write-Verbose "For [$DependencyName], you have a different version [$ExistingVersion] compared to the version available on GitHub [$GitHubSemanticVersion]"
                        break
                    }
                    0 {
                        Write-Verbose "For [$DependencyName], you already have the version [$ExistingVersion]"
                        $ModuleExistingMatches = $true
                        $ShouldInstall = $false
                        break versionsremote
                    }
                }
            }
        }
    } else {
        Write-Verbose "[$DependencyID] has no tags on GitHub or [$DependencyVersion] is a branchname"
        try {
            $GitHubRepo = Invoke-RestMethod -Uri "https://api.github.com/repos/$DependencyID"
        } catch {
            if ($Dependency.Credential){
                Write-Verbose -Message "Detected credential. Attempting to authenticate with GitHub."
                $GitHubRepo = Invoke-RestMethod -Uri "https://api.github.com/repos/$DependencyID" -Headers @{"Authorization" = "Bearer $((New-Object pscredential 0,$Dependency.Credential).GetNetworkCredential().Password)"}
            } else {
                throw $_
            }
        }
        # Translate version "latest" to the default branch
        if($DependencyVersion -eq "latest") {
            $DependencyVersion = $GitHubRepo | Select-Object -ExpandProperty 'default_branch'
        }

        # Link for a .zip archive of the repository's branch
        $URL = "https://api.github.com/repos/$DependencyID/zipball/$DependencyVersion"
        $ShouldInstall = $true
    }
}

if ($TargetType -ne 'Exact') {
    $TargetPath = Join-Path $TargetPath $DependencyName
}

# Install action needs to be wanted and logical
if(($PmirinAction -contains 'Install') -and $ShouldInstall) {
    # Create a temporary directory and download the repository to it
    $OutPath = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().guid)
    New-Item -ItemType Directory -Path $OutPath -Force | Out-Null
    $OutFile = Join-Path $OutPath "$DependencyVersion.zip"
    if ($null -eq $Dependency.Credential) {
        Invoke-RestMethod -Uri $URL -OutFile $OutFile
    } else {
        Invoke-RestMethod -Uri $URL -OutFile $OutFile -Headers @{"Authorization" = "Bearer $((New-Object pscredential 0,$Dependency.Credential).GetNetworkCredential().Password)"}
    }

    if(-not (Test-Path $OutFile)) {
        Write-Error "Could not download [$URL] to [$OutFile]. See error details and verbose output for more information"
        return
    }

    # Extract the zip file
    if($script:IsWindows) {
        $ZipFile = (New-Object -com shell.application).NameSpace($OutFile)
        $ZipDestination = (New-Object -com shell.application).NameSpace($OutPath)
        $ZipDestination.CopyHere($ZipFile.Items())
    } else {
        # If not on Windows "Expand-Archive" should be available as PS version 6 is considered minimum.
        Expand-Archive $OutFile -DestinationPath $OutPath
    }

    # Remove the zip file
    Remove-Item $OutFile -Force -Confirm:$false

    $OutPath = (Get-ChildItem -Path $OutPath)[0].FullName
    $OutPath = (Rename-Item -Path $OutPath -NewName $DependencyName -PassThru).FullName
    if ($DependencyVersion -notmatch "^v?\d+(?:\.\d+)+$") {
        # safe to assume $DependencyVersion is a branch name, attempt to find the version
        $module = Get-Module -ListAvailable $(Get-ChildItem $OutPath -Recurse | Where-Object Name -Like "*.psd1" | Select-Object -ExpandProperty FullName) | Where-Object Name -eq $DependencyName 
        if ($null -ne $module) {
            $SemanticVersion = ($module | Select-Object -ExpandProperty Version).ToString()
            Write-Verbose -Message "For [$DependencyName] version [$DependencyVersion] found semantic version [$SemanticVersion]"
        } else {
            Write-Verbose -Message "Could not find a module with name [$DependencyName]."
        }
    }

    if($ExtractPath) {
        # Filter only the contents wanted
        [string[]]$ToCopy = foreach($RelativePath in $ExtractPath) {
            $AbsolutePath = Join-Path $OutPath $RelativePath
            if(-not (Test-Path $AbsolutePath)) {
                Write-Warning "Expected ExtractPath [$RelativePath], did not find at [$AbsolutePath]"
            } else {
                $AbsolutePath
            }
        }
    } elseif($ExtractProject) {
        # Filter only the project contents
        $ProjectDetails = Get-ProjectDetail -Path $OutPath
        [string[]]$ToCopy = $ProjectDetails.Path
    } else {
        # Use the standard download path
        [string[]]$ToCopy = $OutPath
    }

    Write-Verbose "Contents that will be copied: $ToCopy"

    # Copy the contents to their target
    if(-not (Test-Path $TargetPath)) {
        New-Item $TargetPath -ItemType "directory" -Force
    }

    $Destination = $null

    if($TargetType -eq 'Exact') {
        $Destination = $TargetPath
    } elseif($SemanticVersion -match "^\d+(?:\.\d+)+$" -and $PSVersionTable.PSVersion -ge '5.0'  ) {
        # For versioned GitHub tags
        $Destination = Join-Path $TargetPath $SemanticVersion
    } elseif(($DependencyVersion -eq "latest") -and ($RemoteAvailable) -and $PSVersionTable.PSVersion -ge '5.0' ) {
        # For latest GitHub tags
        $Destination = Join-Path $TargetPath $GitHubSemanticVersion
    } elseif($PSVersionTable.PSVersion -ge '5.0' -and $TargetType -eq 'Parallel') {
        # For GitHub branches
        $Destination = Join-Path $TargetPath $SemanticVersion
    } else {
        $Destination = $TargetPath
    }

    if($Force -and (Test-Path -Path $Destination)) {
        Remove-Item -Path $Destination -Force -Recurse
    }

    Write-Verbose "Copying [$($ToCopy.Count)] items to destination [$Destination] with`nTarget [$TargetPath]`nName [$DependencyName]`nVersion [$DependencyVersion]`nGitHubVersion [$GitHubVersion]"

    foreach($Item in $ToCopy) {
        Copy-Item -Path $Item -Destination $Destination -Force -Recurse
    }

    # Delete the temporary folder
    Remove-Item (Get-Item $OutPath).parent.FullName -Force -Recurse
    $ModuleExisting = $true
}

# Conditional import
if($ModuleExisting) {
    Import-PmirinModule -Name $TargetPath -Action $PmirinAction
} elseif($PmirinAction -contains 'Import') {
    Write-Warning "[$DependencyName] at [$TargetPath] should be imported, but does not exist"
}

# Return true or false if Test action is wanted
if($PmirinAction -contains 'Test') {
    return $ModuleExistingMatches
}

# Otherwise return null
return $null
