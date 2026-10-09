---
name: disk-lens
description: >-
  Open disk-lens, the captain's local browser page for what holds the disk, CPU, RAM, and firstmate's own pools, tasks, and helpers, when the captain invokes /disk-lens or asks to see or free disk space, memory, or processes.
  Also load as firstmate's disk-pressure playbook when free disk drops under about 20 GiB, a worker or bench disk guard fires, a Docker or build step fails with ENOSPC or "no space left on device", or the captain mentions disk space.
user-invocable: true
metadata:
  internal: true
---

# disk-lens

`bin/fm-disk-lens.sh` owns launch, stop, and scan mechanics; `bin/fm-disk-lens.py`'s header owns every safety rule behind the page's actions.

## Open the page

1. Run `bin/fm-disk-lens.sh` with this home's `FM_HOME`.
   It starts the local server, prints the page URL, and opens it in the browser; a second run reuses the running page.
2. Give the captain the URL and the four tabs: Disk, Firstmate, CPU, RAM.
3. The page stops on its Quit button, when this agent session ends, or after an idle hour; `bin/fm-disk-lens.sh stop` stops it from here.

Every free, trash, or kill happens only on the captain's click and in-page confirmation.
"Ask AI" is a fast model's first look and only a guess; "Hand to firstmate" arrives as an inbox note, and it is a request to investigate, never authority to delete.

## Disk-pressure playbook

1. Diagnose read-only with the page's own scanner, no browser needed.
   `bin/fm-disk-lens.sh scan --no-du --top 60` returns in seconds with free space, Docker sizes, and the inventory.
   `bin/fm-disk-lens.sh scan --tabs disk --min-mb 500` adds real sizes but runs du over the home for minutes, so run it as a background job.
2. Summarize for the captain: free and total space, the top consumers by kind (Docker images, containers, and build cache; worktrees and pool slots; repos; caches; personal files), and which large items a live task still holds.
3. Firstmate deletes nothing from this playbook.
   Propose concrete candidates with their sizes and what the page would do to each, then open the page so the captain frees them.
   A worker's own finished task still goes through ordinary task cleanup, not disk-lens.

## Standing rules (captain, 2026-10-09)

- Build Docker images right before they are used and delete them right after; keep the Dockerfiles.
  Put this in the instructions of any task that builds images, such as benches.
- Worktrees and repos are removed only through disk-lens's push-and-log path: branches pushed to GitHub without force, an entry in `data/disk-lens/backup-log.md` and the configured mirror ([`docs/configuration.md`](../../../docs/configuration.md#disk-lens-backup-log-mirror-configdisk-lens-log-repo)), then removal.
- Everything else goes to the macOS Trash, never rm.
