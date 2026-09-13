# DSM release ramdisk patch intake

Use this runbook when adding a new DSM release, for example DSM 7.4.2. It is
an intake process, not permission to extend an existing compatibility range by
version number alone. A new release joins a patch family only after its
original ramdisk passes the relevant checks.

The governing architecture is documented in
[`ramdisk-patch-family-migration.md`](ramdisk-patch-family-migration.md).

## Files that define a release

For every supported platform, add or update only these release-owned files:

```text
config/<synology-platform>/<DSM-version>-<build>/config.json
config/_common/ramdisk/patch-sets.json
```

`config.json` must name ordered atomic entries in `patches.ramdisk_sets`; it
must not use a model-name directory or reintroduce a direct
`patches.ramdisk` patch path. `build-loader.sh` resolves the platform config,
then `include/patch.sh` expands those set names using `patch-sets.json`.

## Intake procedure

1. Obtain the original PAT and unpack its ramdisk for each platform/build.
   Preserve an unmodified copy for comparison.
2. Inventory every target file touched by the current patch sets:

   ```text
   /etc/passwd
   /etc/rc
   /linuxrc.syno or /linuxrc.syno.impl
   /usr/sbin/init.post
   /usr/syno/web/webman/get_state.cgi
   /usr/syno/sbin/syno_feature_check.sh
   ```

3. For each existing atomic patch, run `patch --dry-run -p1` against the
   original unpacked ramdisk. Record the platform, DSM version/build, patch
   set, target file, and result.
4. Compare the proposed patch file with the current family file byte-for-byte
   and compare its target-file context. Identical patch bytes alone are not
   enough if the new vendor target no longer accepts the hunk.
5. Select the narrowest valid action:

   | Result | Required change |
   | --- | --- |
   | Existing patch dry-runs everywhere in its claimed new range | Extend that family name and directory range, then point every matching platform config to it. |
   | Existing patch works only for a subset | Keep its current range; create a new family for the verified subset. |
   | Patch differs by platform | Add a `platform/<platform>/` patch and a narrowly named platform set. |
   | Patch does not apply or its behavior is uncertain | Do not enable it; retain vendor behavior and record the evidence. |

6. Preserve set ordering. In particular, a new linuxrc exception belongs after
   the base linuxrc set it depends on, and a platform exception belongs exactly
   where its source patch previously appeared.

7. Build at least one loader from every changed family and inspect the
   resulting ramdisk. A static-patch failure is fatal by design; do not hide it
   with a permissive fallback.

## DSM 7.4.2 decision points

Start DSM 7.4.2 with these existing candidates, but do not select any of them
until the dry-run matrix confirms them:

```text
root-password-7.2.0-7.4.1
linuxrc-7.2.1-7.4.1
init-post-family-f-7.3.2-7.4.1
global-common-etc-rc
global-disable-disabled-ports
```

The fresh-install wait workaround is deliberately separate:

```text
linuxrc-fresh-install-skip-disk-ready-wait-90080-plus
config/_common/ramdisk/linuxrc/7.4.1/
  ramdisk-006-skip-fresh-install-disk-ready-wait.patch
```

For DSM 7.4.2, verify both the `CheckAllDiskReady()` function signature and
the exact main call site before selecting `ramdisk-006`. Never enable it just
because the DSM build number is later than 90080. A changed signature requires
a new, separately reviewed linuxrc exception set.

## Required validation before merge

```sh
jq empty config/_common/ramdisk/patch-sets.json
find config -path '*/config.json' -print0 | xargs -0 -n1 jq empty
bash -n build-loader.sh build-loader_t.sh include/patch.sh
```

Also verify that every expanded set path exists, each configuration contains no
duplicate patch path, and the resolved order matches the intended release
plan. Keep any release-specific comparison record beside the change; the
current migration baseline is
`docs/ramdisk-patch-baseline.json`.

## Update checklist

- [ ] Add platform release configs under `config/<platform>/`.
- [ ] Store PAT metadata and source provenance through the normal release
      intake path.
- [ ] Run and record the original-ramdisk dry-run matrix.
- [ ] Extend an existing set only with evidence; otherwise add a narrowly
      scoped family or platform set.
- [ ] Update `patch-sets.json`, affected `config.json` files, and this runbook
      if the release introduces a new decision rule.
- [ ] Build and inspect representative loaders before publishing.
