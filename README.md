# LoFi FX plugin installer

`install.sh` installs the latest macOS release of the five LoFi FX OFX plugins into DaVinci Resolve's standard OFX directory:

```sh
./install.sh
```

The script uses only tools included with modern macOS: Bash, `curl`, `unzip`, `shasum`, `ditto`, `xattr`, and `sudo`. It downloads and verifies all five release archives before changing the install directory, removes the `com.apple.quarantine` attribute from each bundle, and resets Resolve's cached OFX plugin list. Quit DaVinci Resolve before running it and launch Resolve again afterward.

The default system install may prompt for an administrator password. To install in the current user's Library instead:

```sh
./install.sh --user
```

Use `./install.sh --dry-run` to download and verify release assets without installing them. The installer stops if any requested repository has no accessible macOS release asset.
