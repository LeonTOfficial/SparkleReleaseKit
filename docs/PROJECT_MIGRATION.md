# Migrate managed project files

`project upgrade` updates SparkleReleaseKit's public configuration schema and
generated templates. It does not update an installed app, the SparkleReleaseKit
CLI, or the Sparkle Swift Package dependency.

## Preview first

```bash
sparklekit project upgrade "/path/to/YourApp"
sparklekit project upgrade "/path/to/YourApp" --json
```

Preview is the default and writes nothing. It reports:

- source and target schema versions;
- source and target SparkleReleaseKit versions;
- the migration identifier;
- created, updated, unchanged, and preserved paths;
- bounded textual diffs; and
- conflicts caused by missing ownership evidence or manual changes.

Potentially sensitive diff lines are redacted and long diffs are bounded.

## Apply a reviewed migration

```bash
sparklekit project upgrade "/path/to/YourApp" --apply
```

Apply proceeds only when every changed generated file still matches its
recorded SHA-256. Manual edits are never overwritten. Unknown additional files
are preserved. Missing managed files may be restored.

The operation acquires the project integration lock, revalidates snapshots,
creates a timestamped backup under `.sparklekit/backups/`, writes atomically,
and rolls back every touched path if any step fails. Symlinks and paths that
could escape the project are rejected. A successful second run is idempotent
and performs no unnecessary writes.

## Resolve a conflict

1. Review the reported current and desired diff.
2. Keep the local customization and manually incorporate the new generated
   behavior, or restore the last generated file from version control or a
   trusted backup.
3. Do not edit `.sparklekit/manifest.json` merely to make a hash match.
4. Run the preview again.
5. Apply only when the preview contains no conflicts.
6. Run `sparklekit doctor` and
   `sparklekit test --allow-project-execution`.

## Stored migration metadata

Schema v4 adds the following public, non-secret fields to `sparklekit.json`:

- `management.generatedByVersion`;
- `management.lastAppliedMigration`;
- `management.knownTemplateVersion`;
- `management.managedFiles[].path`;
- `management.managedFiles[].originalTemplateSHA256`; and
- `management.managedFiles[].templateVersion`.

The internal `.sparklekit/manifest.json` records the exact SHA-256 of each
generated file after apply. Neither file contains private signing keys.

Schemas v1 through v3 are decoded with controlled defaults and rewritten only
after explicit apply. Unsupported future schemas are rejected rather than
guessed.
