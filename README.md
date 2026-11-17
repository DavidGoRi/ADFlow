# ADFlow

[![CI](https://github.com/DavidGoRi/ADFlow/actions/workflows/ci.yml/badge.svg)](https://github.com/DavidGoRi/ADFlow/actions/workflows/ci.yml)
![PowerShell 5.1](https://img.shields.io/badge/PowerShell-5.1-blue)
![License: MIT](https://img.shields.io/badge/license-MIT-green)

*Leer en [español](README.es.md).*

**Automated joiner and leaver processing for Active Directory, written in PowerShell.**

HR sends a CSV with the people who start next month. ADFlow turns each row into
a ready-to-use account: a unique user name, the right OU for the department, the
right groups for the job title and a temporary password that must be changed at
the first logon. Every action is logged with the information needed to undo it.

> **Status: phase 1 of 5.** Onboarding works end to end against a simulated
> directory. Offboarding, rollback, home folders, the HTML report and the real
> Active Directory provider follow (see the [roadmap](#roadmap)).

## Why it is built this way

The logic never calls the ActiveDirectory module directly. It talks to a
**directory provider**, a small object with methods such as `FindUser`,
`NewUser` and `AddGroupMember`. Two providers implement it:

| Provider | Used for | Status |
| --- | --- | --- |
| `Mock` | tests, the demo, any PC without a domain | ready |
| `ActiveDirectory` | a real domain, through RSAT (`New-ADUser`, `Add-ADGroupMember`…) | phase 4 |

Because of that, every rule (names, OUs, groups, validation, idempotency, logging)
is tested with Pester on a normal Windows computer and in GitHub Actions, without
a domain controller.

```
HR CSV ──► Import-ADFlowHireFile ──► Invoke-ADFlowOnboarding ──► directory provider
            (validation)               │  Get-ADFlowSamAccountName     ├─ Mock (JSON)
                                       │  Get-ADFlowDepartmentOu       └─ ActiveDirectory (phase 4)
settings ──► Get-ADFlowConfig ─────────┤  Get-ADFlowGroupAssignment
                                       │  Get-ADFlowRandomPassword
                                       └─► audit trail: audit.jsonl, audit.csv, summary.json
```

## Features (phase 1)

- **Unique user names.** `María José García López` → `maria.garcia`. If it is
  taken: `maria.garcial` (initial of the second surname), then `maria.garcia2`,
  `maria.garcia3`… Accents and special letters are folded (`Íñigo` → `inigo`,
  `Groß` → `gross`), particles stay with their surname (`de la Fuente` →
  `delafuente`), hyphens and apostrophes are joined (`O'Connor` → `oconnor`) and
  the 20-character limit of `sAMAccountName` is respected without losing the
  numeric suffix. Names handed out earlier in the same run are also avoided.
- **OU by department and groups by job title**, from a JSON file. Matching
  ignores case, accents and extra spaces. Unknown departments are rejected;
  unknown titles only get the default groups, with a warning.
- **Secure temporary passwords** from a cryptographic generator, with upper and
  lower case letters, digits and symbols, without look-alike characters
  (`O/0`, `I/l/1`). They are returned only as `SecureString` and are never written
  to disk. Accounts are created with *change password at next logon*.
- **HR file validation**: comma or semicolon separated (Excel in Spanish uses
  `;`), UTF-8, required columns, repeated or malformed employee ids, invalid
  dates. One bad row does not stop the others.
- **Idempotent**: a person whose `EmployeeId` is already in the directory is
  skipped, so the same file can be run twice safely.
- **Three modes**: `-DryRun` (works out the whole plan and logs it as *Planned*),
  standard `-WhatIf`, and live.
- **Audit trail** per run in `output\runs\<RunId>\`: `audit.jsonl` (written as
  it happens), `audit.csv` and `summary.json`. Each change carries its reverse
  action (`RemoveUser`, `RemoveGroupMember`) for the rollback of phase 2.

## Quick start

Requirements: Windows PowerShell 5.1 (included in Windows 10/11). Nothing else
is needed to try it: the demo uses the simulated directory.

```powershell
git clone https://github.com/DavidGoRi/ADFlow.git
cd ADFlow

# See what would happen, without changing anything
.\ADFlow.ps1 -Action Onboard -CsvPath .\demo\new-hires.csv -DryRun

# Create the accounts in the simulated directory (output\mock-directory.json)
.\ADFlow.ps1 -Action Onboard -CsvPath .\demo\new-hires.csv -ResetMockDirectory
```

Dry run of the demo file (all names and data are fictitious):

```
Planned   E1001   maria.garcial         María José García López
Planned   E1002   jose.pena             José Ángel Peña Muñoz
Planned   E1003   pedro.delafuente      Pedro de la Fuente Ruiz
          Group GG-CRM-Users does not exist in the directory and was not assigned
Planned   E1004   inigo.martinezaragon  Íñigo Martínez-Aragón
Planned   E1005   ana.garcia2           Ana García Lorenzo
Planned   E1006   zoe.oconnor           Zoë O'Connor
          Title 'Brand Manager' has no role in the settings: only the default groups are given
Planned   E1007   maximiliano.fernande  Maximiliano Fernández-Villaverde
          Group GG-CRM-Users does not exist in the directory and was not assigned; Manager javier.moreno not found: the account has no manager
Rejected  E1008   -                     Lucía Gómez
          Department 'Legal' has no OU in the settings
Rejected  E1002   -                     José Peña
          EmployeeId 'E1002' is repeated (first on row 3)
Skipped   E0907   laura.sanchez         Laura Sánchez Ortega
          Employee E0907 already has the account laura.sanchez
Rejected  E1009   -                     Sofía
          LastName is empty; StartDate '2026-13-01' is not a yyyy-MM-dd date
Planned   E1010   jose.penam            José Ángel Peña Moreno

Run 20261117-174252-2246: 8 Planned, 3 Rejected, 1 Skipped
```

### Parameters of `ADFlow.ps1`

| Parameter | Default | Description |
| --- | --- | --- |
| `-Action` | | `Onboard` (more actions in later phases) |
| `-CsvPath` | | HR file of new hires |
| `-ConfigPath` | `config\adflow.json` | Domain, OUs, roles and groups |
| `-Provider` | `Mock` | Directory provider |
| `-MockSeedPath` | `demo\directory.json` | Starting state of the simulated directory |
| `-MockStatePath` | `output\mock-directory.json` | Where the simulated directory keeps its changes |
| `-LogPath` | `output\runs` | Audit trail folder |
| `-DryRun` | | Plan only, no changes |
| `-WhatIf` | | Standard PowerShell preview |
| `-ResetMockDirectory` | | Start the simulated directory again from the seed |
| `-PassThru` | | Return the result objects (passwords as `SecureString`) |

## HR file

UTF-8 CSV with a header, separated by `,` or `;`:

```
EmployeeId;FirstName;LastName;Department;Title;Manager;StartDate
E1001;María José;García López;IT;Helpdesk Technician;laura.sanchez;2026-12-01
```

| Column | Required | Notes |
| --- | --- | --- |
| `EmployeeId` | yes | 1-16 letters, digits or hyphens; unique in the file |
| `FirstName`, `LastName` | yes | Full names, with accents; two surnames are fine |
| `Department` | yes | Must exist in the settings |
| `Title` | yes | Job title; unknown titles get only the default groups |
| `Manager` | no | `sAMAccountName` of the manager |
| `StartDate` | no | `yyyy-MM-dd` |

## Settings

[`config/adflow.json`](config/adflow.json) maps departments to OUs and job titles
to groups:

```json
{
  "domain": { "upnSuffix": "corp.example.com", "mailDomain": "corp.example.com" },
  "naming": { "maxLength": 20 },
  "password": { "length": 16 },
  "defaultGroups": [ "GG-AllStaff" ],
  "departments": {
    "IT": { "ou": "OU=IT,OU=Staff,DC=corp,DC=example,DC=com" }
  },
  "roles": {
    "Helpdesk Technician": [ "GG-IT-Helpdesk", "GG-VPN-Users" ]
  }
}
```

The file is validated on load and every problem is reported at once.

## Audit trail

Each run writes a folder `output\runs\<yyyyMMdd-HHmmss-xxxx>\`:

```json
{"timestamp":"2026-11-17T17:43:00.4011501+01:00","runId":"20261117-174300-56fe","sequence":1,
 "action":"CreateUser","target":"maria.garcial","employeeId":"E1001","status":"Succeeded","message":"",
 "details":{"SamAccountName":"maria.garcial","Ou":"OU=IT,OU=Staff,DC=corp,DC=example,DC=com","...":"..."},
 "undo":{"Action":"RemoveUser","SamAccountName":"maria.garcial"}}
```

Statuses: `Succeeded`, `Failed`, `Planned` (dry run), `WhatIf`, `Skipped`,
`Rejected`. The logger refuses any detail called `Password` or holding a
`SecureString`. `output\` is in `.gitignore`: in real use it contains personal data.

## Tests

130 Pester tests cover name generation, passwords, settings, HR file validation,
the simulated directory, the audit trail, the three modes, failures in the
directory and the entry script. They also check that every script is UTF-8 with
BOM (needed by Windows PowerShell 5.1 for accented text) and that the sample data
only uses the reserved `example.com` domain.

```powershell
Install-Module Pester -MinimumVersion 5.5 -Scope CurrentUser -SkipPublisherCheck
Install-Module PSScriptAnalyzer -Scope CurrentUser

Invoke-Pester -Path .\tests
Invoke-ScriptAnalyzer -Path . -Recurse -Settings .\PSScriptAnalyzerSettings.psd1
```

GitHub Actions runs both on Windows PowerShell 5.1 for every push.

## Roadmap

1. **Core and onboarding** ✅ — provider layer and simulated directory, unique
   names, OUs and groups, passwords, HR file validation, `-DryRun`/`-WhatIf`,
   audit trail, tests and CI.
2. **Offboarding and rollback** — disable the account, remove its groups and keep
   them in the log, move it to the leavers OU; `Undo-ADFlowRun` replays the
   `undo` entries of a run in reverse order.
3. **Home folders, welcome email and report** — personal folder with NTFS
   permissions, welcome message from a template (generated, not sent) and an
   HTML report of each run.
4. **Active Directory provider and lab** — the same methods on top of RSAT, and
   a guide to build a test domain with Windows Server Evaluation in Hyper-V.
5. **Polish** — screenshots, changelog and version 1.0.0.

## Project layout

```
ADFlow.ps1                 entry point
config/adflow.json         sample settings (fictitious domain)
demo/new-hires.csv         sample HR file
demo/directory.json        starting state of the simulated directory
src/Naming.ps1             accent folding and unique user names
src/Password.ps1           temporary passwords
src/Config.ps1             settings, departments and roles
src/HRFile.ps1             HR file reading and validation
src/MockDirectory.ps1      simulated directory provider
src/Audit.ps1              audit trail
src/Onboarding.ps1         onboarding
tests/                     Pester tests
```

## License

[MIT](LICENSE). All people, ids and domains in this repository are fictitious.
