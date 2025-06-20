# Initialize
$VerbosePreference = "SilentlyContinue"
$ProgressPreference = "SilentlyContinue"
$ErrorActionPreference = "SilentlyContinue"

# Add References
Add-Type -AssemblyName System.Web
Add-Type -AssemblyName Microsoft.VisualBasic
Add-Type -AssemblyName System.IO.Compression.FileSystem

# Add Classes Root Driver
If (!(Test-Path "HKCR:")) { New-PSDrive -Name HKCR -PSProvider Registry -Root HKEY_CLASSES_ROOT | Out-Null }

# Function to Expand Files
Function Expand-Files {

    Param(
        [Parameter(Mandatory = $True)][String]$SourcePath,
        [Parameter(Mandatory = $True)][String]$DestinationPath,
        [Switch]$Force
    )
    
    $Encoding = [System.Text.Encoding]::GetEncoding((Get-Culture).TextInfo.OEMCodePage)
    $Contents = [System.IO.Compression.ZipFile]::Open($SourcePath, "Read", $Encoding)
    $Contents.Entries.FullName | ForEach-Object { If ($Force) { Remove-Item "$DestinationPath\$_" -Recurse -Force -ErrorAction Ignore } }
    $Contents.Dispose()

    [System.IO.Compression.ZipFile]::ExtractToDirectory($SourcePath, $DestinationPath, $Encoding)

}

# Function to Update Files
Function Update-Files {

    $FileDir = "C:\Startup\OneDrive"
    $TempDir = "C:\Startup\OneDriveTemp"
    $FileZip = "$TempDir\$Global:TenantName.zip"
    $FileUrl = "https://raw.githubusercontent.com/thewerthon/OneDriveSync/main/Setup/$Global:TenantName.exe"

    New-Item -Path $TempDir -ItemType Directory -ErrorAction Ignore | Out-Null
    New-Item -Path $FileDir -ItemType Directory -ErrorAction Ignore | Out-Null

    Try {

        Invoke-WebRequest -Uri $FileUrl -OutFile $FileZip
        Expand-Files -SourcePath $FileZip -DestinationPath $TempDir -Force
        Remove-Item -Path $FileZip -Force

        $CheckFolder = Test-Path "$TempDir\$Global:TenantName" -PathType Container
        $CheckParams = [bool](Get-Content -Path "$TempDir\$Global:TenantName\Params.json" | ConvertFrom-Json)
        $CheckScript = [bool]((Get-Content "$TempDir\OneDriveSync.ps1") -Match "Update-Files")
        
        If ($CheckFolder -And $CheckParams -And $CheckScript) {
            
            Copy-Item -Path "$TempDir\*" -Destination $FileDir -Recurse -Force
        
        }

    } Finally {

        Remove-Item -Path $TempDir -Recurse -Force

    }

}

# Function to Create AuthToken
Function New-AuthToken {

    Try {

        $Uri = "https://login.microsoftonline.com/$Global:TenantID/oauth2/token"
        $Content = "grant_type=client_credentials&client_id=$Global:ClientID&client_secret=" + ($Global:ClientSecret).Replace("+", "%2B") + "&resource=https://graph.microsoft.com"
        $Response = Invoke-RestMethod -Uri $Uri -Body $Content -Method Post -UseBasicParsing
        
        If ($Response.Access_Token) {

            Return @{
                'Content-Type'  = 'application/json'
                'Authorization' = "Bearer " + $Response.Access_Token
                'ExpiresOn'     = $Response.Expires_On
            }

        } Else {

            Write-Host "Failed to create access token." -ForegroundColor Red
            Return $Null

        }

    } Catch {

        Write-Host "Fatal web error in New-AuthToken function." -ForegroundColor Red
        Return $Null

    }

}

# Function to Get AuthToken
Function Get-AuthToken {

    If ($Global:AuthToken) {

        $CurrentTimeUnix = $((Get-Date ([DateTime]::UtcNow) -UFormat +%s)).split((Get-Culture).NumberFormat.NumberDecimalSeparator)[0]
        $TokenExpires = [MATH]::floor(([int]$AuthToken.ExpiresOn - [int]$CurrentTimeUnix) / 60)
        If ($TokenExpires -le 0) { $Global:AuthToken = New-AuthToken }

    } Else {

        $Global:AuthToken = New-AuthToken

    }

}

