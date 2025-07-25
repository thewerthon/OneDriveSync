# Initialize
$VerbosePreference = "SilentlyContinue"
$ProgressPreference = "SilentlyContinue"
$ErrorActionPreference = "SilentlyContinue"

# Add References
Add-Type -AssemblyName System.Web
Add-Type -AssemblyName Microsoft.VisualBasic
Add-Type -AssemblyName System.IO.Compression.FileSystem

# Add Classes Root Driver
if (!(Test-Path "HKCR:")) { New-PSDrive -Name HKCR -PSProvider Registry -Root HKEY_CLASSES_ROOT | Out-Null }

# Function to Expand Files
function Expand-Files {

	param(
		[Parameter(Mandatory = $True)][String]$SourcePath,
		[Parameter(Mandatory = $True)][String]$DestinationPath,
		[Switch]$Force
	)
    
	$Encoding = [System.Text.Encoding]::GetEncoding((Get-Culture).TextInfo.OEMCodePage)
	$Contents = [System.IO.Compression.ZipFile]::Open($SourcePath, "Read", $Encoding)
	$Contents.Entries.FullName | ForEach-Object { if ($Force) { Remove-Item "$DestinationPath\$_" -Recurse -Force -ErrorAction Ignore } }
	$Contents.Dispose()

	[System.IO.Compression.ZipFile]::ExtractToDirectory($SourcePath, $DestinationPath, $Encoding)

}

# Function to Update Files
function Update-Files {

	$FileDir = "C:\Startup\OneDrive"
	$TempDir = "C:\Startup\OneDriveTemp"
	$FileZip = "$TempDir\$Global:TenantName.zip"
	$FileUrl = "https://raw.githubusercontent.com/thewerthon/OneDriveSync/main/Setup/$Global:TenantName.exe"

	New-Item -Path $TempDir -ItemType Directory -ErrorAction Ignore | Out-Null
	New-Item -Path $FileDir -ItemType Directory -ErrorAction Ignore | Out-Null

	try {

		Invoke-WebRequest -Uri $FileUrl -OutFile $FileZip
		Expand-Files -SourcePath $FileZip -DestinationPath $TempDir -Force
		Remove-Item -Path $FileZip -Force

		$CheckFolder = Test-Path "$TempDir\$Global:TenantName" -PathType Container
		$CheckParams = [bool](Get-Content -Path "$TempDir\$Global:TenantName\Params.json" | ConvertFrom-Json)
		$CheckScript = [bool]((Get-Content "$TempDir\OneDriveSync.ps1") -match "Update-Files")
        
		if ($CheckFolder -and $CheckParams -and $CheckScript) {
            
			Copy-Item -Path "$TempDir\*" -Destination $FileDir -Recurse -Force
        
		}

	} finally {

		Remove-Item -Path $TempDir -Recurse -Force

	}

}

# Function to Create AuthToken
function New-AuthToken {

	try {

		$Uri = "https://login.microsoftonline.com/$Global:TenantID/oauth2/token"
		$Content = "grant_type=client_credentials&client_id=$Global:ClientID&client_secret=" + ($Global:ClientSecret).Replace("+", "%2B") + "&resource=https://graph.microsoft.com"
		$Response = Invoke-RestMethod -Uri $Uri -Body $Content -Method Post -UseBasicParsing
        
		if ($Response.Access_Token) {

			return @{
				'Content-Type'  = 'application/json'
				'Authorization' = "Bearer " + $Response.Access_Token
				'ExpiresOn'     = $Response.Expires_On
			}

		} else {

			Write-Host "Failed to create access token." -ForegroundColor Red
			return $Null

		}

	} catch {

		Write-Host "Fatal web error in New-AuthToken function." -ForegroundColor Red
		return $Null

	}

}

# Function to Get AuthToken
function Get-AuthToken {

	if ($Global:AuthToken) {

		$CurrentTimeUnix = $((Get-Date ([DateTime]::UtcNow) -UFormat +%s)).split((Get-Culture).NumberFormat.NumberDecimalSeparator)[0]
		$TokenExpires = [MATH]::floor(([int]$AuthToken.ExpiresOn - [int]$CurrentTimeUnix) / 60)
		if ($TokenExpires -le 0) { $Global:AuthToken = New-AuthToken }

	} else {

		$Global:AuthToken = New-AuthToken

	}

}

# Function to Get OneDrive Account
function Get-OneDriveAccount {
	
	$Accounts = Get-ChildItem -Path "HKCU:\Software\Microsoft\OneDrive\Accounts" -ErrorAction Ignore | Where-Object { $_.Name -match "Business" }
	
	foreach ($Account in $Accounts) {
		
		$Tenant = Get-ItemProperty -Path "Registry::$($Account.Name)" -ErrorAction Ignore | Select-Object -ExpandProperty ConfiguredTenantId -ErrorAction Ignore
		if ($Tenant -eq $Global:TenantID) { return $Account; break }
		
	}
	
}

