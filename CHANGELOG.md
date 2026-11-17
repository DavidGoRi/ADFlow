# Changelog

All notable changes to this project are documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
- Phase 3: personal folder at onboarding, created with protected NTFS
  permissions (SYSTEM, Administrators and admin groups full control, the user
  Modify) and removed on rollback only when empty.
- Fictitious SIDs in the simulated directory, so folder permissions are real.
- Welcome email drafts (.eml, X-Unsent) from an HTML template, to the manager
  with a copy to the helpdesk, never with the password.
- HTML report of every run, refreshed when the run is rolled back, and
  `-Action Report`.
- Phase 2: offboarding from an HR file of leavers (by `EmployeeId` or
  `SamAccountName`): records the groups, disables the account, writes the
  leave reason, removes the groups except `keepGroups`, moves it to the leavers
  OU and archives the personal folder.
- Protected accounts and protected groups that offboarding never touches.
- `Undo-ADFlowRun` and `-Action Undo`: replays the reverse actions of a live run
  from the audit trail, with its own audit trail and a guard against undoing a
  run twice.
- Changes described as data (`Invoke-ADFlowAction`), shared by offboarding and
  rollback.
- Phase 1: onboarding from an HR CSV file against a replaceable directory
  provider, with a simulated (`Mock`) provider for tests and the demo.
- Unique `sAMAccountName` generation: accent folding, surname particles,
  second-surname initial and numeric suffixes, 20-character limit.
- OU by department and groups by job title from `config/adflow.json`.
- Cryptographically random temporary passwords returned as `SecureString`.
- HR file validation (comma or semicolon separated) and idempotent runs.
- `-DryRun` and `-WhatIf` modes.
- Audit trail per run (`audit.jsonl`, `audit.csv`, `summary.json`) with undo data.
- Pester tests, PSScriptAnalyzer settings and GitHub Actions CI.
