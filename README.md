# Gitea stack (gitea + postgres + actions runner)

Everything is configured in **`.env`**. Nothing else to edit.

## Requirements
Linux with systemd, docker + compose plugin, `just` (`apt install just`, or https://just.systems), cron for scheduled backups.

## Quick start
```sh
cp .env.example .env
$EDITOR .env           # at least: DOMAIN, ROOT_URL, ADMIN_USER, ADMIN_EMAIL
just check             # validates, generates empty secrets/passwords into .env
just up                # optional: test run from this folder (just down to stop)
just install           # copies to INSTALL_DIR, systemd service, creates admin
just install-backup    # optional: scheduled backups (cron)
```
Admin password: whatever you set, or the generated one in `.env`.

| Recipe | |
|---|---|
| `just check` | validate config |
| `just up` / `just down` | run without installing (testing) |
| `just ps` / `just logs [svc]` | status / logs |
| `just install` | install or apply new `.env` (idempotent) |
| `just uninstall` | remove service, keep data |
| `just backup DIR` | backup now into `DIR/<timestamp>` |
| `just restore DIR` | restore that backup |
| `just install-backup` / `uninstall-backup` | scheduled backup cron |

After install, the live config is `INSTALL_DIR/.env`. Edit the one here and rerun `just install` (or work directly in `INSTALL_DIR`, the justfile is copied there too).
Service: `systemctl status|restart gitea`, `journalctl -u gitea -f`.

## Backups
Each backup = `gitea-db.dump` (pg_dump: issues, PRs, users…), `gitea-data.tar.gz` (repos, LFS, attachments, app.ini), `runner-data.tar.gz`, `dot.env`, `docker-compose.yml`, `SHA256SUMS`.
Gitea + runner stop for the duration (consistency). Scheduled ones go to `BACKUP_DIR`, keep `BACKUP_KEEP`, and refuse to run if `BACKUP_MOUNTPOINT` isn't mounted.

USB stick (ext4, auto-mounted, boots fine without it):
```sh
sudo mkfs.ext4 -L GITEABACKUP /dev/sdX1
echo 'LABEL=GITEABACKUP /mnt/backup ext4 defaults,nofail,x-systemd.device-timeout=5 0 2' | sudo tee -a /etc/fstab
sudo mkdir -p /mnt/backup && sudo mount -a
```

### Restore
`just restore /mnt/backup/gitea-backups/2026-11-01_030000`
- Secrets (`GITEA_SECRET_KEY`…) are taken from the backup and written into `.env` (old one kept as `.env.bak-*`).
- Current data is moved to `DATA_DIR/.pre-restore-*`, delete it once you're happy.
- Restoring onto a **newer** Gitea is fine (migrates), onto an older one is not.

### New machine / migration
```sh
git clone <this repo> && cd gitea-stack
cp /mnt/backup/gitea-backups/<latest>/dot.env .env   # adjust DOMAIN/paths if needed
just install
just restore /mnt/backup/gitea-backups/<latest>
```

### Migrating from your old setup
Old data isn't in this format. Easiest: on the old instance use the backup script from before (or `pg_dump -Fc` + tar of its `/data`), then lay it out as a backup dir (`gitea-db.dump`, `gitea-data.tar.gz` containing a top-level `gitea/` folder = old `/data`, `dot.env` = new .env, `SHA256SUMS`) and `just restore` it. Or simpler: install fresh and use Gitea's "New Migration" to pull repos (+issues/PRs) from the old instance while both run.
In both cases, copy `SECRET_KEY` and `INTERNAL_TOKEN` from the old `app.ini` (`[security]`) into `GITEA_SECRET_KEY` / `GITEA_INTERNAL_TOKEN` in `.env` if you restore old data, or 2FA/encrypted settings break.
