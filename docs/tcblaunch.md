# `tcblaunch.exe` — what it is, and the "newer Windows broke it" problem

`tcblaunch.exe` is **Microsoft's** DRTM / Secure-Launch payload, shipped inside Windows (`C:\Windows\System32\tcblaunch.exe`). [slbounce](https://github.com/TravMurav/slbounce) abuses the secure-launch path that loads it to drop Linux at **EL2** (so KVM works). It is **Microsoft proprietary** — like the Qualcomm blobs, it is **not** in this repo and may not be redistributed. You extract it from a Windows install you own.

## The catch: slbounce only bounces a *specific* build

slbounce depends on the exact internal layout of `tcblaunch.exe`. **Microsoft changed it in newer Windows builds**, so the `tcblaunch.exe` on a freshly-updated machine often **won't bounce** — the boot just fails or falls back. The known-good build for this platform is pinned in `config/install.env`:

```
TCBLAUNCH_VERSION="26100.6584"
```

`scripts/03-setup-el2-boot.sh` does a best-effort `strings` check and **warns** if the `tcblaunch.exe` you supplied doesn't look like that build. (It only warns — it can't hard-verify, and it never auto-downloads it.)

## Getting the exact build — Windows 11 24H2, build `26100.6584` (ARM64)

You need `tcblaunch.exe` from **Windows 11 24H2, build `26100.6584`, ARM64**. The base 24H2 ISO Microsoft hands out is an *earlier* build, so the reliable way to get exactly `26100.6584` is **[uupdump.net](https://uupdump.net)**:

1. On uupdump.net search **`26100.6584`** and pick the **arm64** Retail / "Cumulative Update" result.
2. Download the pack and run its `uup_download_linux.sh` (or the Windows `.cmd`) — it builds a `Win11_24H2_…_arm64.iso` with that exact build baked in.

Other sources if your build already matches: your existing Windows (`winver` == `26100.6584`), or the **ASUS A14 factory recovery** `install.wim`.

## Extract it (no Windows install needed)

Point `config/install.env` at the ISO:

```ini
TCBLAUNCH_ISO="/path/to/Win11_24H2_26100.6584_arm64.iso"
```

Then let `install.sh` handle it, or run the helper directly:

```bash
sudo ./scripts/extract-tcblaunch.sh /path/to/Win11_24H2_26100.6584_arm64.iso
```

It loop-mounts the ISO, `wimextract`s `/Windows/System32/tcblaunch.exe` (needs `wimtools`/`wimlib`), **verifies the build is `26100.6584`** (warns loudly otherwise), and drops it on the ESP root where slbounce reads it. You're extracting from media you got from Microsoft — that's fine; redistributing the binary from a repo is not.

## If your Windows is too new

If you've already updated past a working build and don't want to roll back: keep a copy of a known-good `tcblaunch.exe` **for your own use** (the extractor will reuse whatever is already on the ESP). Don't commit it to the repo. The slbounce community tracks which builds work — start there if 26100.6584 ever stops being available.
