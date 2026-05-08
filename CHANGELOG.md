# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0-rpi5-diskless] - 2026-03-19

### Added
- Working RPI5 Alpine diskless installation with NFS support
- Late-services for NFS startup after system is fully up

### Fixed
- NFS service startup dependency issues
- Removed unused /etc/k3s directory from overlay

### Known Issues
- Documentation still needs polish
- No automated CI/CD pipeline

---

For detailed technical fixes and improvements, see [docs/CHANGELOG-fixes.md](./docs/CHANGELOG-fixes.md).