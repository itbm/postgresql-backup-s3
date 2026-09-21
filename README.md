# postgres-backup-s3

Backup and restore PostgreSQL to/from S3 (supports periodic backups and encryption).

The image is based on Alpine 3.24 and ships the PostgreSQL 18 client (`postgresql18-client`), the current stable major release. PostgreSQL 19 is not used yet because it is still in beta.

## Basic Usage

### Backup

```sh
$ docker run -e S3_ACCESS_KEY_ID=key -e S3_SECRET_ACCESS_KEY=secret -e S3_BUCKET=my-bucket -e S3_PREFIX=backup -e POSTGRES_DATABASE=dbname -e POSTGRES_USER=user -e POSTGRES_PASSWORD=password -e POSTGRES_HOST=localhost itbm/postgres-backup-s3
```

### Restore

```sh
$ docker run -e S3_ACCESS_KEY_ID=key -e S3_SECRET_ACCESS_KEY=secret -e S3_BUCKET=my-bucket -e BACKUP_FILE=backup/dbname_0000-00-00T00:00:00Z.sql.gz -e POSTGRES_DATABASE=dbname -e POSTGRES_USER=user -e POSTGRES_PASSWORD=password -e POSTGRES_HOST=localhost -e CREATE_DATABASE=yes itbm/postgres-backup-s3
```

Note: When `BACKUP_FILE` is provided, the container automatically runs the restore process instead of backup.

## Kubernetes Deployment

```
apiVersion: v1
kind: Namespace
metadata:
  name: backup

---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postgresql
  namespace: backup
spec:
  selector:
    matchLabels:
      app: postgresql
  strategy:
    type: Recreate
  template:
    metadata:
      labels:
        app: postgresql
    spec:
      containers:
      - name: postgresql
        image: itbm/postgresql-backup-s3
        imagePullPolicy: Always
        env:
        - name: POSTGRES_DATABASE
          value: ""
        - name: POSTGRES_HOST
          value: ""
        - name: POSTGRES_PORT
          value: ""
        - name: POSTGRES_PASSWORD
          value: ""
        - name: POSTGRES_USER
          value: ""
        - name: S3_ACCESS_KEY_ID
          value: ""
        - name: S3_SECRET_ACCESS_KEY
          value: ""
        - name: S3_BUCKET
          value: ""
        - name: S3_ENDPOINT
          value: ""
        - name: S3_PREFIX
          value: ""
        - name: SCHEDULE
          value: ""
```

## Environment variables

