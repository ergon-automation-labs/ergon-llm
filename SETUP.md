# Development Setup

## Initial Setup

After cloning the repository, run:

```bash
make setup
```

This will:
1. Initialize git (if not already initialized)
2. Install dependencies (`mix deps.get`)
3. Install git hooks for automated pre-push validation

## Git Hooks

This repository uses git hooks to automate validation and release publishing.

### Pre-push Hook

**Installed:** `git-hooks/pre-push`  
**Configured via:** `git config core.hooksPath git-hooks`

#### What it does:

- **On main branch pushes:**
  - Runs `mix deps.get` to ensure dependencies are up-to-date
  - Runs full test suite
  - Compiles code with `mix compile --force`
  - Builds OTP release with `MIX_ENV=prod mix release`
  - Creates version-stamped tarball
  - Publishes release to GitHub using `gh release create`
  - Proceeds with push only if all checks pass

- **On feature branch pushes:**
  - Skips validation (tests run in GitHub Actions)
  - Allows push to proceed

#### Bypassing the hook:

If needed, you can skip the pre-push hook:

```bash
git push --no-verify
```

**Note:** This is not recommended for main branch pushes, as it skips the validation and release publishing.

## Manual Release Publishing

If the automatic hook fails or you need to manually build and publish:

```bash
# Build release (runs tests first)
make release

# Publish release to GitHub
make publish-release
```

## Reinstalling Hooks

If you accidentally delete or corrupt the hooks:

```bash
make setup-hooks
```

This will reconfigure git to use the `git-hooks/` directory.
