param(
    [Parameter(Mandatory=$true)]  [string]$accessToken,
    [Parameter(Mandatory=$true)]  [string]$sendGridApiKey,
    [Parameter(Mandatory=$true)]  [string]$sourcesDirectory,
    [Parameter(Mandatory=$true)]  [string]$releaseNotesPath,
    [Parameter(Mandatory=$true)]  [string]$latestRelease,
    [Parameter(Mandatory=$true)]  [string]$pdfConversionDriveId,
    [Parameter(Mandatory=$true)]  [string]$fromAddress,
    [Parameter(Mandatory=$true)]  [string]$ipName,
    [Parameter(Mandatory=$false)] [string]$pdfConversionFolderPath = "",
    [Parameter(Mandatory=$false)] [string]$customerName        = "",
    [Parameter(Mandatory=$false)] [string]$testRecipients      = "",
    [Parameter(Mandatory=$false)] [bool]  $onlyLatestVersion   = $true,
    [Parameter(Mandatory=$false)] [string]$changeLogFolder     = ""
)

$ErrorActionPreference = 'Stop'

function Set-Placeholders {
    param([string]$textToReplace, [hashtable]$placeholders)
    $result = $textToReplace
    foreach ($key in $placeholders.Keys) {
        $result = $result -replace "\{$key\}", $placeholders[$key]
    }
    return $result
}

# === Connect to Microsoft Graph ===
$secureToken = ConvertTo-SecureString -String $accessToken -AsPlainText -Force
Connect-MgGraph -AccessToken $secureToken

