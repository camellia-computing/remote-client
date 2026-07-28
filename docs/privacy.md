# Camellia Remote privacy boundary

Camellia Remote is pre-release software. This document describes the source baseline; it is not a jurisdiction-specific consumer privacy notice and does not announce a hosted service.

The client handles device identifiers, network addresses, authentication material, clipboard content, transferred files, session metadata, optional recordings, and diagnostic logs as required by features the user enables. Remote-session content is exchanged with the selected peer and, when direct connectivity fails, the configured relay. Account, policy, device, and audit requests go only to the management endpoint configured by the operator. The baseline does not compile in a Camellia telemetry, update, rendezvous, relay, or management endpoint.

Credentials and permanent-password material use platform-protected or encrypted local storage where implemented. Logs must not contain passwords, access tokens, private keys, clipboard/file contents, or full device-verification secrets. Operators control their servers, retention, backups, access policy, and any legal notice required for their deployment.

Before distributing a build connected to a hosted service, the distributor must publish an accurate service-specific privacy notice, identify the controller and contact route, document purposes, retention, subprocessors, transfer locations, user rights, and incident handling, and ensure that the compiled configuration matches that notice.

Do not report private data or vulnerabilities in a public issue. Follow [SECURITY.md](../SECURITY.md).