# Function to Get OneDrive Account Property
function Get-OneDriveAccountProperty {
    
	param (
		[Parameter(Mandatory = $True)]
		[String]$Property
	)
    
	if ($Null -eq $Global:OneDriveAccount) { $Global:OneDriveAccount = Get-OneDriveAccount }
	return (Get-ItemProperty -Path "Registry::$($OneDriveAccount.Name)" -Name $Property -ErrorAction Ignore | Select-Object -ExpandProperty $Property -ErrorAction Ignore)
    
}

# Function to Get Unified Groups
function Get-UnifiedGroups() {

	try {

		Get-AuthToken
		$Uri = "https://graph.microsoft.com/v1.0/users/$Global:UserEmail/memberOf"
		return (Invoke-RestMethod -Uri $Uri -Headers $AuthToken -Method Get).Value

	} catch {

		Write-Host "Fatal web error in Get-UnifiedGroups function." -ForegroundColor Red
		return $Null

	}

}

# Function to Get Mount Points
function Get-MountPoints {
	
	if ($Null -eq $Global:OneDriveAccount) { $Global:OneDriveAccount = Get-OneDriveAccount }
	$MountPoints = Get-Item -Path "Registry::$($OneDriveAccount.Name)\Tenants\$TenantName" -ErrorAction Ignore | Select-Object -ExpandProperty Property -ErrorAction Ignore
	return $MountPoints
	
}

# Function to Get OneDrive Status
function Get-OneDriveStatus {
	
	if ($Null -eq $Global:OneDriveAccount) { $Global:OneDriveAccount = Get-OneDriveAccount }
	
	$OneDriveAccountStatus = !([String]::IsNullOrEmpty($OneDriveAccount))
	$OneDriveProcessStatus = !([String]::IsNullOrEmpty((Get-Process OneDrive -ErrorAction Ignore)))	
	$OneDriveFirstRunEntry = (Get-ItemProperty -Path "Registry::$($OneDriveAccount.Name)" -Name "FirstRun" -ErrorAction Ignore | Select-Object -ExpandProperty "FirstRun" -ErrorAction Ignore) -eq 1
    
	return ($OneDriveProcessStatus -and $OneDriveAccountStatus -and $OneDriveFirstRunEntry)
	
}

# Load Params Files
if ($Args[0] -like "*.json") { $ParamFiles = Get-Item -Path $Args[0] } else { $ParamFiles = Get-ChildItem "C:\Startup\OneDrive\*\Params.json" -Recurse -Depth 1 -Force }