# === Test-mode early exit ===
if (-not [string]::IsNullOrEmpty($testRecipients)) {
    $testAttachmentName = "$ipName-v$latestRelease-release-notes.pdf"
    $testPdfLocalPath   = "$sourcesDirectory/$testAttachmentName"
    $testUniqueMdName   = "$ipName-release-notes-$latestRelease.md"
    $testReleaseNotesLocation = "$sourcesDirectory/$releaseNotesPath"

    $testFolderPrefix = ""
    if (-not [string]::IsNullOrWhiteSpace($pdfConversionFolderPath)) {
        $testFolderPrefix = $pdfConversionFolderPath.Trim('/') + '/'
    }

    $testUploadItemPath = "root:/${testFolderPrefix}${testUniqueMdName}:"
    $testUploadedItemId = $null

    try {
        Write-Host "TEST MODE: Uploading markdown to drive item: $testUploadItemPath"
        $testUploadResponse = Set-MgDriveItemContent `
            -DriveId $pdfConversionDriveId `
            -DriveItemId $testUploadItemPath `
            -InFile $testReleaseNotesLocation
        $testUploadedItemId = $testUploadResponse.Id
        Write-Host "TEST MODE: Uploaded as driveItem: $testUploadedItemId"

        Write-Host "TEST MODE: Converting to PDF..."
        Get-MgDriveItemContent `
            -DriveId $pdfConversionDriveId `
            -DriveItemId $testUploadedItemId `
            -Format pdf `
            -OutFile $testPdfLocalPath
        Write-Host "TEST MODE: PDF saved to: $testPdfLocalPath"
    }
    finally {
        if ($testUploadedItemId) {
            Write-Host "TEST MODE: Cleaning up scratch driveItem $testUploadedItemId"
            try {
                Remove-MgDriveItem -DriveId $pdfConversionDriveId -DriveItemId $testUploadedItemId
            } catch {
                Write-Warning "TEST MODE: Failed to delete scratch driveItem: $($_.Exception.Message)"
            }
        }
    }

    $testPdfContent = [Convert]::ToBase64String([IO.File]::ReadAllBytes($testPdfLocalPath))

    $testToList = @($testRecipients -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ } | ForEach-Object { @{ email = $_ } })

    $testSendGridPayload = @{
        personalizations = @(@{
            to      = $testToList
            subject = "TEST - $ipName v$latestRelease release notes preview"
        })
        from        = @{ email = $fromAddress }
        content     = @(@{ type = 'text/html'; value = '<p>Please review the attached release notes.</p>' })
        attachments = @(@{
            content     = $testPdfContent
            type        = 'application/pdf'
            filename    = $testAttachmentName
            disposition = 'attachment'
        })
    } | ConvertTo-Json -Depth 6

    Write-Host "TEST MODE: Sending preview email to: $testRecipients"
    Invoke-RestMethod `
        -Method      Post `
        -Uri         'https://api.sendgrid.com/v3/mail/send' `
        -Headers     @{ Authorization = "Bearer $sendGridApiKey" } `
        -ContentType 'application/json' `
        -Body        $testSendGridPayload
    return
}

# === Get SP list item ===
Write-Host "=== Testing Get-MgSiteListItem ==="
Write-Host "Customer: $customerName | IP: $ipName"

if ($customerName -eq "all") {
    $filter = "fields/dlwrIpName eq '$ipName'"
} else {
    $filter = "fields/dlwrCustomerName eq '$customerName' and fields/dlwrIpName eq '$ipName'"
}

$listItems = Get-MgSiteListItem `
  -SiteId "dlw365qa.sharepoint.com,7bb8c461-8535-4564-9ee5-9d50314a9cbc,f6eefd7b-906e-4949-b5ea-ce5494d2bdd0" `
  -ListId "ca17277a-f981-4d8a-8c7c-30a59c9fe231" `
  -Filter $filter `
  -ExpandProperty "fields" `
  -Headers @{ Prefer = "HonorNonIndexedQueriesWarningMayFailRandomly" }

Write-Host "Items returned: $($listItems.Count)"

foreach ($item in $listItems) {
    $fields = $item.Fields.AdditionalProperties
    Write-Host "dlwrCustomerName:   $($fields.dlwrCustomerName)"
    Write-Host "dlwrIpName:         $($fields.dlwrIpName)"
    Write-Host "dlwrCurrentVersion: $($fields.dlwrCurrentVersion)"
    Write-Host "dlwrToRecipients:   $($fields.dlwrToRecipients)"
}

foreach ($customer in $listItems) {
    $fields = $customer.Fields.AdditionalProperties

    $IpName = $fields.dlwrIpName

    $placeholders = @{
        "ipname"  = $IpName
        "version" = $latestRelease
    }

    $mailSubject    = Set-Placeholders -textToReplace $fields.dlwrMailSubject    -placeholders $placeholders
    $mailBody       = Set-Placeholders -textToReplace $fields.dlwrMailBody       -placeholders $placeholders
    $attachmentName = Set-Placeholders -textToReplace $fields.dlwrAttachmentName -placeholders $placeholders

    if (-not $onlyLatestVersion) {
        $customerFromVersion = $fields.dlwrCurrentVersion
        if ([string]::IsNullOrEmpty($customerFromVersion)) { $customerFromVersion = $latestRelease }

        & "$PSScriptRoot/Get-ReleaseNotes.ps1" `
            -changeLogFolder           $changeLogFolder `
            -fromVersion               $customerFromVersion `
            -includeDescription        $true `
            -includeChangeNonTechnical $true `
            -includeChangeTechnical    $false `
            -includeDeploymentNotes    $false `
            -releaseNotesOutputPath    $releaseNotesPath `
            -sourcesDirectory          $sourcesDirectory `
            -tillVersion               "N/A"
    }

    # === Convert markdown to PDF via Microsoft Graph SDK ===
    $uniqueMdName = "$IpName-release-notes-$latestRelease.md"

    # Normalize folder path: empty -> root of drive; otherwise trim slashes and append one
    $folderPrefix = ""
    if (-not [string]::IsNullOrWhiteSpace($pdfConversionFolderPath)) {
        $folderPrefix = $pdfConversionFolderPath.Trim('/') + '/'
    }

    $driveId = $pdfConversionDriveId # Documents from /sites/ip-release-notes
    Write-Host "Using drive ID: $driveId"

    # Path-syntax DriveItemId for creating a new file by path
    $uploadItemPath = "root:/${folderPrefix}${uniqueMdName}:"
    $pdfLocalPath   = "$sourcesDirectory/$attachmentName"
    $uploadedItemId = $null
    $releaseNotesLocation = "$sourcesDirectory/$releaseNotesPath"

    try {
        Write-Host "Uploading markdown to drive item: $uploadItemPath"
        $uploadResponse = Set-MgDriveItemContent `
            -DriveId $driveId `
            -DriveItemId $uploadItemPath `
            -InFile $releaseNotesLocation
        $uploadedItemId = $uploadResponse.Id
        Write-Host "Uploaded as driveItem: $uploadedItemId"

        Write-Host "Converting to PDF..."
        Get-MgDriveItemContent `
            -DriveId $driveId `
            -DriveItemId $uploadedItemId `
            -Format pdf `
            -OutFile $pdfLocalPath
        Write-Host "PDF saved to: $pdfLocalPath"
    }
    finally {
        if ($uploadedItemId) {
            Write-Host "Cleaning up scratch driveItem $uploadedItemId"
            try {
                Remove-MgDriveItem -DriveId $driveId -DriveItemId $uploadedItemId
            } catch {
                Write-Warning "Failed to delete scratch driveItem: $($_.Exception.Message)"
            }
        }
    }

    # === Send mail ===
    $pdfContent = [Convert]::ToBase64String([IO.File]::ReadAllBytes($pdfLocalPath))

    Write-Host "Processing customer: $($fields.dlwrCustomerName)"

    $toList = @($fields.dlwrToRecipients -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ } | ForEach-Object { @{ email = $_ } })
    $ccList = @($fields.dlwrCcRecipients -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ } | ForEach-Object { @{ email = $_ } })

    $personalization = @{ to = $toList; subject = $mailSubject }
    if ($ccList.Count -gt 0) { $personalization.cc = $ccList }

    $sendGridPayload = @{
        personalizations = @($personalization)
        from        = @{ email = $fromAddress }
        content     = @(@{ type = 'text/html'; value = $mailBody })
        attachments = @(@{
            content     = $pdfContent
            type        = 'application/pdf'
            filename    = $attachmentName
            disposition = 'attachment'
        })
    } | ConvertTo-Json -Depth 6

    Write-Host "Sending email to: $($fields.dlwrToRecipients)"
    Invoke-RestMethod `
        -Method      Post `
        -Uri         'https://api.sendgrid.com/v3/mail/send' `
        -Headers     @{ Authorization = "Bearer $sendGridApiKey" } `
        -ContentType 'application/json' `
        -Body        $sendGridPayload
}