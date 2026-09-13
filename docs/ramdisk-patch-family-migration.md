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
    7.0/
    7.1.1/
    7.2.0/
    7.2.1-plus/
    7.4.1/
  init-post/
    family-a/
    family-b/
    family-c/
  root-password/
    <context-family>/
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

## Compatibility and patch sets

The existing `patches.ramdisk` array remains supported. The opt-in
`patches.ramdisk_sets` array selects ordered reusable sets from
`config/_common/ramdisk/patch-sets.json`, followed by any direct entries.
Duplicate paths are errors.

`patch-sets.json` composes, in order, the selected root-password, linuxrc,
init-post, optional platform, and global patches. Set names identify the
release combination, not the physical location of a patch.

Version names are only starting hypotheses. The linuxrc groups `6.2.4`, `7.0`,
`7.1.1`, `7.2.0`, `7.2.1-plus`, and `7.4.1`, and the init-post families A/B/C,
must be validated independently. A patch becomes global only after it applies
unchanged to every target ramdisk in its declared support range. Root-password
patches are not currently global because their passwd context differs.

## Migration rules

1. Use platform configuration paths only; do not recreate model-name paths.
2. Preserve the exact existing patch application order.
3. A new DSM build gets explicit family paths even when an older patch is
   byte-identical. This prevents a later build-specific edit changing an older
   build.
4. Retain `config/_common/v*`, direct arrays, and legacy model paths until a
   separate removal change has passed validation.

## Required validation

1. Validate all JSON with `jq empty` and shell code with `bash -n`.
2. Compare each migrated configuration's expanded order with its predecessor.
3. Run `patch --dry-run -p1` against original unpacked ramdisks for every
   represented platform/build.
4. Build at least one loader per changed family.
