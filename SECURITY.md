# Security

## Reporting a vulnerability

Please **don't open a public issue** for security problems. Report them
privately through GitHub:
**[Report a vulnerability](https://github.com/thiefspin/zag/security/advisories/new)**
(Security tab → Advisories).

Include the library and version or commit, what an attacker can do, and the
smallest reproduction you have. You'll get a reply within a week. A fix and an
advisory are published together once a patched release is out.

## Supported versions

Before 1.0, only the latest release gets security fixes.

## Scope

Examples of what counts:

- **zag-http:** request parsing (smuggling, header injection), path traversal
  via wildcards, memory safety, internal details leaking in responses, and
  `zag.Client` sending credentials to the wrong host.
- **zag-pg:** authentication (SCRAM/MD5), SQL injection through the parameter
  API, and protocol parsing of malicious server responses.

Known non-goals today, which are not vulnerabilities:

- zag-pg has no TLS. Use it only on trusted networks.
- The zag-http server has no TLS. Terminate it at a proxy.
