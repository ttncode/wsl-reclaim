# wsl-reclaim

**WSL2 ate 80 GB and won't give it back.** This gives it back, in one command.

WSL2 virtual disks only ever grow. You delete 30 GB inside the distro, `df` happily
reports the space as free, and the `.vhdx` on Windows stays exactly as large as it
was. Cleaning inside the distro and shrinking the disk on Windows are two separate
jobs, and almost every guide only covers one of them.

`wsl-reclaim` does both:

```bash
./wsl-slim.sh --compact
```

Cleans package caches, dead Docker layers and stale IDE server builds inside WSL,
then hands off to an elevated PowerShell that shuts WSL down and compacts the
`.vhdx` on the Windows side.

Roughly what a run looks like:

```
== Docker: build cache ==
Total reclaimed space: 12.4GB

== npm cache ==
== other caches ==
== stale IDE server builds (keeps newest of each) ==
== journal + apt ==

Freed inside WSL: 31G  (78G -> 47G used)

== compacting the .vhdx from Windows ==

== Ubuntu
   C:\Users\you\AppData\Local\wsl\{guid}\ext4.vhdx
   logical 81.73 GB | on disk 81.73 GB
   reclaimed 30.91 GB -> now 50.82 GB
```

## Install

```bash
git clone https://github.com/ttncode/wsl-reclaim.git
cd wsl-reclaim && chmod +x wsl-slim.sh
```

Two files, no dependencies. Keep them together — the shell script looks for the
PowerShell one beside it.

## Usage

```bash
./wsl-slim.sh                        # clean inside WSL only
./wsl-slim.sh --compact              # clean, then shrink the .vhdx  (needs UAC)
./wsl-slim.sh --drop-orphan-volumes  # also delete unused Docker volumes
```

`--compact` shuts WSL down, so your shell dies mid-run. That is expected: the
elevated Windows console keeps going and reports what it reclaimed.

The Windows half runs standalone too, if the inside-WSL cleanup isn't what you want:

```powershell
powershell -ExecutionPolicy Bypass -File compact-wsl.ps1
powershell -ExecutionPolicy Bypass -File compact-wsl.ps1 -WhatIf   # report only
powershell -ExecutionPolicy Bypass -File compact-wsl.ps1 -Path D:\some\disk.vhdx
```

## Why your last attempt at this did nothing

If you already tried `diskpart` and the disk didn't budge, it is one of these two,
and they need opposite responses.

**Your disk is sparse.** WSL 2.5.6+ can mark disks sparse, and diskpart refuses
them outright:

> Virtual hard disk files must be uncompressed and unencrypted and must not be sparse.

It fails at the `attach vdisk` step. Run interactively, that failure scrolls past
and `compact vdisk` looks like it ran. Nothing was ever going to happen — and
nothing needed to. Sparse disks return freed blocks to Windows on their own, within
seconds. What stays big is the *logical* size, which is the number Explorer shows
you. `wsl-reclaim` reports allocated size instead, so you can see the disk is
already fine.

**Your disk isn't sparse, and it was still mounted.** `compact vdisk` needs the
disk detached, which means `wsl --shutdown` first and `attach vdisk readonly`. Miss
either and diskpart reports success while reclaiming nothing. `wsl-reclaim` does
both in the right order.

Check which case you're in:

```powershell
fsutil sparse queryflag "C:\Users\you\AppData\Local\wsl\{guid}\ext4.vhdx"
```

## What it cleans inside WSL

Docker containers, images and build cache · npm, pnpm, yarn, pip, composer and Go
build caches · Playwright browsers · stale VS Code / Cursor / Windsurf / Antigravity
server builds (keeps the newest of each) · journald over 50 MB · apt archives.

Anything currently running is never touched.

## Protecting your projects

The Docker sweep removes containers and images that aren't running. To keep specific
ones regardless:

```bash
export WSL_SLIM_KEEP='^(nginx|php|mysql)-myproject$'
```

or put one extended regex per line in `~/.config/wsl-slim.keep`:

```
^postgres-clientwork$
^redis-.*$
```

`--drop-orphan-volumes` is opt-in for a reason: it deletes unused Docker volumes,
and that is where your local database data lives.

## Caveats

Compaction needs Administrator — diskpart does, there is no way around it. The
script re-launches itself elevated and you'll get a UAC prompt.

Disk discovery reads distro paths from `HKCU:\...\Lxss`. Anything not registered
there (some container runtimes keep their own disk elsewhere) won't be found
automatically; pass `-Path` to point at it directly.

Written against WSL 2.7.x with Ubuntu. Disk discovery, sparse detection and the
allocated-size reporting are verified there; the sparse branch itself is based on
documented diskpart behaviour rather than a sparse disk I've reproduced, so if you
hit a case it gets wrong, an issue with your `fsutil sparse queryflag` output is
very welcome.

## License

MIT
