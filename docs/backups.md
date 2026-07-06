# Backups & restore

A backup nobody has restored is a wish. This page covers both
directions (SPEC §14). Every snapshot is two artifacts:

- `kammer-db-<timestamp>.dump` — the database, `pg_dump` custom format
- `kammer-uploads-<timestamp>.tar.gz` — the uploads directory (local
  storage only; with the S3 adapter your object store carries its own
  durability story and the tarball is skipped)

## Taking backups

**Scheduled (recommended):** set `BACKUP_DIR` and the instance writes
a snapshot every night at 04:15 UTC, pruning to the newest
`BACKUP_KEEP` (default 14) per artifact:

```sh
BACKUP_DIR=/backups
BACKUP_KEEP=14
BACKUP_AGE_RECIPIENT=age1...   # optional; encrypts with age
```

In Docker Compose, mount a volume at the target:

```yaml
services:
  app:
    environment:
      BACKUP_DIR: /backups
    volumes:
      - kammer_backups:/backups
```

**By hand:**

```sh
# development / anywhere Mix exists
mix kammer.backup /var/backups/kammer --keep 14

# production release / inside the container
bin/kammer eval 'Kammer.Release.backup("/backups", keep: 14)'
docker compose exec app bin/kammer eval 'Kammer.Release.backup("/backups")'
```

`--encrypt-to age1...` (or the `BACKUP_AGE_RECIPIENT` variable) pipes
both artifacts through [age](https://age-encryption.org); the `age`
binary must be on the PATH. Decrypt with `age --decrypt -i keyfile`.

Copy snapshots **off the machine** — a backup on the disk that dies
with the database is not a backup. `rsync`, `restic`, or your
provider's volume snapshots on top of `BACKUP_DIR` all work.

## Restoring

With the app **stopped** (or pointed elsewhere):

```sh
# 1. Recreate the database from the dump
createdb kammer_restored
pg_restore --clean --if-exists --no-owner \
  --dbname=kammer_restored kammer-db-20260706-041500.dump

# 2. Unpack uploads back to UPLOADS_PATH's parent
tar -xzf kammer-uploads-20260706-041500.tar.gz -C /app

# 3. Point the app at the restored database and start it
DATABASE_URL=ecto://user:pass@host/kammer_restored docker compose up -d
```

In Compose, the equivalent of step 1 inside the db container:

```sh
docker compose exec -T db createdb -U kammer kammer_restored
docker compose exec -T db pg_restore --clean --if-exists --no-owner \
  --dbname=kammer_restored -U kammer < kammer-db-<timestamp>.dump
```

**Verify a restore once before you need it.** The whole procedure on a
scratch machine takes ten minutes; discovering a broken dump during an
outage takes considerably longer.

## What's inside / GDPR note

The dump contains everything the instance stores — accounts, content,
guest identities. Treat snapshots with the same care as the live
database: encrypt them (see above) or store them where the same
people who could read the database can read them, and let retention
(`BACKUP_KEEP`) honor your privacy policy's deletion promises —
purged content lives on in old snapshots until they rotate out.