# Function to Get OneDrive Account
Function Get-OneDriveAccount {
	
    $Accounts = Get-ChildItem -Path "HKCU:\Software\Microsoft\OneDrive\Accounts" -ErrorAction Ignore | Where-Object { $_.Name -Match "Business" }
	
    ForEach ($Account In $Accounts) {
		
        $Tenant = Get-ItemProperty -Path "Registry::$($Account.Name)" -ErrorAction Ignore | Select-Object -ExpandProperty ConfiguredTenantId -ErrorAction Ignore
        If ($Tenant -eq $Global:TenantID) { Return $Account; Break }
		
    }
	
}

# Function to Get OneDrive Account Property
Function Get-OneDriveAccountProperty {
    
    Param (
        [Parameter(Mandatory = $True)]
        [String]$Property
    )
    
    If ($Null -eq $Global:OneDriveAccount) { $Global:OneDriveAccount = Get-OneDriveAccount }
    Return (Get-ItemProperty -Path "Registry::$($OneDriveAccount.Name)" -Name $Property -ErrorAction Ignore | Select-Object -ExpandProperty $Property -ErrorAction Ignore)
    
}

# Function to Get Unified Groups
Function Get-UnifiedGroups() {

    Try {

        Get-AuthToken
        $Uri = "https://graph.microsoft.com/v1.0/users/$Global:UserEmail/memberOf"
        Return (Invoke-RestMethod -Uri $Uri -Headers $AuthToken -Method Get).Value

    } Catch {

        Write-Host "Fatal web error in Get-UnifiedGroups function." -ForegroundColor Red
        Return $Null

    }

}

# Function to Get Mount Points
Function Get-MountPoints {
	
    If ($Null -eq $Global:OneDriveAccount) { $Global:OneDriveAccount = Get-OneDriveAccount }
    $MountPoints = Get-Item -Path "Registry::$($OneDriveAccount.Name)\Tenants\$TenantName" -ErrorAction Ignore | Select-Object -ExpandProperty Property -ErrorAction Ignore
    Return $MountPoints
	
}

# Function to Get OneDrive Status
Function Get-OneDriveStatus {
	
    If ($Null -eq $Global:OneDriveAccount) { $Global:OneDriveAccount = Get-OneDriveAccount }
	
    $OneDriveAccountStatus = !([String]::IsNullOrEmpty($OneDriveAccount))
    $OneDriveProcessStatus = !([String]::IsNullOrEmpty((Get-Process OneDrive -ErrorAction Ignore)))	
    $OneDriveFirstRunEntry = (Get-ItemProperty -Path "Registry::$($OneDriveAccount.Name)" -Name "FirstRun" -ErrorAction Ignore | Select-Object -ExpandProperty "FirstRun" -ErrorAction Ignore) -eq 1
    
    Return ($OneDriveProcessStatus -And $OneDriveAccountStatus -And $OneDriveFirstRunEntry)
	
}

# Load Params Files
If ($Args[0] -Like "*.json") { $ParamFiles = Get-Item -Path $Args[0] } Else { $ParamFiles = Get-ChildItem "C:\Startup\OneDrive\*\Params.json" -Recurse -Depth 1 -Force }

