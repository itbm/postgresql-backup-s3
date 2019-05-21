# postgres-backup-s3

Backup PostgresSQL to S3 (supports periodic backups)

## Basic Usage

```sh
$ docker run -e S3_ACCESS_KEY_ID=key -e S3_SECRET_ACCESS_KEY=secret -e S3_BUCKET=my-bucket -e S3_PREFIX=backup -e POSTGRES_DATABASE=dbname -e POSTGRES_USER=user -e POSTGRES_PASSWORD=password -e POSTGRES_HOST=localhost itbm/postgres-backup-s3
```

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

- `POSTGRES_DATABASE` list of databases you want to backup (default: --all-databases)
- `POSTGRES_HOST` the postgresql host *required*
- `POSTGRES_PORT` the postgresql port (default: )
- `POSTGRES_USER` the postgresql user *required*
- `POSTGRES_PASSWORD` the postgresql password *required*
- `POSTGRES_EXTRA_OPTS` extra postgresql options
- `S3_ACCESS_KEY_ID` your AWS access key *required*
- `S3_SECRET_ACCESS_KEY` your AWS secret key *required*
- `S3_BUCKET` your AWS S3 bucket path *required*
- `S3_PREFIX` path prefix in your bucket (default: 'backup')
- `S3_REGION` the AWS S3 bucket region (default: us-west-1)
- `S3_ENDPOINT` the AWS Endpoint URL, for S3 Compliant APIs such as [minio](https://minio.io) (default: none)
- `S3_S3V4` set to `yes` to enable AWS Signature Version 4, required for [minio](https://minio.io) servers (default: no)
- `SCHEDULE` backup schedule time, see explainatons below
- `ENCRYPTION_PASSWORD` password to encrypt the backup. Can be decrypted using `openssl aes-256-cbc -d -in backup.sql.gz.enc -out backup.sql.gz`
- `DELETE_OLDER_THAN` delete old backups, see explanation and warning below

### Automatic Periodic Backups

You can additionally set the `SCHEDULE` environment variable like `-e SCHEDULE="@daily"` to run the backup automatically.

More information about the scheduling can be found [here](http://godoc.org/github.com/robfig/cron#hdr-Predefined_schedules).

### Delete Old Backups

You can additionally set the `DELETE_OLDER_THAN` environment variable like `-e DELETE_OLDER_THAN="30 days ago"` to delete old backups.

WARNING: this will delete all files in the S3_PREFIX path, not just those created by this script.

### Encryption

You can additionally set the `ENCRYPTION_PASSWORD` environment variable like `-e ENCRYPTION_PASSWORD="superstrongpassword"` to encrypt the backup. It can be decrypted using `openssl aes-256-cbc -d -in backup.sql.gz.enc -out backup.sql.gz`.