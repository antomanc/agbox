# Security policy

## Supported versions

Only the latest release receives fixes.

## Reporting a vulnerability

Please **don't open a public issue**. Use GitHub's
[private vulnerability reporting](https://github.com/antomanc/agbox/security/advisories/new)
with steps to reproduce. You'll get an answer within a week.

In scope: anything that makes agbox weaken a machine beyond what
[docs/security.md](docs/security.md) describes. For example: leaking secrets, unsafe file
permissions, SSH or firewall changes that don't do what they claim, or installer integrity
issues.

Running agents without prompts (`AGENT_MODE=yolo`) is a documented design choice, not a
vulnerability.
