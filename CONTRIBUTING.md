# Contributing to Alpine Linux Diskless k3s Cluster

Thank you for your interest in contributing!

## Getting Started

1. Fork the repository
2. Clone your fork: `git clone git@github.com:yourusername/diskless-alpine-k3s-rpi.git`
3. Create a feature branch: `git checkout -b feature/my-feature`

## Development Workflow

### Building the Project

```bash
# Validate configuration
make validate

# Build apkovl archives
make build

# Run tests (QEMU)
make test-qemu
```

### Code Style

- Use shellcheck to lint shell scripts: `shellcheck scripts/*.sh lib/*.sh`
- Format shell scripts with shfmt: `shfmt -w scripts/*.sh lib/*.sh`
- Follow the EditorConfig settings in `.editorconfig`

### Testing

- Test your changes with QEMU before submitting
- Verify the build completes without errors
- Check that generated apkovl archives are valid

## Submitting Changes

1. Commit your changes with descriptive commit messages
2. Push to your fork
3. Open a Pull Request against `main`
4. Fill in the PR template with relevant details

## Commit Message Format

Use conventional commit format:

```
type(scope): description

[optional body]
```

Types: `feat`, `fix`, `docs`, `style`, `refactor`, `test`, `chore`

Example:
```
feat(network): add support for static IP configuration

Add static IP assignment per node in YAML config.
Includes validation for IP address format.
```

## Questions?

- Open an issue for bugs or feature requests
- Use discussions for general questions

## License

By contributing, you agree that your contributions will be licensed under the MIT License.