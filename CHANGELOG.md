# Changelog

All notable changes to this project are documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
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
