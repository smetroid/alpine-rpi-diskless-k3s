# Security Policy

## Supported Versions

We release patches for security vulnerabilities. Currently supported versions:

| Version | Supported          |
| ------- | ------------------ |
| 1.0.x   | :white_check_mark: |

## Reporting a Vulnerability

If you discover a security vulnerability, please report it responsibly:

1. **Do NOT** create a public GitHub issue
2. Email the maintainer directly or use GitHub's private vulnerability reporting
3. Include as much detail as possible:
   - Description of the vulnerability
   - Steps to reproduce
   - Potential impact

## Security Considerations

### Sensitive Data

- Never commit secrets, tokens, or keys to the repository
- Use environment variables or secure vaults for sensitive configuration
- The `.gitignore` file excludes `*.yaml`, `*.key`, and `*.pem` files

### Network Security

- Default configurations use private network ranges
- SSH keys should be generated externally and added to config
- Consider network isolation for production clusters

### k3s Security

- k3s token should be kept secret
- Use k3s built-in security features (Pod Security Policies, Network Policies)
- Keep k3s version up to date

## Updates

We will announce security updates via GitHub releases.