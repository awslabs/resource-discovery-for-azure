# Obfuscation Tests

Pester tests to validate that the obfuscation feature works correctly and no PII leaks into output files.

## Prerequisites

- PowerShell 7+
- Pester module (v5+)

```powershell
Install-Module -Name Pester -Force -Scope CurrentUser
```

## How to Run

### 1. Generate a test report with obfuscation enabled

```powershell
pwsh ./ResourceInventory.ps1 -SubscriptionID <your-sub-id> -Obfuscate -AutoAuth -Debug
```

### 2. Copy the output zip to the Tests folder

```powershell
cp /path/to/ResourcesReport_*.zip ./Tests/
```

### 3. Run the tests

```powershell
pwsh -Command "Invoke-Pester ./Tests/Obfuscation.Tests.ps1 -Output Detailed"
```

Or set environment variables to avoid editing the test file:

```powershell
$env:TEST_ZIP_PATH = "./Tests/ResourcesReport_202603301824.zip"
$env:TEST_SUBSCRIPTION_ID = "<your-subscription-id>"
$env:TEST_USER_EMAIL = "user@example.com"
pwsh -Command "Invoke-Pester ./Tests/Obfuscation.Tests.ps1 -Output Detailed"
```

### 4. Run skip-mode tests (no Azure needed)

Generate skip-mode output:
```powershell
pwsh ./ResourceInventory.ps1 -SubscriptionID <your-sub-id> -SkipMetrics -SkipConsumption -Obfuscate -AutoAuth
```

Then run:
```powershell
$env:TEST_ZIP_PATH = "./Tests/ResourcesReport_skip.zip"
pwsh -Command "Invoke-Pester ./Tests/Obfuscation.Tests.ps1 -Output Detailed"
```
