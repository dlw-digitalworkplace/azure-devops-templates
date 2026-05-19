param (
    [Parameter(Mandatory=$true)]
    [string]$sourcesDirectory,
    [Parameter(Mandatory=$true)]
    [string]$changeLogFolder
)

$changeLogFolderPath = "$sourcesDirectory/$changeLogFolder"

Write-Host "Release notes folder contents:"
Get-ChildItem $changeLogFolderPath

if (-not (Test-Path -Path $changeLogFolderPath)) {
    Write-Output "Change log folder not found: $changeLogFolderPath"
    exit 1
}

$latestRelease = [System.Version]"0.0.0"
Get-ChildItem -Path $changeLogFolderPath/*.json | ForEach-Object {
    $releaseNotes = Get-Content -Path $changeLogFolderPath/$($_.Name) -Raw | ConvertFrom-Json

    if ([System.Version]$releaseNotes.version -gt [System.Version]$latestRelease) {
        $latestRelease = [System.Version]$releaseNotes.version
    }
}

$tillRelease = "$($latestRelease.Major).$($latestRelease.Minor).$($latestRelease.Build + 1)"

Write-Host "Latest release found: $latestRelease"
Write-Host "##vso[task.setvariable variable=latestRelease;isOutput=true]$latestRelease"
Write-Host "##vso[task.setvariable variable=tillRelease;isOutput=true]$tillRelease"
