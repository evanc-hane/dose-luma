# Upstream synchronization

DoseLuma has an independent Git history and product identity. Upstream changes
are reviewed and ported selectively instead of merging unrelated histories.

## Current baseline

- Upstream: `https://git.uwaterloo.ca/d273liu/syde660-medscan.git`
- Reviewed through: `ccbeab9189be303e744e025c82ea36b238bf714d`
- Review date: July 30, 2026

## Changes ported

- Removed the unsupported macOS push entitlement. DoseLuma already contained
  this fix.
- Raised the iOS application and test targets from iOS 16 to iOS 17.
- Updated applicable SwiftUI `onChange` closures for the iOS 17 API.
- Prevented missed doses from being displayed as “All medications taken.”
- Marked local medication notifications so tapping one starts the DoseLuma
  voice session; caregiver alerts do not start a call.
- Kept the shared backend `config` module object stable across the full test
  suite.

## Intentionally not copied

- The upstream repository reorganization and deleted legacy server files.
- Team engineering notebooks, reports, environment-specific network scripts,
  and the upstream web demo.
- MedScan branding, bundle identifiers, signing team, authorship metadata, and
  upstream generated benchmark artifacts.

DoseLuma-specific watchOS code, portfolio documentation, CI, dependency split,
SQLite persistence, and container safeguards remain authoritative.

## Future update workflow

1. Fetch or inspect `upstream/main`.
2. List commits after the reviewed SHA above.
3. Review each patch and map `app/medscan_swift` paths to
   `app/doseluma_swift`.
4. Preserve DoseLuma naming and configuration.
5. Run the backend regression suite and intent benchmark.
6. Compile iOS, watchOS, and macOS targets on a Mac before release.
