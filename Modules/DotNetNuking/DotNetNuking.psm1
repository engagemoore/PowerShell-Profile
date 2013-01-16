Set-StrictMode -Version Latest

Push-Location

Import-Module Add-HostFileEntry
Import-Module WebAdministration
Import-Module SQLPS -DisableNameChecking

Pop-Location

$defaultDotNetNukeVersion = '7.0.1'

function Remove-DotNetNukeSite {
  param(
    [parameter(Mandatory=$true,position=0)]
    [string]$siteName
  );
  
  if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Warning "You do not have Administrator rights to run this script!`nPlease re-run this script as an Administrator!"
    Break
  }

  if (Test-Path IIS:\Sites\$siteName) { Remove-Website $siteName }
  if (Test-Path IIS:\AppPools\$siteName) { Remove-WebAppPool $siteName }
  if (Test-Path C:\inetpub\wwwroot\$siteName) { Remove-Item C:\inetpub\wwwroot\$siteName -Recurse -Force }

  if (Test-Path "SQLSERVER:\SQL\(local)\DEFAULT\Databases\$(Encode-SQLName $siteName)") { 
    Invoke-Sqlcmd -Query "ALTER DATABASE [$siteName] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;" -ServerInstance . -Database master
    Invoke-Sqlcmd -Query "DROP DATABASE [$siteName];" -ServerInstance . -Database master
  }

  if (Test-Path "SQLSERVER:\SQL\(local)\DEFAULT\Logins\$(Encode-SQLName "IIS AppPool\$siteName")") { 
    Invoke-Sqlcmd -Query "DROP LOGIN [IIS AppPool\$siteName];" -Database master
  }

  # TODO: Remove host file entry

<#
.SYNOPSIS
    Destroys a DotNetNuke site
.DESCRIPTION
    Destroys a DotNetNuke site, removing it from the file system, IIS, and the database
.PARAMETER siteName
    The name of the site (the domain, folder name, and database name, e.g. dnn.dev)
#>
}

function Restore-DotNetNukeSite {
  param(
    [parameter(Mandatory=$true,position=0)]
    [string]$siteName,
    [parameter(Mandatory=$true,position=1)]
    [string]$siteZip,
    [parameter(Mandatory=$true,position=2)]
    [string]$databaseBackup,
    [parameter(Mandatory=$false)]
    [string]$sourceVersion = '',
    [parameter(Mandatory=$false)]
    [string]$oldDomain = ''
  );
  
  # TODO: Switch $siteZip and $databaseBackup is $siteZip extension is .bak

  $version = if ($sourceVersion -ne '') { $sourceVersion } else { $defaultDotNetNukeVersion }
  $includeSource = $sourceVersion -ne ''
  New-DotNetNukeSite $siteName -siteZip $siteZip -databaseBackup $databaseBackup -version $version -includeSource $includeSource -oldDomain $oldDomain

<#
.SYNOPSIS
    Restores a backup of a DotNetNuke site
.DESCRIPTION
    Restores a DotNetNuke site from a file system zip and database backup
.PARAMETER siteName
    The name of the site (the domain, folder name, and database name, e.g. dnn.dev)
.PARAMETER siteZip
    The full path to the zip (any format that 7-Zip can expand) of the site's file system
.PARAMETER databaseBackup
    The full path to the database backup (.bak file).  This must be in a location to which SQL Server has access
.PARAMETER sourceVersion
    If specified, the DNN source for this version will be included with the site
.PARAMETER oldDomain
    If specified, the Portal Alias table will be updated to replace the old site domain with the new site domain
#>
}

