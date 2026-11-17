# Test lab: a domain controller in Hyper-V

*Leer en [español](LAB.es.md).*

This guide builds a free, isolated test domain (`corp.example.com`) in a Hyper-V
virtual machine and runs ADFlow against it with `-Provider ActiveDirectory`.
Nothing here touches a real domain: the lab script refuses to run in any domain
other than the one in the sample data.

Time: about one hour, most of it waiting for installs.

## 1. What you need

- Windows 10/11 **Pro, Enterprise or Education** (Hyper-V is not available in
  Home), with virtualization enabled in the BIOS/UEFI.
- 8 GB of RAM at least (16 GB is comfortable) and 60 GB of free disk.
- Windows Server Evaluation: free for 180 days, no product key.

## 2. Enable Hyper-V

In PowerShell **as administrator**, then restart:

```powershell
Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All
```

## 3. Download Windows Server Evaluation

Download the ISO of **Windows Server 2025** (or 2022) from the
[Microsoft Evaluation Center](https://www.microsoft.com/evalcenter).
Microsoft asks for a short form. The English ISO is the easiest to follow with
this guide.

## 4. Create the virtual machine

As administrator, with the path of your ISO:

```powershell
$iso = 'C:\ISO\WindowsServer2025_Eval.iso'
New-VM -Name DC01 -Generation 2 -MemoryStartupBytes 4GB -SwitchName 'Default Switch' `
    -NewVHDPath "$env:PUBLIC\Documents\Hyper-V\DC01.vhdx" -NewVHDSizeBytes 60GB
Set-VMProcessor -VMName DC01 -Count 2
Add-VMDvdDrive -VMName DC01 -Path $iso
Set-VMFirmware -VMName DC01 -FirstBootDevice (Get-VMDvdDrive -VMName DC01)
Start-VM -Name DC01
vmconnect.exe localhost DC01
```

Press a key when the VM says *Press any key to boot from CD or DVD*. Choose
**Windows Server … Standard Evaluation (Desktop Experience)**, a custom install
on the empty disk, and set the Administrator password.

The *Default Switch* gives the VM internet access through NAT, which is enough
for the lab. Its IP address can change after a restart of the host; for a lab
that is fine.

## 5. Turn the server into a domain controller

Inside the VM, in PowerShell as administrator:

```powershell
Rename-Computer -NewName DC01 -Restart
```

After the restart:

```powershell
Install-WindowsFeature AD-Domain-Services -IncludeManagementTools
Install-ADDSForest -DomainName corp.example.com -DomainNetbiosName CORP -InstallDns
```

It asks for a *Safe Mode Administrator* password and restarts. Sign in again as
`CORP\Administrator`.

`example.com` is reserved for documentation (RFC 2606), so this domain can never
clash with a real one.

**Take a checkpoint now**, so you can always go back to a clean domain:

```powershell
# On the host
Checkpoint-VM -Name DC01 -SnapshotName 'Clean domain'
```

## 6. Get ADFlow into the VM

The VM has internet through the Default Switch:

```powershell
Invoke-WebRequest https://github.com/DavidGoRi/ADFlow/archive/refs/heads/main.zip -OutFile $env:TEMP\adflow.zip
Expand-Archive $env:TEMP\adflow.zip -DestinationPath C:\
Get-ChildItem C:\ADFlow-main -Recurse | Unblock-File
Set-Location C:\ADFlow-main
```

## 7. Fill the lab with the sample data

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\New-ADFlowLab.ps1 -WhatIf
powershell -ExecutionPolicy Bypass -File .\tools\New-ADFlowLab.ps1
```

It creates the OUs of `demo/directory.json` (parents first), the groups in
`OU=Groups`, the sample users with random passwords nobody knows, and the shares
`\\DC01\home$` and `\\DC01\archive$` in `C:\Shares`. Run it again at any time:
it only creates what is missing.

Open **Active Directory Users and Computers** (`dsa.msc`) to see the result.

## 8. Run ADFlow against the domain

Always start with a dry run:

```powershell
$ad = @{ Provider = 'ActiveDirectory'; HomeRoot = '\\DC01\home$'; ArchiveRoot = '\\DC01\archive$' }

.\ADFlow.ps1 -Action Onboard -CsvPath .\demo\new-hires.csv @ad -DryRun
.\ADFlow.ps1 -Action Onboard -CsvPath .\demo\new-hires.csv @ad
```

Check in `dsa.msc` that the accounts are in their OUs and groups, and look at
the permissions of a personal folder:

```powershell
(Get-Acl \\DC01\home$\jose.pena).Access | Format-Table IdentityReference, FileSystemRights, IsInherited
```

Then the leavers, and the rollback (the run id is printed by the previous
command):

```powershell
.\ADFlow.ps1 -Action Offboard -CsvPath .\demo\leavers.csv @ad
.\ADFlow.ps1 -Action Undo -RunId <run id> @ad
```

Each run leaves `report.html` and the audit trail in `output\runs\<run id>\`.

To run ADFlow from your own computer instead of the DC, the computer must be
joined to the lab domain and have RSAT:

```powershell
Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0
.\ADFlow.ps1 -Action Onboard -CsvPath .\demo\new-hires.csv @ad -Server DC01.corp.example.com -Credential (Get-Credential)
```

## 9. Start again or clean up

```powershell
# On the host: back to the clean domain
Restore-VMCheckpoint -VMName DC01 -Name 'Clean domain' -Confirm:$false

# Or remove the lab completely
Stop-VM -Name DC01 -TurnOff
Remove-VM -Name DC01 -Force
Remove-Item "$env:PUBLIC\Documents\Hyper-V\DC01.vhdx"
```

The evaluation expires after 180 days; rebuilding the lab with this guide takes
about an hour.

## What the tests cover, and what only the lab shows

The GitHub Actions tests run the Active Directory provider against a simulated
ActiveDirectory module (`tests/FakeActiveDirectory.psm1`) and run the same
contract tests on both providers. That checks the logic, the LDAP filters and
the parameters ADFlow passes to each cmdlet. Only a real domain shows the rest:
permissions of the account that runs ADFlow, replication delays between
domain controllers, password policies, and how the file server applies the
folder permissions. That is what this lab is for.
