# Resource Discovery for Azure

This is a PowerShell script provided by AWS that generates an inventory report including detailed metrics of an Azure environment to which you have read access for the previous 30 days.

This repository is focusing solely on read-only integrations with Azure APIs and Azure Monitor. Our goal is to deliver a 
reliable and efficient solution for Azure environment reporting, empowering you with comprehensive insights into your cloud resources and their utilization.

By leveraging this script, you can effortlessly generate Excel/JSON exports that provide a comprehensive overview of your Azure environment, including usage statistics, and performance metrics.

## Table of Contents

- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [Running the Script](#running-the-script)

## Prerequisites
- PowerShell 7 or Azure CloudShell PowerShell
- Azure CLI
- Azure CLI Account Extension
- Azure CLI Resource-Graph Extension
  
The script can be executed in both Azure Cloudshell PowerShell and PowerShell Desktop environments.  
For additional information on Azure CloudShell, please review this [article](https://learn.microsoft.com/en-us/azure/cloud-shell/get-started/classic?tabs=azurecli)

### Requirements
> **Note:** By default, script will attempt to install the necessary PowerShell modules and Azure CLI components, but you need **administrator** privileges during the script execution.
> You can also assign the following Roles in Azure to a user to execute the script:
- Reader Role
- Billing Reader Role
- Monitoring reader Role
- Cost Management Reader Role

## Installation

1. Clone the repository by running the following command

```bash
git clone https://github.com/awslabs/resource-discovery-for-azure.git
```

## Running the Script

The script uses concurrency to execute commands in parallel, especially when gathering metrics. By default, the concurrency limit is set to 6. To change this, use the `-ConcurrencyLimit` option. 

2. If you are in Azure CloudShell please ensure you select PowerShell , you're already authenticated. In PowerShell Desktop, you will be redirected to the Azure sign-in page.
3. Change directory to the location where repository was cloned
```powershell
cd resource-discovery-for-azure
```
4. Use the following command to run the script

```powershell
./ResourceInventory.ps1 -ConcurrencyLimit 8
```

When running the script from CloudShell - the output should be similar to this screenshot -  
For item 1 in the screenshot, it should state Bash as this means you are running in PowerShell

![CloudShell](./docs/cloudshell.png)

## Script Output/Reports
3. When the script has completed, a zip file of the report will be saved in the folder **_InventoryReports._**
     - Script will create multiple files and one zip 
         - Consumption_ResourcesReport_(date).json 
         - Inventory_ResourcesReport_(date).json 
         - Metrics_ResourcesReport_(date).json 
         - ResourcesReport_(date).xlsx 

     - The files are zipped up automatically and the zip
         - ResourcesReport_(date).zip

---

## Parameters

The following table lists the parameters that can be used with the script:

| Parameter         | Type     | Description                                                                                                     |
|-------------------|----------|-----------------------------------------------------------------------------------------------------------------|
| `$TenantID`       | String   | Specifies the Tenant ID you want to create a Resource Inventory                                                                                       |
| `$Appid`          | String   | Service Principal Authentication ID.                                                                                   |
| `$SubscriptionID` | String   | Specifies the Subscription which will be run for Inventory.                                                                                  |
| `$Secret`         | String   | Client Secret of the Service Principal key.                                                                                       |
| `$ResourceGroup`  | String   | Specifies the Resource Group.                                                                                   |
| `$Debug`          | Switch   | Enable Debug Mode                                                                                  |
| `$SkipConsumption`| Switch   | A switch to indicate if consumption metrics should be gathered.                                                |
| `$DeviceLogin`    | Switch   | A switch to trigger device login.                                                                               |
| `$ConcurrencyLimit` | Integer | Specifies the concurrency limit for parallel command execution. Default value is `6`.                            |

---

## ⚠️ Warning Messages

- **Important:** Script will not upgrade the current version of the Powershell modules.
  
- **Important:** If you're running the script inside Azure CloudShell, the final Excel will not have auto-fit columns, and you will see warnings during the script execution. This is an expected issue with the Import-Excel module but it does **not** affect the inventory which will remain accurate.

---
