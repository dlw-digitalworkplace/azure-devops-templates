param(
    [Parameter(Mandatory=$true)]  [string]$accessToken,
    [Parameter(Mandatory=$true)]  [string]$sourcesDirectory,
    [Parameter(Mandatory=$true)]  [string]$releaseNotesPath,
    [Parameter(Mandatory=$true)]  [string]$latestRelease,
    [Parameter(Mandatory=$true)]  [string]$pdfConversionDriveId,
    [Parameter(Mandatory=$true)]  [string]$fromAddress,
    [Parameter(Mandatory=$true)]  [string]$ipName,
    [Parameter(Mandatory=$false)] [string]$pdfConversionFolderPath = "",
    [Parameter(Mandatory=$false)] [string]$customerName = ""
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

    $params = @{
        message = @{
            subject = $mailSubject
            body = @{
                contentType = "HTML"
                content     = $mailBody
            }
            toRecipients = @(
                $fields.dlwrToRecipients -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ } | ForEach-Object {
                    @{ emailAddress = @{ address = $_ } }
                }
            )
            CcRecipients = @(
                $fields.dlwrCcRecipients -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ } | ForEach-Object {
                    @{ emailAddress = @{ address = $_ } }
                }
            )
            attachments = @(
                @{
                    "@odata.type" = "#microsoft.graph.fileAttachment"
                    name          = $attachmentName
                    contentType   = "application/pdf"
                    contentBytes  = $pdfContent
                }
            )
        }
    }

    Write-Host "Sending email to: $($fields.dlwrToRecipients)"
    Send-MgUserMail -UserId $fromAddress -BodyParameter $params
}