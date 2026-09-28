# Repository instructions

## Updating `config/pats.json`

- Collect PAT download URLs and MD5 checksums from the Synology DSM archive at `https://archive.synology.com/download/Os/DSM`. Open the directory for the exact DSM version and revision, then identify each model's `.pat` file and its corresponding `.pat.md5` file.
- Read the checksum from each model's `.pat.md5` file. Record the corresponding `.pat` download URL as `url` and the checksum as `sum` under that model and DSM version in `config/pats.json`.
- Merge newly collected entries into the existing `config/pats.json`. Preserve models and versions that were not collected in the current run; do not replace the whole file with a partial result.
- Validate the resulting JSON and verify that each new URL and MD5 pair refers to the same model, DSM version, and revision. Do not use a failed download or placeholder checksum as a valid entry.
- For the supported DSM release directories, `python3 tools/update_pats_from_archive.py 'MODEL' ...` performs this collection and merge. Use `--dry-run` to verify the result without writing it.
