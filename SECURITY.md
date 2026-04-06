# Security Policy

## Security Posture

This project is a local-first MLOps platform reference stack and learning lab.
It is intentionally designed to be easy to run and inspect on a laptop, not to
serve as a production-ready secure distribution.

Documented simplifications include:

- checked-in lab credentials for local-only use
- simplified authentication and secret-management posture
- static local networking assumptions
- single-node or low-replica operational defaults
- limited hardening around persistence, retention, and enterprise controls

Those tradeoffs are intentional for the purpose of local learning and platform
exploration. They should not be copied directly into production environments.

## What Is Likely In Scope

Examples of issues that are useful to report privately:

- unintended credential exposure beyond the repo's documented lab defaults
- command or script behavior that can affect the host in unexpected or unsafe ways
- privilege escalation or cross-tenant access that exceeds the repo's intended model
- supply-chain or dependency issues that create avoidable risk in the default path
- sensitive information disclosure that is not already intentional and documented

## What Is Probably Not A Security Bug Here

The following are already part of the documented local-lab posture:

- checked-in local credentials intended only for isolated development use
- absence of enterprise auth, secret rotation, or production-grade secret storage
- lack of HA, compliance controls, or hardened multi-environment deployment patterns
- trusting the local developer environment more than a production platform should

Those limitations are real, and they matter, but they are not surprises in the
context of this repo.