function New-DotNetNukeSite {
  param(
    [parameter(Mandatory=$true,position=0)]
    [string]$siteName,
    [parameter(Mandatory=$false,position=1)]
    [string]$version = $defaultDotNetNukeVersion,
    [parameter(Mandatory=$false,position=2)]
    [bool]$includeSource = $true,
    [parameter(Mandatory=$false)]
    [string]$objectQualifier = '',
    [parameter(Mandatory=$false)]
    [string]$databaseOwner = 'dbo',
    [parameter(Mandatory=$false)]
    [string]$siteZip = $null,
    [parameter(Mandatory=$false)]
    [string]$databaseBackup = $null,
    [parameter(Mandatory=$false)]
    [string]$oldDomain = $null
  );

  if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
    Write-Warning "You do not have Administrator rights to run this script!`nPlease re-run this script as an Administrator!"
    Break
  }
  
  $v = New-Object System.Version($version)
  $majorVersion = $v.Major
  $formattedVersion = $v.Major.ToString('0#') + '.' + $v.Minor.ToString('0#') + '.' + $v.Build.ToString('0#')
  if ($includeSource -eq $true) {
    Write-Host "Extracting DNN $formattedVersion source"
    &7za x -oC:\inetpub\wwwroot\$siteName "${env:soft}\DNN\Versions\DotNetNuke $majorVersion\DotNetNuke_Community_${formattedVersion}_Source.zip" | Out-Null
    Write-Host "Copying DNN $formattedVersion source symbols into install directory"
    cp "${env:soft}\DNN\Versions\DotNetNuke $majorVersion\DotNetNuke_Community_${formattedVersion}_Symbols.zip" C:\inetpub\wwwroot\$siteName\Website\Install\Module
    Write-Host "Updating site URL in sln files"
    ls C:\inetpub\wwwroot\$siteName\*.sln | % { Set-Content $_ ((Get-Content $_) -replace '"http://localhost/DotNetNuke_Community"', "`"http://$siteName`"") }
  }
  
  if ($siteZip -eq $null) { 
    $siteZip = "${env:soft}\DNN\Versions\DotNetNuke $majorVersion\DotNetNuke_Community_${formattedVersion}_Install.zip"
  }
  Write-Host "Extracting DNN site"
  &7za x -y -oC:\inetpub\wwwroot\$siteName\Website $siteZip | Out-Null

  Write-Host "Creating HOSTS file entry for $siteName"
  Add-HostFileEntry $siteName

  Write-Host "Creating IIS app pool"
  New-WebAppPool $siteName
  Write-Host "Creating IIS site"
  New-Website $siteName -HostHeader $siteName -PhysicalPath C:\inetpub\wwwroot\$siteName\Website -ApplicationPool $siteName
  # TODO: Setup SSL cert & binding

  Write-Host "Setting modify permission on website files for IIS AppPool\$siteName"
  Set-ModifyPermission C:\inetpub\wwwroot\$siteName\Website $siteName
  
  [xml]$webConfig = Get-Content C:\inetpub\wwwroot\$siteName\Website\web.config
  if ($databaseBackup -eq $null) {
    Write-Host "Creating new database"
    New-DotNetNukeDatabase $siteName
  }
  else {
    Write-Host "Restoring database"
    Restore-DotNetNukeDatabase $siteName $databaseBackup

    $objectQualifier = $webConfig.configuration.dotnetnuke.data.providers.add.objectQualifier.TrimEnd('_')
    $databaseOwner = $webConfig.configuration.dotnetnuke.data.providers.add.databaseOwner.TrimEnd('.')

    if ($oldDomain -ne $null) {
      Write-Host "Updating portal aliases"
      Invoke-Sqlcmd -Query "UPDATE $(Get-DotNetNukeDatabaseObjectName 'PortalAlias' $databaseOwner $objectQualifier) SET HTTPAlias = REPLACE(HTTPAlias, '$oldDomain', '$siteName')" -Database $siteName
      Invoke-Sqlcmd -Query "UPDATE $(Get-DotNetNukeDatabaseObjectName 'PortalSettings' $databaseOwner $objectQualifier) SET SettingValue = REPLACE(SettingValue, '$oldDomain', '$siteName') WHERE SettingName = 'DefaultPortalAlias'" -Database $siteName
      # TODO: Update remaining .com aliases to .com.dev
      # TODO: Add all aliases to host file and IIS
    }

    Write-Host "Setting SMTP to localhost"
    Invoke-Sqlcmd -Query "UPDATE $(Get-DotNetNukeDatabaseObjectName 'HostSettings' $databaseOwner $objectQualifier) SET SettingValue = 'localhost' WHERE SettingName = 'SMTPServer'" -Database $siteName
    Invoke-Sqlcmd -Query "UPDATE $(Get-DotNetNukeDatabaseObjectName 'HostSettings' $databaseOwner $objectQualifier) SET SettingValue = '0' WHERE SettingName = 'SMTPAuthentication'" -Database $siteName
    Invoke-Sqlcmd -Query "UPDATE $(Get-DotNetNukeDatabaseObjectName 'HostSettings' $databaseOwner $objectQualifier) SET SettingValue = 'N' WHERE SettingName = 'SMTPEnableSSL'" -Database $siteName
    Invoke-Sqlcmd -Query "UPDATE $(Get-DotNetNukeDatabaseObjectName 'HostSettings' $databaseOwner $objectQualifier) SET SettingValue = '' WHERE SettingName = 'SMTPUsername'" -Database $siteName
    Invoke-Sqlcmd -Query "UPDATE $(Get-DotNetNukeDatabaseObjectName 'HostSettings' $databaseOwner $objectQualifier) SET SettingValue = '' WHERE SettingName = 'SMTPPassword'" -Database $siteName
  }

  $connectionString = "Data Source=.`;Initial Catalog=$siteName`;Integrated Security=true"
  $webConfig.configuration.connectionStrings.add.connectionString = $connectionString
  $webConfig.configuration.appSettings.add | ? { $_.key -eq 'SiteSqlServer' } | % { $_.value = $connectionString }
  $webConfig.configuration.dotnetnuke.data.providers.add.objectQualifier = $objectQualifier
  $webConfig.configuration.dotnetnuke.data.providers.add.databaseOwner = $databaseOwner
  Write-Host "Updating web.config with connection string and data provider attributes"
  $webConfig.Save("C:\inetpub\wwwroot\$siteName\Website\web.config")
  
  if (-not (Test-Path "SQLSERVER:\SQL\(local)\DEFAULT\Logins\$(Encode-SQLName "IIS AppPool\$siteName")")) { 
    Write-Host "Creating SQL Server login for IIS AppPool\$siteName"
    Invoke-Sqlcmd -Query "CREATE LOGIN [IIS AppPool\$siteName] FROM WINDOWS WITH DEFAULT_DATABASE = [$siteName];" -Database master
  }
  Write-Host "Creating SQL Server user"
  Invoke-Sqlcmd -Query "CREATE USER [IIS AppPool\$siteName] FOR LOGIN [IIS AppPool\$siteName];" -Database $siteName
  Write-Host "Adding SQL Server user to db_owner role"
  Invoke-Sqlcmd -Query "EXEC sp_addrolemember N'db_owner', N'IIS AppPool\$siteName';" -Database $siteName
  
  Write-Host "Launching http://$siteName"
  Start-Process -FilePath http://$siteName

<#
.SYNOPSIS
    Creates a DotNetNuke site
.DESCRIPTION
    Creates a DotNetNuke site, either from a file system zip and database backup, or a new installation
.PARAMETER siteName
    The name of the site (the domain, folder name, and database name, e.g. dnn.dev)
.PARAMETER version
    The DotNetNuke version
.PARAMETER includeSource
    Whether to include the DNN source files
.PARAMETER objectQualifier
    The database object qualifier
.PARAMETER databaseOwner
    The database schema
.PARAMETER databaseBackup
    The full path to the database backup (.bak file).  This must be in a location to which SQL Server has access
.PARAMETER sourceVersion
    If specified, the DNN source for this version will be included with the site
.PARAMETER oldDomain
    If specified, the Portal Alias table will be updated to replace the old site domain with the new site domain
#>
}

function New-DotNetNukeDatabase {
  param(
    [parameter(Mandatory=$true,position=0)]
    [string]$siteName
  );
  
  Invoke-Sqlcmd -Query "CREATE DATABASE [$siteName];" -Database master
}

function Restore-DotNetNukeDatabase {
  param(
    [parameter(Mandatory=$true,position=0)]
    [string]$siteName,
    [parameter(Mandatory=$true,position=1)]
    [string]$databaseBackup
  );
  
  #based on http://redmondmag.com/articles/2009/12/21/automated-restores.aspx
  $server = New-Object Microsoft.SqlServer.Management.Smo.Server('(local)')
  $dbRestore = New-Object Microsoft.SqlServer.Management.Smo.Restore
  
  $dbRestore.Action = 'Database'
  $dbRestore.NoRecovery = $false
  $dbRestore.ReplaceDatabase = $true
  $dbRestore.Devices.AddDevice($databaseBackup, [Microsoft.SqlServer.Management.Smo.DeviceType]::File)
  $dbRestore.Database = $siteName
   
  $dbRestoreFile = New-Object Microsoft.SqlServer.Management.Smo.RelocateFile
  $dbRestoreLog = New-Object Microsoft.SqlServer.Management.Smo.RelocateFile
  
  $logicalDataFileName = $siteName
  $logicalLogFileName = $siteName
  
  foreach ($file in $dbRestore.ReadFileList($server)) {
    switch ($file.Type) {
      'D' { $logicalDataFileName = $file.LogicalName }
      'L' { $logicalLogFileName = $file.LogicalName }
    }
  }

  $dbRestoreFile.LogicalFileName = $logicalDataFileName
  $dbRestoreFile.PhysicalFileName = $server.Information.MasterDBPath + '\' + $siteName + '_Data.mdf'
  $dbRestoreLog.LogicalFileName = $logicalLogFileName
  $dbRestoreLog.PhysicalFileName = $server.Information.MasterDBLogPath + '\' + $siteName + '_Log.ldf'
  
  $dbRestore.RelocateFiles.Add($dbRestoreFile) | Out-Null
  $dbRestore.RelocateFiles.Add($dbRestoreLog) | Out-Null
  
  try {
    $dbRestore.SqlRestore($server)
  }
  catch [System.Exception] {
    write-host $_.Exception
  }
}

function Get-DotNetNukeDatabaseObjectName {
    param(
        [parameter(Mandatory=$true,position=0)]
        [string]$objectName, 
        [parameter(Mandatory=$true,position=1)]
        [string]$databaseOwner, 
        [parameter(Mandatory=$false,position=2)]
        [string]$objectQualifier
    );

    if ($objectQualifier -ne '') { $objectQualifier += '_' }
    return $databaseOwner + ".[$objectQualifier$objectName]"
}

Export-ModuleMember Remove-DotNetNukeSite
Export-ModuleMember New-DotNetNukeSite
Export-ModuleMember Restore-DotNetNukeSite