# Execute Sync for Each Param File
ForEach ($ParamFile In $ParamFiles) {
    
    # Load Params
    $Params = Get-Content -Path $ParamFile.FullName | ConvertFrom-Json
    
    # Set Primary Variables
    $Global:TenantID = $Params.TenantID
    $Global:TenantName = $Params.TenantName
    $Global:TenantDomain = $Params.TenantDomain
    $Global:ClientID = $Params.ClientID
    $Global:ClientSecret = $Params.ClientSecret
    $Global:OneDrivePath1 = "C:\Program Files\Microsoft OneDrive\OneDrive.exe"
    $Global:OneDrivePath2 = "$($Env:LocalAppData)\Microsoft\OneDrive\OneDrive.exe"

    # Update Files
    Update-Files
    Start-Sleep -Seconds 1
    $Params = Get-Content -Path $ParamFile.FullName | ConvertFrom-Json

    # Check if OneDrive is installed
    If (Test-Path $OneDrivePath1) { $Global:OneDrivePath = $OneDrivePath1 }
    If (Test-Path $OneDrivePath2) { $Global:OneDrivePath = $OneDrivePath2 }
    If ($Null -eq $Global:OneDrivePath) { Write-Host "OneDrive is not installed in $OneDrivePath." -ForegroundColor Red; Exit 1 }

    # Wait Before Setup
    If (!(Get-OneDriveStatus)) {
		
        $Attempts = 0
        Start-Process $OneDrivePath -ArgumentList "/background"
		
        Do {
			
            $Attempts++
            Start-Sleep -Seconds 5
            If (Get-OneDriveStatus) { Break }

        } Until ( $Attempts -ge 12 )
		
    }

    # Start OneDrive Setup
    If (!(Get-OneDriveStatus)) {
		
        $UserUPN = WhoAmI /UPN 2>$Null

        If ($UserUPN) {

            $Attempts = 0
            Write-Host "Waiting account setup for $UserUPN..." -ForegroundColor Cyan
            Start-Process "odopen://sync?useremail=$UserUPN"
		
            Do {
			
                $Attempts++
                Start-Sleep -Seconds 30
                If (Get-OneDriveStatus) { Break }
			
            } Until ( $Attempts -ge 6)

        }
        
    }
    
    # Exit Script if OneDrive Is Not Setted Up
    If (!(Get-OneDriveStatus)) {
		
        Write-Host "OneDrive is not setted up." -ForegroundColor Red
        Exit 1
		
    }

    # Set Secondary Variables
    $Global:AuthToken = New-AuthToken
    $Global:OneDriveAccount = Get-OneDriveAccount
    
    # Set Tertiary Variables
    $Global:UserId = Get-OneDriveAccountProperty -Property "cid"
    $Global:UserName = Get-OneDriveAccountProperty -Property "UserName"
    $Global:UserEmail = Get-OneDriveAccountProperty -Property "UserEmail"
    $Global:TenantName = Get-OneDriveAccountProperty -Property "DisplayName"

    # Set Quaternary Variables
    $Global:UnifiedGroups = Get-UnifiedGroups
    $Global:MountPoints = Get-MountPoints
    $Global:SyncPath = Join-Path -Path $Env:UserProfile -ChildPath $TenantName

    # Start Sync
    Write-Host "OneDrive Sync for $TenantName..." -ForegroundColor Cyan

    # Remove Folders
    ForEach ($Folder In $Params.RemoveFolders) {
		
        $Path = "$SyncPath\$Folder"
        $IsSynced = !([String]::IsNullOrEmpty($MountPoints)) -And ($MountPoints -Match $Folder)
		
        If (Test-Path $Path) {
            If (!$IsSynced) {
                Write-Host ">> Removing $Folder..." -ForegroundColor Magenta
                icacls $Path /reset /t /c /q | Out-Null
                Remove-Item $Path -Recurse -Force -ErrorAction Ignore
            }
        }
		
    }

    # Sync Folders
    $SyncFolders = $Params.DefaultFolders + $Params.TeamsFolders
    ForEach ($SyncFolder In $SyncFolders) {

        # Set Folder Variables
        $SiteId = [System.Web.HttpUtility]::UrlEncode($SyncFolder.SiteId).Replace("+", "%20")
        $WebId = [System.Web.HttpUtility]::UrlEncode($SyncFolder.WebId).Replace("+", "%20")
        $WebUrl = [System.Web.HttpUtility]::UrlEncode($SyncFolder.WebUrl).Replace("+", "%20")
        $ListId = [System.Web.HttpUtility]::UrlEncode($SyncFolder.ListId).Replace("+", "%20")
        $WebTitle = [System.Web.HttpUtility]::UrlEncode($SyncFolder.WebTitle).Replace("+", "%20")
        $ListTitle = [System.Web.HttpUtility]::UrlEncode($SyncFolder.ListTitle).Replace("+", "%20")
        $FolderName = $SyncFolder.WebTitle + " - " + $SyncFolder.ListTitle
        $IsSynced = !([String]::IsNullOrEmpty($MountPoints)) -And ($MountPoints -Match $FolderName.Replace("(", "\(").Replace(")", "\)"))

        # Skip if Folder is Synced
        If ($IsSynced) { Continue }

        # Check if Folder Applies
        $ApplyToUser = $SyncFolder.ApplyTo -eq "*" -Or $SyncFolder.ApplyTo -Match $UserEmail.Replace("@$TenantDomain", "") -And -Not [String]::IsNullOrEmpty($SyncFolder.ApplyTo)
        $IsUserGroup = $UnifiedGroups.Id -Match $SyncFolder.GroupId -And -Not [String]::IsNullOrEmpty($SyncFolder.GroupId)
		
        # Try to Sync Folder
        If ($ApplyToUser -Or $IsUserGroup) {
			
            $Attempts = 0
            Write-Host ">> Syncing $($SyncFolder.Name)..." -ForegroundColor Cyan -NoNewline
				
            Do {
					
                $Attempts++
                $Launch = "odopen://sync/?userId=$UserId&userEmail=$UserEmail&siteId={$SiteId}&webId={$WebId}&webUrl=$WebUrl&listId={$ListId}&webTitle=$WebTitle&listTitle=$ListTitle"
                Start-Process $Launch #$Launch.Replace(" ", "%20").Replace("{", "%7B").Replace("}", "%7D").Replace("-", "%2D")
                Start-Sleep -Seconds 6
                $CurrentMountPoints = Get-MountPoints
                If ($CurrentMountPoints -Match $FolderName) { Break }
					
            } Until ( $Attempts -ge 5 )

            If (((Get-MountPoints) -Match $FolderName) -And (Test-Path "$SyncPath\$FolderName")) {

                Write-Host " success!" -ForegroundColor Green

            } Else {

                Write-Host " failed!" -ForegroundColor Magenta

            }

        }

    }

    # Apply Folder Icons
    ForEach ($SyncFolder In $SyncFolders) {

        $FolderName = $SyncFolder.WebTitle + " - " + $SyncFolder.ListTitle
        $FolderPath = "$SyncPath\$FolderName"
        $DesktopIni = "$FolderPath\Desktop.ini"

        If ((Test-Path $DesktopIni) -And ($Args -Match "ReapplyIcons")) {

            Remove-Item $DesktopIni -Force -ErrorAction Ignore
            
        }

        If ((Test-Path $FolderPath) -And -Not (Test-Path $DesktopIni)) {
			
            $Icon = $SyncFolder.Icon
            $Content = "[.ShellClassInfo]`nIconResource=$Icon,0`n[ViewState]`nMode=`nVid=`nFolderType=StorageProviderGeneric"

            Try {

                $Content | Out-File $DesktopIni

            } Catch {

                Get-Process OneDrive -ErrorAction Ignore | Stop-Process -Force; Start-Sleep -Seconds 5
                icacls $FolderPath /reset /c /q | Out-Null
                $Content | Out-File $DesktopIni

            } Finally {

                If (Test-Path $DesktopIni) { (Get-Item $DesktopIni -Force).Attributes = 'Hidden, System, Archive' }
                If (Test-Path $FolderPath) { (Get-Item $FolderPath -Force).Attributes = 'ReadOnly, Directory, Archive, ReparsePoint' }
				
            }

        }

    }

    # Hide General Folder
    ForEach ($SyncFolder In $SyncFolders) {

        $FolderName = $SyncFolder.WebTitle + " - " + $SyncFolder.ListTitle
        $FolderPath = "$SyncPath\$FolderName\General"

        If (Test-Path $FolderPath) {
            
            $Attributes = (Get-Item $FolderPath -Force).Attributes
            If ($Attributes -NotMatch "Hidden") { (Get-Item $FolderPath -Force).Attributes = 'Hidden, Directory, ReparsePoint' }
        
        }

    }

    # Start OneDrive Process
    If (!(Get-Process OneDrive -ErrorAction Ignore)) { Start-Process $OneDrivePath -ArgumentList "/background" }

}

# Finish
Start-Sleep -Seconds 5