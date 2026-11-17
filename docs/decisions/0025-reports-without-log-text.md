# 25. Keep log text out of installer reports

Status: Accepted

Date: 2026-10-06

## Context

A failure report is more useful with the installer's error output. The WiFi password is embedded in a late-command, and installer logs can echo commands, so log text can carry secrets onto the server, the journal and every SSE client.

## Decision

A failure reason is a fixed phrase plus at most the crash exception class. `install-report.sh` restricts it to a safe character set, and the server cleans and caps it again.

## Consequences

- Reports never leak secrets.
- Diagnosing a failure still needs the installer's own logs on the target.

## Alternatives

None recorded.
