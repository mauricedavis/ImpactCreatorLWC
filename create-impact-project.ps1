&lt;#
.SYNOPSIS
    Creates a complete SFDX project with the Impact Creator LWC and Apex classes.
.DESCRIPTION
    Run from whatever directory you want the project folder created in.
    It will create a folder called "mi-sbdc" (or you can change $ProjectName below).
.NOTES
    Requires: Salesforce CLI (sf) installed
    Usage:    .\create-impact-project.ps1
#&gt;

$ErrorActionPreference = "Stop"

# ── Config ───────────────────────────────────────────────────────────
$ProjectName = "ImpactCreatorLWC"

# ── Create SFDX project ─────────────────────────────────────────────
if (Test-Path $ProjectName) {
    Write-Host "Folder '$ProjectName' already exists. Using it." -ForegroundColor Yellow
} else {
    Write-Host "Creating SFDX project '$ProjectName'..." -ForegroundColor Cyan
    sf project generate --name $ProjectName --template standard
}

Set-Location $ProjectName

# ── Paths ────────────────────────────────────────────────────────────
$lwcDir   = "force-app\main\default\lwc\impactCreator"
$classDir = "force-app\main\default\classes"

New-Item -ItemType Directory -Path $lwcDir   -Force | Out-Null
New-Item -ItemType Directory -Path $classDir -Force | Out-Null

# ── Apex class meta XML ─────────────────────────────────────────────
$apexMeta = @'
<?xml version="1.0" encoding="UTF-8"?>
<ApexClass xmlns="http://soap.sforce.com/2006/04/metadata">
    <apiVersion>62.0</apiVersion>
    <status>Active</status>
</ApexClass>
'@

Set-Content -Path "$classDir\ImpactCreatorController.cls-meta.xml"     -Value $apexMeta -Encoding UTF8
Set-Content -Path "$classDir\ImpactCreatorControllerTest.cls-meta.xml" -Value $apexMeta -Encoding UTF8

# ── Done ─────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "========================================================" -ForegroundColor Green
Write-Host " Project created at: $(Resolve-Path .)" -ForegroundColor Green
Write-Host "========================================================" -ForegroundColor Green
Write-Host ""
Write-Host "Copy the downloaded files:" -ForegroundColor Yellow
Write-Host ""
Write-Host "  LWC (4 files) -> $lwcDir\" -ForegroundColor White
Write-Host "    impactCreator.js"
Write-Host "    impactCreator.html"
Write-Host "    impactCreator.css"
Write-Host "    impactCreator.js-meta.xml"
Write-Host ""
Write-Host "  Apex (2 files) -> $classDir\" -ForegroundColor White
Write-Host "    ImpactCreatorController.cls"
Write-Host "    ImpactCreatorControllerTest.cls"
Write-Host ""
Write-Host "Then connect your sandbox and deploy:" -ForegroundColor Yellow
Write-Host ""
Write-Host "  sf org login web -a mi-sbdc-sandbox -r https://test.salesforce.com" -ForegroundColor White
Write-Host "  sf project deploy start -d force-app -o mi-sbdc-sandbox" -ForegroundColor White
Write-Host ""
