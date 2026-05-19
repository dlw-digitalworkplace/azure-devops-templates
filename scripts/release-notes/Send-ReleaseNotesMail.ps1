param(
    [Parameter(Mandatory=$true)]  [string]$accessToken,
    [Parameter(Mandatory=$true)]  [string]$sourcesDirectory,
    [Parameter(Mandatory=$true)]  [string]$releaseNotesPath,
    [Parameter(Mandatory=$true)]  [string]$configPath,
    [Parameter(Mandatory=$true)]  [string]$latestRelease,
    [Parameter(Mandatory=$true)]  [string]$pdfConversionDriveId,
    [Parameter(Mandatory=$false)] [string]$pdfConversionFolderPath = ""
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
$customerName = "TEST DLW 2"
$ipName = "Connect"

Write-Host "=== Testing Get-MgSiteListItem ==="
Write-Host "Customer: $customerName | IP: $ipName"

$listItems = Get-MgSiteListItem `
  -SiteId "dlw365qa.sharepoint.com,7bb8c461-8535-4564-9ee5-9d50314a9cbc,f6eefd7b-906e-4949-b5ea-ce5494d2bdd0" `
  -ListId "ca17277a-f981-4d8a-8c7c-30a59c9fe231" `
  -Filter "fields/dlwrCustomerName eq '$customerName' and fields/dlwrIpName eq '$ipName'" `
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


# === Load config and release notes ===
$configLocation = "$sourcesDirectory/$configPath"
$configMail = Get-Content -Path $configLocation -Raw | ConvertFrom-Json

$releaseNotesLocation = "$sourcesDirectory/$releaseNotesPath"
$releaseNotesHtml = (ConvertFrom-Markdown -Path $releaseNotesLocation).Html

$placeholders = @{
    "version"      = $latestRelease
    "releaseNotes" = $releaseNotesHtml
}

Write-Host "Config location:        $configLocation"
Write-Host "Release notes location: $releaseNotesLocation"

$mailSubject     = Set-Placeholders -textToReplace $configMail.mailSubject     -placeholders $placeholders
$mailBody        = Set-Placeholders -textToReplace $configMail.mailBody        -placeholders $placeholders
$attachementName = Set-Placeholders -textToReplace $configMail.attachementName -placeholders $placeholders

# === Convert markdown to PDF via Microsoft Graph SDK ===
$uniqueMdName = "release-notes-$latestRelease.md"

# Normalize folder path: empty -> root of drive; otherwise trim slashes and append one
$folderPrefix = ""
if (-not [string]::IsNullOrWhiteSpace($pdfConversionFolderPath)) {
    $folderPrefix = $pdfConversionFolderPath.Trim('/') + '/'
}

$driveId = $pdfConversionDriveId
Write-Host "Using drive ID: $driveId"

# Path-syntax DriveItemId for creating a new file by path
$uploadItemPath = "root:/${folderPrefix}${uniqueMdName}:"
$pdfLocalPath   = "$sourcesDirectory/$attachementName"
$uploadedItemId = $null

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

foreach ($customer in $configMail.customers) {
    Write-Host "Processing customer: $($customer.name)"

    $params = @{
        message = @{
            subject = $mailSubject
            body = @{
                contentType = "HTML"
                content     = $mailBody
            }
            toRecipients = @(
                $customer.toRecipients | ForEach-Object {
                    @{ emailAddress = @{ address = $_ } }
                }
            )
            CcRecipients = @(
                $customer.ccRecipients | ForEach-Object {
                    @{ emailAddress = @{ address = $_ } }
                }
            )
            attachments = @(
                @{
                    "@odata.type" = "#microsoft.graph.fileAttachment"
                    name          = $attachementName
                    contentType   = "application/pdf"
                    contentBytes  = $pdfContent
                }
            )
        }
    }

    Write-Host "Sending email to: $($customer.toRecipients -join ', ')"
    Send-MgUserMail -UserId $configMail.fromAddress -BodyParameter $params
}