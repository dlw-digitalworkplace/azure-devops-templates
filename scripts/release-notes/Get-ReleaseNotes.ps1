param(
    [Parameter(Mandatory=$true)]
    [string]$changeLogFolder,
    [Parameter(Mandatory=$true)]
    [string]$fromVersion,
    [Parameter(Mandatory=$true)]
    [bool]$includeDeploymentNotes,
    [Parameter(Mandatory=$true)]
    [bool]$includeDescription,
    [Parameter(Mandatory=$true)]
    [bool]$includeTechnicalNotes,
    [Parameter(Mandatory=$true)]
    [string]$releaseNotesOutputPath,
    [Parameter(Mandatory=$true)]
    [string]$sourcesDirectory,
    [Parameter(Mandatory=$true)]
    [string]$tillVersion
)

class ReleaseNotes {
    [System.Collections.Generic.List[System.String]]return_lines($pth, $notes, $outputConfig) {
        $lines = New-Object System.Collections.Generic.List[System.String]

        $notes = $notes | ForEach-Object {
            $component = if ([string]::IsNullOrEmpty($_.component)) { "Miscellaneous" } else { $_.component }
            $_ | Add-Member -NotePropertyName 'component' -NotePropertyValue $component -Force -PassThru
        }

        $notes | Group-Object -Property component | ForEach-Object {
            $component = $_.Name
            $lines.Add("### $component")
            $_.Group | ForEach-Object {
                $note = $_
                $title = [string]::IsNullOrEmpty($note.title) ? "<-- No title provided -->" : $note.title
                if (-not [string]::IsNullOrEmpty($note.readiness)) { $title = "$($title) ($($note.readiness))"}
                if ($note.isBreakingChange) { $title = "! BREAKING ! $($title)"}

                $lines.Add(" - $($title)")
                if ($true -eq $outputConfig.includeDescription -and $null -ne $note.publicDescription) {
                    $lines.Add("   - $($note.publicDescription)")
                }

                if ($true -eq $outputConfig.includeTechnicalNotes -and $null -ne $note.technicalNotes) {
                    $lines.Add("   - Technical: $($note.technicalNotes)")
                }
            }

            $lines.Add("")
        }

        return $lines
    }
}

Write-Output "Start generating release notes..."

$outputConfig = @{
    includeDescription = $includeDescription
    includeTechnicalNotes = $includeTechnicalNotes
}

$pth = "$sourcesDirectory/$releaseNotesOutputPath"
$changeLogFolderPath = "$sourcesDirectory/$changeLogFolder"

Write-Host "Logging sources directory contents..."
Get-ChildItem $sourcesDirectory

Write-Host "output path for release notes..."
Write-Host $pth

Write-Host "Logging change log folder path contents..."
Get-ChildItem $changeLogFolderPath

if (-not (Test-Path -Path $changeLogFolderPath)) {
    Write-Output "Change log folder not found: $changeLogFolderPath"
    exit 1
}

$engine = New-Object -TypeName ReleaseNotes
$dict = New-Object 'System.Collections.Generic.Dictionary[String, Object]'

New-Item -Path $pth -ItemType File -Force
Get-ChildItem -Path $changeLogFolderPath/*.json | ForEach-Object {

    Write-Host "Found file $($_.Name)"

    $releaseNotes = Get-Content -Path $changeLogFolderPath/$($_.Name) -Raw | ConvertFrom-Json
    $date = Get-Date -Date $releaseNotes.date -Format "yyyy/MM/dd"
    $version = $releaseNotes.version

    if ($version -lt $fromVersion -and ($tillVersion -eq "N/A" -or $version -ge $tillVersion)) {
        continue
    }

    Write-Host "Adding lines for file $($_.Name)"

    $lines = New-Object System.Collections.Generic.List[System.String]
    
    $lines.Add("# Connect v$($version) ($($date))")
    
    if ($releaseNotes.comments.major.length -gt 0) {
        $lines.Add("`n## Major changes")
        $lines.AddRange($engine.return_lines($pth, $releaseNotes.comments.major, $outputConfig))
    }

    if ($releaseNotes.comments.minor.length -gt 0) {
        $lines.Add("`n## Minor changes")
        $lines.AddRange($engine.return_lines($pth, $releaseNotes.comments.minor, $outputConfig))
    }

    if ($releaseNotes.comments.patch.length -gt 0) {
        $lines.Add("`n## Patches")
        $lines.AddRange($engine.return_lines($pth, $releaseNotes.comments.patch, $outputConfig))
    }

    if($true -eq $includeDeploymentNotes){
        if($null -ne $releaseNotes.preDeploymentNotes -and $releaseNotes.preDeploymentNotes.length -gt 0){
            $lines.Add("`n## Predeployment notes")
            $releaseNotes.preDeploymentNotes | ForEach-Object {$lines.Add($_)}
        }

        if($null -ne $releaseNotes.postDeploymentNotes -and $releaseNotes.postDeploymentNotes.length -gt 0){
            $lines.Add("`n## Postdeployment notes")
            $releaseNotes.postDeploymentNotes | ForEach-Object {$lines.Add($_)}
        }
    }

    $lines.Add("")

    $dict.Add($version, $lines)
}

Write-Host "Dict count: $($dict.Count)"

# Sort by version number
$sortedLines = $dict.GetEnumerator() | Sort-Object -Property Key | ForEach-Object {
    $_.Value
}

Write-Host "Writing lines to: $($pth)"

# Write to file
$sortedLines | ForEach-Object {
    Write-Host "Writing line: $($_)"
    $_ | Out-File -FilePath $pth -Append
}

Write-Host "End of generating release notes"