# Changelog

All notable changes to ADFlow are listed here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [semantic versioning](https://semver.org/).

## [Unreleased]

### Added
- Live demo on GitHub Pages (https://davidgori.github.io/ADFlow/), in English and Spanish: a real onboarding, offboarding and rollback on fictitious data, rebuilt weekly by `.github/workflows/demo.yml` with `tools/Build-Demo.ps1`.
- Console GIF in the README, and `tools/Update-Screenshots.ps1` to regenerate every picture in `docs/` from the demo.

## [1.0.0] - 2026-11-17

First stable release. Download `ADFlow-1.0.0.zip`, extract it and run `ADFlow.ps1 -Action Onboard -CsvPath .\demo\new-hires.csv -DryRun`: the demo needs nothing else, not even a domain.

### Onboarding
- New accounts from an HR CSV (comma or semicolon separated, UTF-8), with every row validated and one bad row never stopping the others.
- Unique `sAMAccountName`: accent folding, surname particles (`de la Fuente` → `delafuente`), second-surname initial and numeric suffixes, 20-character limit.
- OU by department and groups by job title from `config/adflow.json`, matched without regard to case, accents or spaces.
- Cryptographically random temporary passwords, returned only as `SecureString`, never written to disk; *change password at next logon*.
- Personal folder created with protected NTFS permissions in one step: SYSTEM, Administrators and admin groups with full control, the user with Modify.
- Welcome email drafts (`.eml`, opened by Outlook as a draft) from an HTML template, to the manager with a copy to the helpdesk, never with the password.
- Idempotent: people already in the directory are skipped.

### Offboarding
- Leavers by `EmployeeId` or `SamAccountName`: the groups, OU and state are recorded, then the account is disabled, described with the leave date and reason, removed from its groups (except `keepGroups`), moved to the leavers OU, and its personal folder is archived.
- Protected accounts (`administrator`, `krbtgt`…) and members of protected groups (`Domain Admins`…) are never touched.

### Rollback and audit
- Every change is logged in `audit.jsonl` with its reverse action; `Undo-ADFlowRun` (`-Action Undo`) replays them from last to first, as a run of its own, with a guard against undoing a run twice. Folders with files are never deleted.
- `-DryRun` and `-WhatIf` for every action.
- Self-contained HTML report of every run (`report.html`), light and dark, with every value escaped; it says when a run was rolled back.

### Directory providers
- `Mock`: a simulated directory in JSON, for the demo, the tests and any computer without a domain. Accounts and groups get fictitious SIDs, so folder permissions are real.
- `ActiveDirectory`: the same operations through RSAT, with `-Server` and `-Credential`, escaped LDAP filters and unique CNs.
- `tools/New-ADFlowLab.ps1` and a lab guide (`docs/LAB.md`, `docs/LAB.es.md`) for a free test domain with Windows Server Evaluation in Hyper-V.

### Quality
- More than 300 Pester tests and PSScriptAnalyzer on Windows PowerShell 5.1 in GitHub Actions, with contract tests shared by both providers (the ActiveDirectory one against a simulated ActiveDirectory module).
- Release zip with SHA-256 checksum, built and published by GitHub Actions from the version tag.

[1.0.0]: https://github.com/DavidGoRi/ADFlow/releases/tag/v1.0.0
