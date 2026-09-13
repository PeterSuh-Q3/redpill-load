# Ramdisk patch-family migration

## Goal

Patch files are owned by the file they modify and by a verified compatibility
family, never by a model name and never by an all-purpose DSM-version folder.
Release configurations are platform configurations only. Top-level model-name
paths have been removed; the loader resolves its release configuration from
the selected Synology platform.

## Canonical layout

```text
config/_common/ramdisk/
  patch-sets.json
  global/
    common-etc-rc.patch
    disable-disabled-ports.patch
  linuxrc/
    6.2.4/
    7.0.1-7.1.0/
    7.1.1/
    7.2.0/
    7.2.1-7.4.1/
    7.4.1/               # revision-90080-plus exception only
  init-post/
    family-a-6.2.4/
    family-b-7.0.1/
    family-c-7.1.0-7.2.0/
    family-d-7.2.1-7.3.1/
    family-e-7.3.0/
    family-f-7.3.2-7.4.1/
  root-password/
    legacy/
    7.2.0-7.4.1/
  platform/
    epyc7002/
    v1000nk/
    apollolake/
    ...
```

`linuxrc` contains only patches for `linuxrc.syno.impl`; `init-post` contains
only patches for `/usr/sbin/init.post`; `root-password` contains only patches
for `/etc/passwd`. A directory such as `ramdisk/dsm-7.4.1` is forbidden because
it mixes target files and hides independently changing compatibility boundaries.

### DSM 7.4.1-90080 fresh-install disk-ready wait exception

DSM 7.4.1-90080 adds `CheckAllDiskReady()`, a 120 × 5-second retry before md0
assembly. This protects an existing system whose disks appear late, but is a
deterministic 600-second delay on a first installation with blank installable
disks: md0 cannot exist before DSM creates its system partitions.

The canonical patch location and name are:

```text
config/_common/ramdisk/linuxrc/7.4.1/
  ramdisk-006-skip-fresh-install-disk-ready-wait.patch
```

`006` is reserved for this new behavior; existing patch numbers are not
renumbered. The patch introduces `IsFreshInstallWithoutSystemPartitions()` and
replaces only the exact `CheckAllDiskReady` call site. It skips the wait only
when `/sys/block/md0` is absent, `synodiskport -installable_disk_list` returns
one or more non-loader disks, and every returned disk exists without a sysfs
partition entry. Any existing partition, empty installable-disk result, or
unknown disk state retains the vendor wait. It applies only to revision 90080+
with the verified `CheckAllDiskReady` source signature.

## Compatibility and patch sets

The existing `patches.ramdisk` array remains supported. The opt-in
`patches.ramdisk_sets` array selects ordered reusable sets from
`config/_common/ramdisk/patch-sets.json`, followed by any direct entries.
Duplicate paths are errors.

`patch-sets.json` defines *atomic* ordered patch sets. Each set represents one
target-file compatibility decision: a root-password context, one linuxrc
family, one init-post family, one platform exception, or one global patch.
Set names identify that single capability and family, not a complete release.

Version names are compatibility claims backed by byte comparison and existing
per-release use. The linuxrc groups are `6.2.4`, `7.0.1-7.1.0`, `7.1.1`,
`7.2.0`, and `7.2.1-7.4.1`; the root-password groups are `legacy` and
`7.2.0-7.4.1`. Init-post families remain independently classified. A patch
becomes global only after it applies unchanged to every target ramdisk in its
declared support range.

The fresh-install wait exception is a separate atomic set, not part of
`linuxrc-7.4.1`: `linuxrc-fresh-install-skip-disk-ready-wait-90080-plus`.
Platforms can select it independently after the original ramdisk passes the
signature and dry-run checks.

## Atomic patch-set composition

Release configurations compose the required capabilities directly in
`patches.ramdisk_sets`; they must not select a monolithic
`dsm-<version>-base` set that hides its components.

```json
{
  "patches": {
    "ramdisk_sets": [
      "root-password-7.4.1",
      "linuxrc-7.4.1",
      "init-post-family-f-7.3.2-7.4.1",
      "global-common-etc-rc"
    ],
    "ramdisk": []
  }
}
```

For a platform that must exclude only the linuxrc patch, such as a hypothetical
`epyc7002` exception, it omits only `linuxrc-7.4.1` while retaining the other
sets:

```json
"ramdisk_sets": [
  "root-password-7.4.1",
  "init-post-family-f-7.3.2-7.4.1",
  "global-common-etc-rc"
]
```

Platform-specific inclusion is equally explicit: add a narrowly scoped set
such as `platform-epyc7002-<purpose>` at the required point in the array. Do
not create a duplicate release-wide set merely to add or remove one patch.
The resolver preserves the declared order and rejects a duplicate patch path,
so an exception remains reviewable in its platform `config.json`.

## Migration rules

