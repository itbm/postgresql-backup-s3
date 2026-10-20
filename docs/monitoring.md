# Monitoring

This page belongs to [postgres-backup-s3](../README.md). A backup you do not watch can stop working without anyone noticing. These are the ways to monitor this image, simplest first. Each one works on its own, and you can combine them.

1. [Heartbeat hooks](#heartbeat-hooks): a ping after each successful backup. Works with both images.
2. [The result line](#result-line): one structured log line at the end of every run. Works with both images.
3. [Metrics from logs](#metrics-from-logs): an OpenTelemetry Collector turns the result line into metrics. Works with both images.
4. [OpenTelemetry image](#opentelemetry-image): traces, metrics and, if you opt in, logs, sent directly from the container.

Then add [alert rules](#alert-rules) for the metrics. On Kubernetes, see also [Kubernetes CronJob](#kubernetes-cronjob).

## Heartbeat hooks

A heartbeat service, such as Healthchecks.io, alerts you when an expected ping does not arrive. It catches a backup that failed, and also one that never ran. Set `HOOK_POST_BACKUP_URL` to the service's ping URL, and optionally `HOOK_PRE_BACKUP_URL` and `HOOK_BACKUP_ERROR_URL`. See [Lifecycle hooks](../README.md#lifecycle-hooks).

## Result line

At the end of every backup and restore, on success and on failure, `backup.sh` and `restore.sh` print one line to stderr in logfmt format:

```text
pgbackup-result operation=backup outcome=success exit_code=0 database=appdb duration_s=44.120 pre_backup_s=0.010 dump_s=38.400 verify_s=1.200 encrypt_s=2.000 upload_s=2.400 retention_s=0.110 post_backup_s=0.000 size_bytes=734003200 retention_deleted=1 retention_kept=13 file=backup/appdb_2026-10-20T02:00:00Z.sql.gz.enc
```

The line comes after the error hooks have run. It is not printed when the configuration is invalid, for example when `S3_BUCKET` is missing, because the run stops before it starts. With `SCHEDULE`, go-cron puts a timestamp and the stream in front of it, as for every line of output: `[2026-10-20 02:00:44] STDERR: pgbackup-result ...`.

The fields are always in this order:

| Field | Description |
|---|---|
| `operation` | `backup` or `restore`. |
| `outcome` | `success` for exit code 0, `cancelled` for exit code 130 or 143 (stopped by a signal), and `failure` for any other exit code. |
| `exit_code` | The script's exit code. |
| `database` | `POSTGRES_DATABASE`. |
| `duration_s` | Seconds from the start of the run, after the configuration checks, to the end. |
| `<phase>_s` | Seconds spent in each phase that ran, in order. A `-` in the phase name becomes `_`, for example `pre_backup_s`. |
| `failed_phase` | The first phase that failed, if any. |
| `size_bytes` | Size of the uploaded backup. Only after a successful upload. |
| `retention_deleted`, `retention_kept` | Backups that `DELETE_OLDER_THAN` deleted and kept. Only when it is set. |
| `file` | The S3 key, without the bucket: the uploaded object for a backup, or `BACKUP_FILE` for a restore, after `latest` is resolved. |

Durations have three decimals. The phases are:

* Backup: `pre-backup`, `dump`, `verify`, `encrypt` (with `ENCRYPTION_PASSWORD`), `upload`, `retention` (with `DELETE_OLDER_THAN`), `post-backup`, and on failure `backup-error`, which runs the error hooks.
* Restore: `resolve` (with `BACKUP_FILE=latest`), `pre-restore`, `download`, `decrypt` (for an encrypted backup), `drop` (with `DROP_DATABASE=yes`), `create` (with `CREATE_DATABASE=yes`), `restore`, `post-restore`, and on failure `restore-error`.

A value that contains a space, a double quote (`"`), an equals sign (`=`), a backslash (`\`) or a control character is put in double quotes, with `\` and `"` escaped as `\\` and `\"`, for example `database="my db"`. Line breaks are removed.

A failed upload looks like this:

```text
pgbackup-result operation=backup outcome=failure exit_code=2 database=appdb duration_s=40.050 pre_backup_s=0.010 dump_s=30.200 verify_s=1.100 upload_s=8.700 backup_error_s=0.040 failed_phase=upload file=backup/appdb_2026-10-20T02:00:00Z.sql.gz
```

## Metrics from logs

[`examples/otel-collector-logs.yaml`](../examples/otel-collector-logs.yaml) is an OpenTelemetry Collector configuration that reads the result lines from the container logs and turns them into metrics. It needs no change to the backup container, so it works with both images. It was tested with `otelcol-contrib` 0.162.0.

As written, it reads the logs of the pods in namespace `backup` whose names start with `pgbackup-`, as in the [Kubernetes CronJob](#kubernetes-cronjob) example, so run the Collector as a DaemonSet with the node's `/var/log/pods` mounted. Comments in the file explain how to read Docker's `json-file` logs instead.

The Collector trusts every line it reads: any container whose logs it reads can print a `pgbackup-result` line and create or overwrite these metrics, for example to hide a failed backup. Point it at the backup containers' logs only.

It produces these metrics, with the same names and attributes as the [OpenTelemetry image](#metrics), so the same [alert rules](#alert-rules) work with either. There are two differences: `pgbackup.runs` has no `error.type`, and a run stopped by `COMMAND_TIMEOUT` counts as `cancelled`, not `timeout`, because the script only sees the signal.

* `pgbackup.runs`
* `pgbackup.last_success.timestamp`
* `pgbackup.last_failure.timestamp`
* `pgbackup.backup.size`
* `pgbackup.retention.deleted`
* `pgbackup.retention.kept`
* `pgbackup.run.duration`

The Collector serves them on port 9464 for Prometheus to scrape. Set `honor_labels: true` in that scrape configuration, so that Prometheus keeps the `job` and `instance` labels that identify each backup target. The recipe sets `job` to `postgresql-backup-s3` and `instance` to the database name, after the Kubernetes namespace if there is one, for example `backup/appdb`. If two targets share these, change the `service.instance.id` statement in the file. A series is exported for 5 minutes after each run; the alert rules are written for metrics that come and go like this.

Counters and histograms (`pgbackup.runs` and `pgbackup.run.duration`) need care. The Collector produces them as deltas, one for each result line, and the recipe's `delta_to_cumulative` processor adds them up into totals for Prometheus. Its `max_stale` (26 hours in the file) must be longer than your schedule period. The totals live in the Collector's memory: they start again from zero when the Collector restarts, and on Kubernetes each node's Collector keeps its own. Treat them as approximate, and alert on the gauges, as the example rules do.

## OpenTelemetry image

The `-otel` image (`itbm/postgresql-backup-s3:<version>-otel`, or `latest-otel`) is the default image with a go-cron that can send each run's trace, metrics and logs over OTLP/HTTP. Nothing is sent until you set an endpoint; without one, it behaves exactly like the default image.

```sh
$ docker run ... -e OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4318 itbm/postgresql-backup-s3:<version>-otel
```

To build it yourself, run `docker build --build-arg GOCRON_VARIANT=otel .`.

To try it locally, [`examples/docker-compose.otel.yaml`](../examples/docker-compose.otel.yaml) starts PostgreSQL, MinIO, Grafana with an OpenTelemetry backend, and a backup every 5 minutes. For a Collector that receives the image's telemetry and forwards it to your backend, see [`examples/otel-collector-otlp.yaml`](../examples/otel-collector-otlp.yaml).

### OpenTelemetry environment variables

As with the other variables, an empty value or `**None**` counts as unset.

| Variable | Default | Description |
|---|---|---|
| `OTEL_EXPORTER_OTLP_ENDPOINT` | | Base URL of an OTLP/HTTP receiver, for example `http://otel-collector:4318`. go-cron adds `/v1/traces`, `/v1/metrics` or `/v1/logs`. Setting it turns on traces and metrics. |
| `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT`, `OTEL_EXPORTER_OTLP_METRICS_ENDPOINT`, `OTEL_EXPORTER_OTLP_LOGS_ENDPOINT` | | Full URL for one signal, used as it is. Takes precedence over `OTEL_EXPORTER_OTLP_ENDPOINT`. |
| `OTEL_TRACES_EXPORTER`, `OTEL_METRICS_EXPORTER` | `otlp` | Set to `none` to turn the signal off. Any other value except `otlp` prints a warning and turns it off. |
| `OTEL_LOGS_EXPORTER` | | Set to `otlp` to send logs. They stay off without it, even when an endpoint is set, because they can contain row values and SQL from restore errors. |
| `OTEL_SDK_DISABLED` | | Set to `true` to turn off all telemetry. |
| `OTEL_EXPORTER_OTLP_PROTOCOL`, `OTEL_EXPORTER_OTLP_<SIGNAL>_PROTOCOL` | `http/protobuf` | Only `http/protobuf` is supported. Any other value, such as `grpc`, prints a warning and turns the signal off. |
| `OTEL_EXPORTER_OTLP_HEADERS`, `OTEL_EXPORTER_OTLP_<SIGNAL>_HEADERS` | | Headers for the receiver, such as an API key, as `name=value` pairs separated by commas, for example `authorization=Bearer%20<token>`. Values are URL-decoded. |
| `OTEL_EXPORTER_OTLP_HEADERS_FILE` | | A file, such as a Docker or Kubernetes secret, from which to read `OTEL_EXPORTER_OTLP_HEADERS`. Trailing newlines are ignored. If `OTEL_EXPORTER_OTLP_HEADERS` is also set, go-cron prints a warning and ignores the file. |
| `OTEL_SERVICE_NAME` | `postgresql-backup-s3` | The `service.name` resource attribute. |
| `OTEL_RESOURCE_ATTRIBUTES` | | Extra resource attributes, for example `k8s.pod.name=...`. They override the defaults, including `service.instance.id`; see [Series identity](#series-identity). |
| `OTEL_METRIC_EXPORT_INTERVAL` | `60000` | With `SCHEDULE`, how often metrics are sent, in milliseconds. A one-shot run sends them when it ends. |
| `OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE` | `cumulative` | Set to `delta` only with a Collector that converts deltas; see [One-shot runs](#one-shot-runs). |
| `TELEMETRY_SHUTDOWN_TIMEOUT` | `5s` | How long go-cron waits for the last telemetry to be sent before it exits, as a Go duration. See [Stopping and grace periods](#stopping-and-grace-periods). |

The endpoint must be an `http://` or `https://` URL with a host. Otherwise go-cron prints a warning and turns that signal off; it never falls back to `localhost`. The URL's scheme decides whether TLS is used: `OTEL_EXPORTER_OTLP_INSECURE` cannot turn TLS off for an `https://` endpoint, and go-cron warns if you try.

These standard variables also work as the OpenTelemetry documentation describes: the `OTEL_EXPORTER_OTLP_*` timeout, compression, certificate, client certificate and client key settings, `OTEL_TRACES_SAMPLER` and `OTEL_TRACES_SAMPLER_ARG`, and the `OTEL_BSP_*` and `OTEL_BLRP_*` batch settings.

### Traces

Each run is one trace. Its root span is named after the operation, `backup` or `restore`, and each phase that the script reports (see [Result line](#result-line)) is a child span named after the phase, with the phase's own start and end time. A run that does not succeed has status Error with the error message, and so does a phase that fails. A phase that is still running when the script exits has status Error with the message "phase did not complete".

Root span attributes:

| Attribute | Description |
|---|---|
| `pgbackup.operation` | `backup` or `restore`. |
| `pgbackup.trigger` | `schedule`, `once` (no `SCHEDULE`, or a restore) or `start` (the run that `BACKUP_ON_START` starts). |
| `pgbackup.schedule` | `SCHEDULE`, for scheduled runs. |
| `pgbackup.outcome` | `success`, `failure`, `timeout` (`COMMAND_TIMEOUT` expired) or `cancelled` (go-cron was stopped). |
| `process.exit.code` | The script's exit code. |
| `error.type` | Only when the run did not succeed: `timeout`, `cancelled`, `signal` (exit code above 128, usually a signal), `start_error` (the script did not start) or `exit_status`. |
| `pgbackup.failed_phase` | The first phase that failed. |
| `db.system.name` | `postgresql`. |
| `db.namespace` | `POSTGRES_DATABASE`, except for `all`. |
| `server.address`, `server.port` | The database host, and its port when it is not 5432. |
| `aws.s3.bucket` | `S3_BUCKET`. |
| `aws.s3.key` | The uploaded or restored object's key. |
| `cloud.region` | `S3_REGION`, when `S3_ENDPOINT` is not set. |
| `pgbackup.backup.size` | Size of the uploaded backup, in bytes. |
| `pgbackup.retention.deleted`, `pgbackup.retention.kept` | Backups that `DELETE_OLDER_THAN` deleted and kept. |
| `pgbackup.dump.format` | `plain` or `custom`. |
| `pgbackup.compression` | The compression command, for plain-format backups. |
| `pgbackup.encrypted` | Whether the backup is encrypted. |
| `pgbackup.report.ignored_lines` | Only when go-cron ignored invalid phase records from the script. |

Phase spans have `pgbackup.phase`, and `pgbackup.phase.status` with the exit status when the phase failed. The `dump`, `verify`, `restore`, `drop` and `create` spans also have `db.system.name`, `db.namespace`, `server.address` and `server.port`, and the `upload` and `download` spans have `aws.s3.bucket` and `aws.s3.key`.

go-cron prints the trace ID when a run finishes, so you can find the trace from the logs, for example `Command finished successfully (trace_id=4bf92f3577b34da6a3ce929d0e0e4736)`. It passes the trace to the scripts and hooks as `TRACEPARENT` and `TRACESTATE`. If go-cron itself starts with `TRACEPARENT` set, for example by a CI job, each root span gets a link to that trace instead of joining it.

### Metrics

| Metric | Type | Unit | Attributes | Prometheus name |
|---|---|---|---|---|
| `pgbackup.last_success.timestamp` | Gauge | `s` | `pgbackup.operation`, `db.namespace` | `pgbackup_last_success_timestamp_seconds` |
| `pgbackup.last_failure.timestamp` | Gauge | `s` | `pgbackup.operation`, `db.namespace` | `pgbackup_last_failure_timestamp_seconds` |
| `pgbackup.backup.size` | Gauge | `By` | `db.namespace` | `pgbackup_backup_size_bytes` |
| `pgbackup.retention.deleted` | Gauge | `{object}` | `db.namespace` | `pgbackup_retention_deleted` |
| `pgbackup.retention.kept` | Gauge | `{object}` | `db.namespace` | `pgbackup_retention_kept` |
| `pgbackup.run.active` | UpDownCounter | `{run}` | `pgbackup.operation`, `db.namespace` | `pgbackup_run_active` |
| `pgbackup.schedule.next_run.timestamp` | Gauge, with `SCHEDULE` only | `s` | `pgbackup.operation`, `db.namespace` | `pgbackup_schedule_next_run_timestamp_seconds` |
| `pgbackup.runs` | Counter | `{run}` | `pgbackup.operation`, `pgbackup.outcome`, `error.type`, `db.namespace` | `pgbackup_runs_total` |
| `pgbackup.skipped_runs` | Counter | `{run}` | `pgbackup.operation`, `db.namespace` | `pgbackup_skipped_runs_total` |
| `pgbackup.run.duration` | Histogram | `s` | `pgbackup.operation`, `pgbackup.outcome`, `db.namespace` | `pgbackup_run_duration_seconds_*` |
| `pgbackup.phase.duration` | Histogram | `s` | `pgbackup.operation`, `pgbackup.phase`, `pgbackup.phase.outcome`, `db.namespace` | `pgbackup_phase_duration_seconds_*` |

* The timestamps are Unix times in seconds: when the last successful or failed run ended, and when the next scheduled run starts. A failed run is one with the outcome `failure`, `timeout` or `cancelled`.
* `pgbackup.skipped_runs` counts scheduled runs skipped because the previous run was still in progress.
* `error.type` is set only for runs that did not succeed. `db.namespace` is left out for `POSTGRES_DATABASE=all`.
* `pgbackup.phase` is one of the phase names in [Result line](#result-line), or `other`. `pgbackup.phase.outcome` is `success`, `failure` or `incomplete`.
* The histogram buckets range from 0.1 seconds to 24 hours.
* In Prometheus, the attributes become the labels `pgbackup_operation`, `pgbackup_outcome`, `pgbackup_phase`, `pgbackup_phase_outcome`, `error_type` and `db_namespace`.

Metric attributes never contain hosts, buckets, object keys or error messages, so the number of series stays small.

### Logs

With `OTEL_LOGS_EXPORTER=otlp`, each line that the backup or restore prints also becomes a log record, with the attribute `log.iostream` (`stdout` or `stderr`) and the run's trace and span IDs. All of them have severity INFO, because the scripts print progress on stderr too. go-cron's own messages are sent with severity INFO, WARN or ERROR. What the container prints does not change.

Before a line is sent, go-cron replaces these values with `[REDACTED]`, when they are at least 8 bytes long:

* The values of `POSTGRES_PASSWORD`, `PGPASSWORD`, `S3_SECRET_ACCESS_KEY`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN` and `ENCRYPTION_PASSWORD`.
* The contents of `POSTGRES_PASSWORD_FILE`, `S3_SECRET_ACCESS_KEY_FILE` and `ENCRYPTION_PASSWORD_FILE`.
* The six `HOOK_*_URL` values.
* The values in `OTEL_EXPORTER_OTLP_HEADERS` and the per-signal headers.

Only exact copies are replaced, so a secret that a tool prints in another form, such as URL-encoded, is not. Control characters other than tab are removed, and invalid UTF-8 is replaced.

A log record holds at most 8 KiB of a line; the rest is cut and the record ends with `…[truncated]`. Lines longer than 64 KiB are split into several lines first, and a secret that crosses such a split is not redacted.

### Series identity

Prometheus identifies a series by its `job` and `instance` labels, which come from the `service.name` and `service.instance.id` resource attributes. `service.name` is `postgresql-backup-s3` unless you set `OTEL_SERVICE_NAME`. By default, `service.instance.id` is a UUID derived from the backup target:

```text
postgresql://<host>:<port>/<database> s3://<bucket>/<prefix>
```

The host is `POSTGRES_HOST`, the port `POSTGRES_PORT` (default 5432), and the prefix `S3_PREFIX` without leading and trailing slashes (default `backup`). The ID stays the same across restarts, pods and upgrades, and differs between targets.

* Never set `service.instance.id` to a pod or container name. Every CronJob run would start a new series, and alerts that need history would not work.
* Put Kubernetes details, such as `k8s.pod.name`, in `OTEL_RESOURCE_ATTRIBUTES`, as in the [Kubernetes CronJob](#kubernetes-cronjob) example. They are not part of the identity, so do not promote them to labels.
* If you set `service.instance.id` yourself, give each target its own value that never changes.

### One-shot runs

Without `SCHEDULE`, and in a Kubernetes CronJob, every run is a new go-cron process that sends its metrics once, when it ends.

* Gauges, such as the last success time and the backup size, are complete. Alert on them, and read them with `max_over_time` or `last_over_time`, because each run leaves only one sample. The [alert rules](#alert-rules) do this.
* Counters and histograms start from zero in every process, so `rate` and `increase` do not see runs add up. To count runs across processes, use one of these:
  * Prometheus `--enable-feature=created-timestamp-zero-ingestion`, which needs the stable identity above. It also adds zero samples to the gauges, which is another reason to read gauges only with `max_over_time` or `last_over_time`.
  * `OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE=delta`, and the Collector's `delta_to_cumulative` processor (commented out in [`examples/otel-collector-otlp.yaml`](../examples/otel-collector-otlp.yaml)) with `max_stale` longer than the schedule period. Every run of a target must have the same resource attributes, so remove per-pod ones such as `k8s.pod.name` from the metrics first. The totals start again from zero when the Collector restarts.
* Never send delta metrics straight to Prometheus without a feature flag for delta ingestion: its OTLP receiver rejects them.

With `SCHEDULE`, go-cron keeps running and sends all metrics every `OTEL_METRIC_EXPORT_INTERVAL`, so counters and histograms work as usual.

### Stopping and grace periods

When the container is stopped, for example by `docker stop`, a Kubernetes pod deletion or `activeDeadlineSeconds`, go-cron sends SIGTERM to the running backup or restore and waits for it to exit (SIGKILL after 30 seconds). It then spends up to `TELEMETRY_SHUTDOWN_TIMEOUT` sending the remaining telemetry.

The telemetry of an interrupted run therefore arrives only if the script exits within the container's stop grace period minus `TELEMETRY_SHUTDOWN_TIMEOUT`. With the defaults, that is about 5 seconds on Docker (10-second stop timeout) and 25 seconds on Kubernetes (30 seconds). To give it more time, set `terminationGracePeriodSeconds: 45` on Kubernetes, or use `docker stop --time 45` or `stop_grace_period: 45s` in Docker Compose.

Telemetry never changes the exit code or fails a run. An unreachable receiver delays go-cron's exit by at most `TELEMETRY_SHUTDOWN_TIMEOUT`. With `SCHEDULE`, telemetry is sent in the background and never delays a run.

### Security

* Logs are off unless you set `OTEL_LOGS_EXPORTER=otlp`. Redaction catches known secrets only, and logs can still contain data from the database, such as row values in restore errors. Send them only to a backend that may hold that data.
* go-cron removes `OTEL_EXPORTER_OTLP_HEADERS`, the per-signal headers and `OTEL_EXPORTER_OTLP_HEADERS_FILE` from the environment of the backup and restore scripts and their hooks, whether or not telemetry ends up enabled. To keep a token out of the container's environment altogether, use `OTEL_EXPORTER_OTLP_HEADERS_FILE` with a secret file.
* The endpoint URL decides TLS: `https://` always uses TLS.
* Spans contain the database host, the bucket and object keys. Metrics do not.
* Spans and metrics never contain command arguments, environment variables, `POSTGRES_EXTRA_OPTS`, `POSTGRES_EXTRA_DUMP_OPTS`, hook URLs or passwords. With logs on, go-cron's own messages name the command it runs, `/bin/sh backup.sh` or `/bin/sh restore.sh`.

### Not supported

* OTLP over gRPC. The image sends OTLP/HTTP with protobuf only, usually to port 4318. If your backend accepts only gRPC, put a Collector in between.
* A Prometheus endpoint to scrape. Send the metrics to a Collector, or to Prometheus's OTLP receiver.
* Exporters other than `otlp`, such as `console` or `prometheus`.

## Alert rules

[`examples/prometheus-alerts.yaml`](../examples/prometheus-alerts.yaml) has four Prometheus alert rules. They work with the metrics of the OpenTelemetry image and with those of [Metrics from logs](#metrics-from-logs).

| Alert | Severity | Fires when |
|---|---|---|
| `PgBackupNoRecentSuccess` | critical | No backup has succeeded in the last 26 hours, or a target that reports runs has never succeeded. |
| `PgBackupLastRunFailed` | warning | The latest backup failed and none has succeeded since. |
| `PgBackupNotReporting` | warning | A target that reported backups in the last 8 days has reported none in the last 26 hours. |
| `PgBackupSizeDrop` | warning | The latest backup is less than half the size of the largest in the 2 days before it. |

The rules group by `job` and `instance`, so they need the stable [series identity](#series-identity), and they read every metric with `max_over_time` or `last_over_time`, so they also work for one-shot runs. Their unit tests are in [`examples/prometheus-alerts.test.yaml`](../examples/prometheus-alerts.test.yaml). To run them, use `promtool test rules prometheus-alerts.test.yaml` in the `examples` directory.

The windows assume a daily schedule:

* 26 hours (`26h` and `26 * 3600`) is the schedule period plus 2 hours' grace. For another schedule, use your period plus some grace.
* 8 days (`8d`) is how long a target that has stopped reporting stays known. Keep it several times longer than the period. After that, its alerts resolve, so also watch the job itself, with a heartbeat hook or with kube-state-metrics.
* `PgBackupSizeDrop` compares the latest backup with the 2 days before the last 26 hours. Change both ranges with the schedule.

If you change the rules, update the expected alerts in the tests too. For a restore drill, copy `PgBackupNoRecentSuccess`, change `pgbackup_operation="backup"` to `"restore"`, and lengthen the windows to suit its schedule, for example 8 days instead of 26 hours for a weekly drill.

## Kubernetes CronJob

[`examples/kubernetes-cronjob.yaml`](../examples/kubernetes-cronjob.yaml) runs a nightly backup of one database as a CronJob with the `-otel` image:

* `concurrencyPolicy: Forbid`, so runs never overlap, `activeDeadlineSeconds` to stop a backup that hangs, and `backoffLimit` to retry a failed one once.
* `terminationGracePeriodSeconds: 45`, so the telemetry of an interrupted run is sent.
* Passwords and keys from a Secret, with `secretKeyRef`.
* `OTEL_EXPORTER_OTLP_ENDPOINT`, and `OTEL_RESOURCE_ATTRIBUTES` with `k8s.pod.name`, `k8s.namespace.name` and `k8s.node.name` from the Downward API. `service.instance.id` keeps its default.
* `HOOK_POST_BACKUP_URL` for a heartbeat.

The second CronJob in the file is a weekly restore drill. It restores the newest backup (`BACKUP_FILE=latest`) into a scratch database server with `DROP_DATABASE=yes` and `CREATE_DATABASE=yes`, and pings its own heartbeat with `HOOK_POST_RESTORE_URL`. A backup that you have never restored is not proven. Never point the drill at a production server, because `DROP_DATABASE=yes` drops the database first.

Without the `-otel` image, kube-state-metrics already reports each CronJob's result. For example:

```yaml
- alert: PgBackupCronJobNoRecentSuccess
  expr: time() - kube_cronjob_status_last_successful_time{namespace="backup", cronjob="pgbackup-appdb"} > 26 * 3600
  labels:
    severity: critical
- alert: PgBackupCronJobFailed
  expr: |
    kube_job_status_failed{namespace="backup"} > 0
    and on (namespace, job_name)
    kube_job_owner{owner_kind="CronJob", owner_name="pgbackup-appdb"}
  labels:
    severity: warning
```

`PgBackupCronJobFailed` keeps firing until Kubernetes deletes the failed Job, which depends on `failedJobsHistoryLimit`.