| Variable             | Default   | Required | Description                                                                                                              |
|----------------------|-----------|----------|--------------------------------------------------------------------------------------------------------------------------|
| POSTGRES_DATABASE    |           | Y        | Database you want to backup/restore or 'all' to backup/restore everything                                               |
| POSTGRES_HOST        |           | Y        | The PostgreSQL host                                                                                                      |
| POSTGRES_PORT        | 5432      |          | The PostgreSQL port                                                                                                      |
| POSTGRES_USER        |           | Y        | The PostgreSQL user                                                                                                      |
| POSTGRES_PASSWORD    |           | Y        | The PostgreSQL password                                                                                                  |
| POSTGRES_EXTRA_OPTS  |           |          | Extra options passed to all PostgreSQL client commands (`pg_dump`, `psql`, `pg_restore`, etc.)                           |
| POSTGRES_EXTRA_DUMP_OPTS |       |          | Extra options passed only to `pg_dump`/`pg_dumpall` (e.g. `--exclude-table=public.foo`)                                  |
| S3_ACCESS_KEY_ID     |           |          | AWS access key. Optional when using the default AWS credential chain (IAM role, instance profile, etc.)                  |
| S3_SECRET_ACCESS_KEY |           |          | AWS secret key. Required if `S3_ACCESS_KEY_ID` is set                                                                    |
| S3_BUCKET            |           | Y        | Your AWS S3 bucket path                                                                                                  |
| S3_PREFIX            | backup    |          | Path prefix in your bucket                                                                                               |
| S3_REGION            | us-west-1 |          | The AWS S3 bucket region                                                                                                 |
| S3_ENDPOINT          |           |          | The AWS Endpoint URL, for S3 Compliant APIs such as [minio](https://minio.io)                                            |
| S3_CA_BUNDLE         |           |          | Path to a CA file or bundle used for S3 HTTPS (sets `AWS_CA_BUNDLE`)                                                     |
| S3_SSL_VERIFY        | yes       |          | Set to `no` to disable TLS verification (`aws --no-verify-ssl`). Insecure; prefer a custom CA instead                    |
| S3_S3V4              | no        |          | Set to `yes` to enable AWS Signature Version 4, required for [minio](https://minio.io) servers                           |
| SCHEDULE             |           |          | Backup schedule time, see explainatons below                                                                             |
| COMMAND_TIMEOUT      |           |          | Max duration for a scheduled backup (`go` duration, e.g. `2h`). Empty/`0` disables the timeout (default)                 |
| ENCRYPTION_PASSWORD  |           |          | Password to encrypt/decrypt the backup                                                                                   |
| DELETE_OLDER_THAN    |           |          | Delete old backups, see explanation and warning below                                                                    |
| USE_CUSTOM_FORMAT    | no        |          | Use PostgreSQL's custom format (-Fc) instead of plain text with compression                                              |
| COMPRESSION_CMD      | gzip      |          | Command used to compress the backup (e.g. `pigz` for parallel compression) - ignored when USE_CUSTOM_FORMAT=yes          |
| DECOMPRESSION_CMD    | gunzip -c |          | Command used to decompress the backup (e.g. `pigz -dc` for parallel decompression) - ignored when USE_CUSTOM_FORMAT=yes  |
| PARALLEL_JOBS        | 1         |          | Number of parallel jobs for pg_restore when using custom format backups                                                  |
| BACKUP_FILE          |           | Y*       | Required for restore. The path to the backup file in S3, format: S3_PREFIX/filename                                      |
| CREATE_DATABASE      | no        |          | For restore: Set to `yes` to create the database if it doesn't exist                                                     |
| DROP_DATABASE        | no        |          | For restore: Set to `yes` to drop the database before restoring (caution: destroys existing data). Use with CREATE_DATABASE=yes to recreate it |

### Custom / self-signed S3 CA

AWS CLI v2 does not always use the system trust store. For S3-compatible endpoints that use a private or self-signed certificate, prefer trusting the CA rather than disabling verification.

1. **Mount extra CAs** (preferred): copy or volume-mount PEM files named `*.crt` into `/usr/local/share/ca-certificates/`. On start the container runs `update-ca-certificates` and points AWS CLI at the system bundle.

```sh
$ docker run ... -v /path/to/minio.crt:/usr/local/share/ca-certificates/minio.crt:ro itbm/postgres-backup-s3
```

Kubernetes ConfigMap example:

```yaml
volumeMounts:
  - name: s3-ca
    mountPath: /usr/local/share/ca-certificates/minio.crt
    subPath: minio.crt
    readOnly: true
volumes:
  - name: s3-ca
    configMap:
      name: s3-ca
```

2. **Bundle path**: set `S3_CA_BUNDLE` (or `AWS_CA_BUNDLE`) to a mounted CA file or bundle. `S3_CA_BUNDLE` overrides the auto system path.

```sh
$ docker run ... -v /path/to/ca.pem:/certs/ca.pem:ro -e S3_CA_BUNDLE=/certs/ca.pem itbm/postgres-backup-s3
```

3. **Last resort** (insecure): `-e S3_SSL_VERIFY=no` passes `--no-verify-ssl` to every `aws` call (backup upload, restore download, and old-backup deletion).

### Automatic Periodic Backups

You can additionally set the `SCHEDULE` environment variable like `-e SCHEDULE="@daily"` to run the backup automatically.

If a run is still in progress when the next schedule fires, the overlapping run is skipped. Optionally set `COMMAND_TIMEOUT` (for example `-e COMMAND_TIMEOUT=2h`) to limit how long a single scheduled backup may run; by default there is no timeout.

More information about the scheduling can be found [here](http://godoc.org/github.com/robfig/cron#hdr-Predefined_schedules).

### Delete Old Backups

You can additionally set the `DELETE_OLDER_THAN` environment variable like `-e DELETE_OLDER_THAN="30 days ago"` to delete old backups.

WARNING: this will delete all files in the S3_PREFIX path, not just those created by this script.

### Encryption

You can additionally set the `ENCRYPTION_PASSWORD` environment variable like `-e ENCRYPTION_PASSWORD="superstrongpassword"` to encrypt the backup. New backups use AES-256-CBC with PBKDF2 (100000 iterations). The restore process detects encrypted backups and decrypts them when `ENCRYPTION_PASSWORD` is set; legacy (pre-PBKDF2) backups are still accepted with a warning. Manual decrypt for current backups: `openssl enc -aes-256-cbc -d -pbkdf2 -iter 100000 -in backup.sql.gz.enc -out backup.sql.gz`.

### Backup Format and Compression Options

There are two options for backup format:

1. **Plain text format with compression** (default):
   - Uses plain SQL text output compressed with gzip/pigz
   - Standard and widely compatible

2. **PostgreSQL custom format**:
   - Enable with `-e USE_CUSTOM_FORMAT=yes`
   - Significantly faster than plain text format
   - Produces smaller backup files (built-in compression)
   - Supports parallel restoration for faster restores
   - Allows selective table/schema restoration
   - Recommended for larger databases

For plain text format, backups are compressed with `gzip` by default. For improved performance on multi-core systems, you can use `pigz` (parallel gzip) instead:

```sh
$ docker run ... -e COMPRESSION_CMD=pigz ... itbm/postgres-backup-s3

$ docker run ... -e DECOMPRESSION_CMD="pigz -dc" ... itbm/postgres-backup-s3
```

When using custom format with parallel restore:

```sh
$ docker run ... -e USE_CUSTOM_FORMAT=yes ... itbm/postgres-backup-s3

$ docker run ... -e PARALLEL_JOBS=4 -e BACKUP_FILE=backup/dbname_0000-00-00T00:00:00Z.dump ... itbm/postgres-backup-s3
```

Note: Custom format is not available when using `POSTGRES_DATABASE=all` as pg_dumpall does not support this format.