# Execute Sync for Each Param File
foreach ($ParamFile in $ParamFiles) {
    
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
	if (Test-Path $OneDrivePath1) { $Global:OneDrivePath = $OneDrivePath1 }
	if (Test-Path $OneDrivePath2) { $Global:OneDrivePath = $OneDrivePath2 }
	if ($Null -eq $Global:OneDrivePath) { Write-Host "OneDrive is not installed in $OneDrivePath." -ForegroundColor Red; exit 1 }

	# Wait Before Setup
	if (!(Get-OneDriveStatus)) {
		
		$Attempts = 0
		Start-Process $OneDrivePath -ArgumentList "/background"
		
		do {
			
			$Attempts++
			Start-Sleep -Seconds 5
			if (Get-OneDriveStatus) { break }

		} until ( $Attempts -ge 12 )
		
	}

	# Start OneDrive Setup
	if (!(Get-OneDriveStatus)) {
		
		$UserUPN = WhoAmI /UPN 2>$Null

		if ($UserUPN) {

			$Attempts = 0
			Write-Host "Waiting account setup for $UserUPN..." -ForegroundColor Cyan
			Start-Process "odopen://sync?useremail=$UserUPN"
		
			do {
			
				$Attempts++
				Start-Sleep -Seconds 30
				if (Get-OneDriveStatus) { break }
			
			} until ( $Attempts -ge 6)

		}
        
	}
    
	# Exit Script if OneDrive Is Not Setted Up
	if (!(Get-OneDriveStatus)) {
		
		Write-Host "OneDrive is not setted up." -ForegroundColor Red
		exit 1
		
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
	foreach ($Folder in $Params.RemoveFolders) {
		
		$Path = "$SyncPath\$Folder"
		$IsSynced = !([String]::IsNullOrEmpty($MountPoints)) -and ($MountPoints -match $Folder)
		
		if (Test-Path $Path) {
			if (!$IsSynced) {
				Write-Host ">> Removing $Folder..." -ForegroundColor Magenta
				icacls $Path /reset /t /c /q | Out-Null
				Remove-Item $Path -Recurse -Force -ErrorAction Ignore
			}
		}
		
	}

	# Sync Folders
	$SyncFolders = $Params.DefaultFolders + $Params.TeamsFolders
	foreach ($SyncFolder in $SyncFolders) {

		# Set Folder Variables
		$SiteId = [System.Web.HttpUtility]::UrlEncode($SyncFolder.SiteId).Replace("+", "%20")
		$WebId = [System.Web.HttpUtility]::UrlEncode($SyncFolder.WebId).Replace("+", "%20")
		$WebUrl = [System.Web.HttpUtility]::UrlEncode($SyncFolder.WebUrl).Replace("+", "%20")
		$ListId = [System.Web.HttpUtility]::UrlEncode($SyncFolder.ListId).Replace("+", "%20")
		$WebTitle = [System.Web.HttpUtility]::UrlEncode($SyncFolder.WebTitle).Replace("+", "%20")
		$ListTitle = [System.Web.HttpUtility]::UrlEncode($SyncFolder.ListTitle).Replace("+", "%20")
		$FolderName = $SyncFolder.WebTitle + " - " + $SyncFolder.ListTitle
		$IsSynced = !([String]::IsNullOrEmpty($MountPoints)) -and ($MountPoints -match $FolderName.Replace("(", "\(").Replace(")", "\)"))

		# Skip if Folder is Synced
		if ($IsSynced) { continue }

		# Check if Folder Applies
		$ApplyToUser = $SyncFolder.ApplyTo -eq "*" -or $SyncFolder.ApplyTo -match $UserEmail.Replace("@$TenantDomain", "") -and -not [String]::IsNullOrEmpty($SyncFolder.ApplyTo)
		$IsUserGroup = $UnifiedGroups.Id -match $SyncFolder.GroupId -and -not [String]::IsNullOrEmpty($SyncFolder.GroupId)
		
		# Try to Sync Folder
		if ($ApplyToUser -or $IsUserGroup) {
			
			$Attempts = 0
			Write-Host ">> Syncing $($SyncFolder.Name)..." -ForegroundColor Cyan -NoNewline
				
			do {
					
				$Attempts++
				$Launch = "odopen://sync/?userId=$UserId&userEmail=$UserEmail&siteId={$SiteId}&webId={$WebId}&webUrl=$WebUrl&listId={$ListId}&webTitle=$WebTitle&listTitle=$ListTitle"
				Start-Process $Launch #$Launch.Replace(" ", "%20").Replace("{", "%7B").Replace("}", "%7D").Replace("-", "%2D")
				Start-Sleep -Seconds 6
				$CurrentMountPoints = Get-MountPoints
				if ($CurrentMountPoints -match $FolderName) { break }
					
			} until ( $Attempts -ge 5 )

			if (((Get-MountPoints) -match $FolderName) -and (Test-Path "$SyncPath\$FolderName")) {

				Write-Host " success!" -ForegroundColor Green

			} else {

				Write-Host " failed!" -ForegroundColor Magenta

			}

		}

	}

	# Apply Folder Icons
	foreach ($SyncFolder in $SyncFolders) {

		$FolderName = $SyncFolder.WebTitle + " - " + $SyncFolder.ListTitle
		$FolderPath = "$SyncPath\$FolderName"
		$DesktopIni = "$FolderPath\Desktop.ini"

		if ((Test-Path $DesktopIni) -and ($Args -match "ReapplyIcons")) {

			Remove-Item $DesktopIni -Force -ErrorAction Ignore
            
		}

		if ((Test-Path $FolderPath) -and -not (Test-Path $DesktopIni)) {
			
			$Icon = $SyncFolder.Icon
			$Content = "[.ShellClassInfo]`nIconResource=$Icon,0`n[ViewState]`nMode=`nVid=`nFolderType=StorageProviderGeneric"

			try {

				$Content | Out-File $DesktopIni

			} catch {

				Get-Process OneDrive -ErrorAction Ignore | Stop-Process -Force; Start-Sleep -Seconds 5
				icacls $FolderPath /reset /c /q | Out-Null
				$Content | Out-File $DesktopIni

			} finally {

				if (Test-Path $DesktopIni) { (Get-Item $DesktopIni -Force).Attributes = 'Hidden, System, Archive' }
				if (Test-Path $FolderPath) { (Get-Item $FolderPath -Force).Attributes = 'ReadOnly, Directory, Archive, ReparsePoint' }
				
			}

		}

	}

	# Hide General Folder
	foreach ($SyncFolder in $SyncFolders) {

		$FolderName = $SyncFolder.WebTitle + " - " + $SyncFolder.ListTitle
		$FolderPath = "$SyncPath\$FolderName\General"

		if (Test-Path $FolderPath) {
            
			$Attributes = (Get-Item $FolderPath -Force).Attributes
			if ($Attributes -notmatch "Hidden") { (Get-Item $FolderPath -Force).Attributes = 'Hidden, Directory, ReparsePoint' }
        
		}

	}

	# Start OneDrive Process
	if (!(Get-Process OneDrive -ErrorAction Ignore)) { Start-Process $OneDrivePath -ArgumentList "/background" }

}

# Finish
Start-Sleep -Seconds 5