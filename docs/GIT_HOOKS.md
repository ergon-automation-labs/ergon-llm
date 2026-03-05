# Git Hooks for bot_army_llm

This project uses Git hooks to automate build validation and release publishing. When you push to main, the pre-push hook automatically validates, builds the OTP release, and publishes it to GitHub.

## Pre-Push Hook (`git-hooks/pre-push`)

**Runs automatically before every `git push`**

### What it does:
1. **On main branch:**
   - Runs `mix deps.get` to ensure dependencies are fresh
   - Runs `mix test` to validate all tests pass
   - Runs `mix compile --force` to check for compilation errors
   - **Builds OTP release** with `MIX_ENV=prod mix release`
   - **Creates tarball** and **publishes to GitHub release** automatically
   - **Blocks the push** if any check fails
   - If all succeed, push proceeds and Jenkins automatically detects the new release

2. **On feature branches:**
   - Skips full test suite (faster iteration during development)
   - Does not build or publish releases
   - Push proceeds immediately

### How to use:

**Normal push (automatic build and publish):**
```bash
git push origin main
# Pre-push hook validates, builds, and publishes
# If any step fails, the push is blocked - fix and try again
```

**Force push (skip hook checks):**
```bash
git push --no-verify origin main
# Bypasses all checks - use only in emergencies!
```

**Manual fallback (if hook fails):**
```bash
make release                # Build release locally
make publish-release        # Manually build and publish to GitHub
```

## Complete Workflow

```
You write code
        ↓
git push origin main
        ↓
Pre-push hook runs locally
  ✓ mix deps.get
  ✓ mix test
  ✓ mix compile
  ✓ MIX_ENV=prod mix release
  ✓ Create tarball
  ✓ gh release create v$VERSION
        ↓
  All pass? ─→ ✅ Code pushed + Release published
  Any fail? ─→ ❌ Push blocked (fix and try again)
        ↓
Jenkins detects new GitHub release
  ✓ Downloads tarball
  ✓ Deploys to Air node
  ✓ Publishes NATS events
        ↓
Deployment complete!
```

## Setup (Automatic)

The hook is configured in `git-hooks/` directory. Git is configured to use this directory via:

```bash
git config core.hooksPath git-hooks
```

To verify the hook is active:

```bash
cd bot_army_llm
git hook list          # Should show pre-push hook
```

## Troubleshooting

**Hook not running?**
```bash
# Verify git is using the right hooks path
git config core.hooksPath

# Verify hook file is executable
ls -la git-hooks/pre-push
chmod +x git-hooks/pre-push

# Test hook manually
git-hooks/pre-push < /dev/null
```

**Release already exists?**
The hook will continue with the push even if the GitHub release creation fails (release might already exist). Subsequent fixes to the code require a new version.

**Need to skip hook?**
```bash
git push --no-verify origin main
```

Use only in emergencies. The hook exists to prevent broken code from being pushed.
