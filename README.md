# arch-boxes

Arch-boxes provides several different VM images.

## Images

### QCOW2 images
At the time of writing we offer two different QCOW2 images. The images are synced to the mirrors under the `images` directory, e.g.: https://fastly.mirror.pkgbuild.com/images/.

#### Basic image
The basic image is meant for local usage and comes preconfigured with the user `arch` (password: `arch`) and sshd running.

#### Cloud image
The cloud image is meant to be used in "the cloud" and comes with [`cloud-init`](https://cloud-init.io/) preinstalled. For tested cloud providers and instructions please see the [ArchWiki's Arch Linux on a VPS page](https://wiki.archlinux.org/title/Arch_Linux_on_a_VPS#Official_Arch_Linux_cloud_image).

## Development

### Dependencies
You'll need the following dependencies:

* arch-install-scripts
* btrfs-progs
* curl
* dosfstools
* gptfdisk
* jq
* qemu-img

### How to build this
Images can be built locally by running (as root):

    ./build.sh

## CloudCone Raw Release (GitHub Actions)

This repository also includes a GitHub Actions workflow for CloudCone dd usage.
It only builds the cloud image as a GPT-partitioned raw disk and targets BIOS boot mode.

Workflow file:

`/.github/workflows/build-cloudcone-raw.yml`

How to use it:

1. Open **Actions** in GitHub.
2. Select **Build CloudCone Arch Raw**.
3. Click **Run workflow** and input `version`.
4. Optional: set `overwrite_release=true` to replace an existing release tag.
5. Wait for the workflow to finish.

Release output:

- `Arch-Linux-x86_64-cloudimg-<version>.raw`
- `Arch-Linux-x86_64-cloudimg-<version>.raw.SHA256`

The workflow creates a GitHub Release with tag `v<version>` and uploads the files above.

Known constraints and troubleshooting:

- The workflow runs on `ubuntu-latest` with a privileged Docker container. If preflight fails, retry later or run on self-hosted Linux.
- `version` maps to release tag `v<version>`. Keep it unique unless `overwrite_release=true`.
- Large raw files can fail upload. The workflow enforces a guarded size threshold and fails early with a clear message.
- If release already exists and overwrite is disabled, rerun with a new version or enable overwrite.

# Releases

Every release is signed by our CI with the following key:
```
-----BEGIN PGP PUBLIC KEY BLOCK-----

mDMEYpOJrBYJKwYBBAHaRw8BAQdAcSZilBvR58s6aD2qgsDE7WpvHQR2R5exQhNQ
yuILsTq0JWFyY2gtYm94ZXMgPGFyY2gtYm94ZXNAYXJjaGxpbnV4Lm9yZz6IkAQT
FggAOBYhBBuaFphKToy0SHEtKuC3i/QybG+PBQJik4msAhsBBQsJCAcCBhUKCQgL
AgQWAgMBAh4BAheAAAoJEOC3i/QybG+P81YA/A7HUftMGpzlJrPYBFPqW0nFIh7m
sIZ5yXxh7cTgqtJ7AQDFKSrulrsDa6hsqmEC11PWhv1VN6i9wfRvb1FwQPF6D7gz
BGKTiecWCSsGAQQB2kcPAQEHQBzLxT2+CwumKUtfi9UEXMMx/oGgpjsgp2ehYPBM
N8ejiPUEGBYIACYWIQQbmhaYSk6MtEhxLSrgt4v0MmxvjwUCYpOJ5wIbAgUJCWYB
gACBCRDgt4v0Mmxvj3YgBBkWCAAdFiEEZW5MWsHMO4blOdl+NDY1poWakXQFAmKT
iecACgkQNDY1poWakXTwaQEAwymt4PgXltHUH8GVUB6Xu7Gb5o6LwV9fNQJc1CMl
7CABAJw0We0w1q78cJ8uWiomE1MHdRxsuqbuqtsCn2Dn6/0Cj+4A/Apcqm7uzFam
pA5u9yvz1VJBWZY1PRBICBFSkuRtacUCAQC7YNurPPoWDyjiJPrf0Vzaz8UtKp0q
BSF/a3EoocLnCA==
=APeC
-----END PGP PUBLIC KEY BLOCK-----
```