1. Use platform configuration paths only; do not recreate model-name paths.
2. Preserve the exact existing patch application order.
3. A version range is named only after the source patch body was compared. The
   initial migration preserves every distinct source body, including the
   ds3615xs init-post exceptions, as a separate atomic set.
4. A configuration must contain only `ramdisk_sets` after migration; direct
   arrays are reserved for a genuinely release-local patch introduced later.
   Do not restore removed model-name or legacy `config/_common/v*` paths.

## Baseline inventory and implementation map

The following inventory was taken after removal of top-level model paths and
uses the remaining 179 platform release configurations as the only reference
set. It is the required input to the full migration; no patch is moved or
deleted merely because its filename looks version-specific.

| Category | Current evidence | Destination and action |
| --- | --- | --- |
| Common root-password patch | 175 platform references | Classify its `/etc/passwd` context, then move into `root-password/<family>/`; it is not automatically global. |
| `v7.2.0` root-password patch | 22 references | Separate root-password family after dry-run validation. |
| `v7.2.2` root-password patch | 17 references | Separate root-password family after dry-run validation. |
| `v7.3.0`, `v7.3.1`, `v7.3.2`, `v7.4.0` root-password patches | 16, 15, 16, 36 references | Group only when original passwd context and patch content both match; otherwise retain separate root-password families. |
| `ramdisk-002-init-script` | 11–38 references per DSM release | Move by content and dry-run result to `linuxrc/6.2.4`, `7.0`, `7.1.1`, `7.2.0`, `7.2.1-plus`, or `7.4.1`. |
| `ramdisk-003-post-init-script*` | 1–38 references per DSM release | Move independently to `init-post/family-a` through `family-f`; special variants stay separate until their target context is proven identical. |
| `ramdisk-005-disable-disabled-ports` | 65 references | Move to `global/` only after the matrix proves it applies to every declared target; otherwise preserve an explicit compatibility set. |
| `ramdisk-common-etc-rc` | 179 references | First global-patch candidate; validate across the complete platform matrix before moving. |
| `v7.4.0/ramdisk-004-disable-fsdn-feature` | 1 reference | Keep as a platform/release-specific patch; do not generalize it. |

### Confirmed unused patch files

These 23 paths had zero references in every remaining platform configuration
and were deleted in commit `93e9958`. The subsequent full migration removes
the remaining referenced legacy paths only after the byte-equivalence check.

```text
ramdisk-002-init-script-NEW-name.patch
ramdisk-002-init-script-OLD-name.patch
ramdisk-003-post-init-script-LOWER.patch
ramdisk-003-post-init-script-UPPER.patch
ramdisk-004-network-hosts.patch
v6.2.4/ramdisk-003-post-init-script-ds3615xs.patch
v6.2.4/ramdisk-004-network-hosts.patch
v6.2.4/ramdisk-004-rc-script.patch
v7.0.1/ramdisk-004-network-hosts.patch
v7.0.1/ramdisk-004-rc-script.patch
v7.1.0/ramdisk-003-post-init-script-ds3615xs.patch
v7.1.0/ramdisk-004-network-hosts.patch
v7.1.0/ramdisk-004-rc-script.patch
v7.1.1/ramdisk-004-network-hosts.patch
v7.1.1/ramdisk-004-rc-script.patch
v7.2.0/ramdisk-004-network-hosts.patch
v7.2.0/ramdisk-004-rc-script.patch
v7.2.1/ramdisk-000-loop.patch
v7.2.2/ramdisk-000-loop.patch
v7.3.0/ramdisk-000-loop.patch
v7.3.1/ramdisk-000-loop.patch
v7.3.2/ramdisk-000-loop.patch
v7.4.0/ramdisk-000-loop.patch
```

The `init-script` content audit already shows that `v7.0.1` and `v7.1.0` are
identical, while the confirmed `v7.3.2` through `v7.4.1` compatibility range
uses the same init-post patch body. It is represented explicitly as
`family-f-7.3.2-7.4.1`; special variants remain separate.

### Full migration sequence

1. Add canonical copies under the target-file hierarchy for every referenced
   patch family, preserving content and patch order.
2. Add atomic named patch sets for each independently selectable capability.
3. Convert every platform `config.json` to an ordered composition of atomic
   `patches.ramdisk_sets`.
4. Compare each expanded list with the pre-migration platform list by
   position and patch-file bytes. `docs/ramdisk-patch-baseline.json` records
   that immutable 179-configuration baseline.
5. Delete obsolete direct files and `v*` copies only after the comparison
   reports no differences.

## Required validation

1. Validate all JSON with `jq empty` and shell code with `bash -n`.
2. Compare each migrated configuration's expanded order with its predecessor.
3. Run `patch --dry-run -p1` against original unpacked ramdisks for every
   represented platform/build.
4. Build at least one loader per changed family.
