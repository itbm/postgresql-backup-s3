package main

import (
	"context"
	"fmt"
	"os"
	"sync"
	"sync/atomic"
	"time"

	"github.com/go-logr/logr"
	"go.opentelemetry.io/contrib/propagators/envcar"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/exporters/otlp/otlplog/otlploghttp"
	"go.opentelemetry.io/otel/exporters/otlp/otlpmetric/otlpmetrichttp"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp"
	"go.opentelemetry.io/otel/log"
	"go.opentelemetry.io/otel/metric"
	metricnoop "go.opentelemetry.io/otel/metric/noop"
	"go.opentelemetry.io/otel/propagation"
	sdklog "go.opentelemetry.io/otel/sdk/log"
	sdkmetric "go.opentelemetry.io/otel/sdk/metric"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	semconv "go.opentelemetry.io/otel/semconv/v1.43.0"
	"go.opentelemetry.io/otel/trace"
	tracenoop "go.opentelemetry.io/otel/trace/noop"

	"github.com/itbm/postgresql-backup-s3/internal/gocron"
)

const (
	scopeName          = "github.com/itbm/postgresql-backup-s3/go-cron"
	defaultServiceName = "postgresql-backup-s3"
	// shutdownGrace is how long Shutdown waits beyond the timeout for an
	// exporter that ignores its context.
	shutdownGrace = 500 * time.Millisecond
)

var (
	attrOperation     = attribute.Key("pgbackup.operation")
	attrTrigger       = attribute.Key("pgbackup.trigger")
	attrSchedule      = attribute.Key("pgbackup.schedule")
	attrOutcome       = attribute.Key("pgbackup.outcome")
	attrFailedPhase   = attribute.Key("pgbackup.failed_phase")
	attrPhase         = attribute.Key("pgbackup.phase")
	attrPhaseStatus   = attribute.Key("pgbackup.phase.status")
	attrPhaseOutcome  = attribute.Key("pgbackup.phase.outcome")
	attrIgnoredLines  = attribute.Key("pgbackup.report.ignored_lines")
	attrBackupSize    = attribute.Key("pgbackup.backup.size")
	attrRetentionDel  = attribute.Key("pgbackup.retention.deleted")
	attrRetentionKept = attribute.Key("pgbackup.retention.kept")
	attrDumpFormat    = attribute.Key("pgbackup.dump.format")
	attrCompression   = attribute.Key("pgbackup.compression")
	attrEncrypted     = attribute.Key("pgbackup.encrypted")

	// durationBuckets cover runs and phases of seconds to a day; the SDK's
	// default boundaries stop at 10 seconds.
	durationBuckets = []float64{0.1, 0.5, 1, 5, 10, 30, 60, 120, 300, 600, 1200, 1800, 3600, 7200, 14400, 28800, 86400}
)

type instruments struct {
	lastSuccess      metric.Float64Gauge
	lastFailure      metric.Float64Gauge
	backupSize       metric.Int64Gauge
	retentionDeleted metric.Int64Gauge
	retentionKept    metric.Int64Gauge
	active           metric.Int64UpDownCounter
	runs             metric.Int64Counter
	skipped          metric.Int64Counter
	runDuration      metric.Float64Histogram
	phaseDuration    metric.Float64Histogram
}

// telemetry implements gocron.Telemetry with explicit OpenTelemetry
// providers. Disabled signals use no-op implementations.
type telemetry struct {
	cfg    config
	target target
	msgs   *messages

	tracesOn, metricsOn bool
	tracer              trace.Tracer
	logger              log.Logger // nil unless logs are enabled
	inst                instruments
	links               []trace.Link // the inbound TRACEPARENT, if any

	dbAttrs  []attribute.KeyValue // db.* and server.* span attributes
	nsAttrs  []attribute.KeyValue // db.namespace as a metric attribute
	shutdown []namedShutdown

	secrets  atomic.Pointer[redactor] // the latest run's secrets
	current  atomic.Pointer[run]      // the active run, for log correlation
	schedule atomic.Pointer[scheduleState]

	shutdownOnce sync.Once
}

type namedShutdown struct {
	signal string
	fn     func(context.Context) error
}

type scheduleState struct {
	attrs attribute.Set
	next  func() time.Time
}

// newTelemetry is passed to gocron.Main. It returns gocron.NoTelemetry when
// no signal is enabled, so go-cron then behaves as without OpenTelemetry: no
// temporary files and no network. The OTLP headers are still kept from the
// command, which never needs them.
func newTelemetry(print gocron.Printer) gocron.Telemetry {
	if t := setup(context.Background(), print); t != nil {
		return t
	}
	for k := range childEnvRemoved {
		os.Unsetenv(k)
	}
	return gocron.NoTelemetry{}
}

// setup returns nil when no signal is enabled.
func setup(ctx context.Context, print gocron.Printer) *telemetry {
	t := &telemetry{msgs: &messages{print: print}}
	t.msgs.secret = t.secrets.Load
	t.cfg = loadConfig(t.warn)
	if !t.cfg.enabled() {
		return nil
	}
	t.secrets.Store(newRedactor())
	t.target = loadTarget()

	// Route the SDK's errors and warnings through go-cron's output instead of
	// the default standard error logger.
	otel.SetErrorHandler(otel.ErrorHandlerFunc(t.msgs.handleError))
	otel.SetLogger(logr.New(&logSink{m: t.msgs}))

	res, err := newResource(ctx, t.target)
	if err != nil {
		t.warn(fmt.Sprintf("resource: %v", err)) // a partial resource is still usable
	}

	t.tracer = tracenoop.NewTracerProvider().Tracer(scopeName)
	meter := metricnoop.NewMeterProvider().Meter(scopeName)

	if ep := t.cfg.tracesEndpoint; ep != "" {
		if exp, err := otlptracehttp.New(ctx, otlptracehttp.WithEndpointURL(ep)); err != nil {
			t.warn(fmt.Sprintf("traces disabled: %v", err))
		} else {
			tp := sdktrace.NewTracerProvider(sdktrace.WithResource(res), sdktrace.WithBatcher(exp))
			t.tracer = tp.Tracer(scopeName, trace.WithInstrumentationVersion(version), trace.WithSchemaURL(semconv.SchemaURL))
			t.tracesOn = true
			t.shutdown = append(t.shutdown, namedShutdown{"traces", tp.Shutdown})
		}
	}
	if ep := t.cfg.metricsEndpoint; ep != "" {
		if exp, err := otlpmetrichttp.New(ctx, otlpmetrichttp.WithEndpointURL(ep)); err != nil {
			t.warn(fmt.Sprintf("metrics disabled: %v", err))
		} else {
			mp := sdkmetric.NewMeterProvider(sdkmetric.WithResource(res), sdkmetric.WithReader(sdkmetric.NewPeriodicReader(exp)))
			meter = mp.Meter(scopeName, metric.WithInstrumentationVersion(version), metric.WithSchemaURL(semconv.SchemaURL))
			t.metricsOn = true
			t.shutdown = append(t.shutdown, namedShutdown{"metrics", mp.Shutdown})
		}
	}
	if ep := t.cfg.logsEndpoint; ep != "" {
		if exp, err := otlploghttp.New(ctx, otlploghttp.WithEndpointURL(ep)); err != nil {
			t.warn(fmt.Sprintf("logs disabled: %v", err))
		} else {
			lp := sdklog.NewLoggerProvider(sdklog.WithResource(res), sdklog.WithProcessor(sdklog.NewBatchProcessor(exp)))
			t.logger = lp.Logger(scopeName, log.WithInstrumentationVersion(version), log.WithSchemaURL(semconv.SchemaURL))
			t.shutdown = append(t.shutdown, namedShutdown{"logs", lp.Shutdown})
		}
	}
	if len(t.shutdown) == 0 {
		return nil
	}

	t.inst = newInstruments(meter, t.observeNextRun)
	t.dbAttrs = dbAttributes(t.target)
	if ns := t.target.namespace(); ns != "" {
		t.nsAttrs = []attribute.KeyValue{semconv.DBNamespace(ns)}
	}
	if t.tracesOn {
		// A trace context inherited from whatever started go-cron becomes a
		// link, never the parent: it may be stale or never exported.
		inbound := trace.SpanContextFromContext(propagation.TraceContext{}.Extract(ctx, &envcar.Carrier{}))
		if inbound.IsValid() {
			t.links = []trace.Link{{SpanContext: inbound}}
		}
	}
	return t
}

func newResource(ctx context.Context, tg target) (*resource.Resource, error) {
	return resource.New(ctx,
		resource.WithSchemaURL(semconv.SchemaURL),
		resource.WithAttributes(
			semconv.ServiceName(defaultServiceName),
			semconv.ServiceVersion(version),
			semconv.ServiceInstanceID(tg.instanceID()),
		),
		resource.WithTelemetrySDK(),
		// Last, so OTEL_RESOURCE_ATTRIBUTES and OTEL_SERVICE_NAME override.
		resource.WithFromEnv(),
	)
}

// dbAttributes are the database span attributes.
func dbAttributes(tg target) []attribute.KeyValue {
	attrs := []attribute.KeyValue{semconv.DBSystemNamePostgreSQL}
	if ns := tg.namespace(); ns != "" {
		attrs = append(attrs, semconv.DBNamespace(ns))
	}
	if tg.host != "" {
		attrs = append(attrs, semconv.ServerAddress(tg.host))
	}
	if port := tg.portNumber(); port != 0 {
		attrs = append(attrs, semconv.ServerPort(port))
	}
	return attrs
}

func newInstruments(m metric.Meter, observeNextRun metric.Float64Callback) instruments {
	var i instruments
	// Creating an instrument fails only for an invalid name, and then still
	// returns a usable instrument, so the errors are ignored.
	i.lastSuccess, _ = m.Float64Gauge("pgbackup.last_success.timestamp",
		metric.WithUnit("s"),
		metric.WithDescription("Unix time at which the last successful run finished."))
	i.lastFailure, _ = m.Float64Gauge("pgbackup.last_failure.timestamp",
		metric.WithUnit("s"),
		metric.WithDescription("Unix time at which the last failed, timed out or cancelled run finished."))
	i.backupSize, _ = m.Int64Gauge("pgbackup.backup.size",
		metric.WithUnit("By"),
		metric.WithDescription("Size of the last uploaded backup."))
	i.retentionDeleted, _ = m.Int64Gauge("pgbackup.retention.deleted",
		metric.WithUnit("{object}"),
		metric.WithDescription("Backups deleted by the last retention pass."))
	i.retentionKept, _ = m.Int64Gauge("pgbackup.retention.kept",
		metric.WithUnit("{object}"),
		metric.WithDescription("Backups kept by the last retention pass."))
	i.active, _ = m.Int64UpDownCounter("pgbackup.run.active",
		metric.WithUnit("{run}"),
		metric.WithDescription("Runs in progress."))
	_, _ = m.Float64ObservableGauge("pgbackup.schedule.next_run.timestamp",
		metric.WithUnit("s"),
		metric.WithDescription("Unix time of the next scheduled run."),
		metric.WithFloat64Callback(observeNextRun))
	i.runs, _ = m.Int64Counter("pgbackup.runs",
		metric.WithUnit("{run}"),
		metric.WithDescription("Finished runs."))
	i.skipped, _ = m.Int64Counter("pgbackup.skipped_runs",
		metric.WithUnit("{run}"),
		metric.WithDescription("Scheduled runs skipped because the previous run was still in progress."))
	i.runDuration, _ = m.Float64Histogram("pgbackup.run.duration",
		metric.WithUnit("s"),
		metric.WithDescription("Duration of runs."),
		metric.WithExplicitBucketBoundaries(durationBuckets...))
	i.phaseDuration, _ = m.Float64Histogram("pgbackup.phase.duration",
		metric.WithUnit("s"),
		metric.WithDescription("Duration of the phases the scripts report."),
		metric.WithExplicitBucketBoundaries(durationBuckets...))
	return i
}

// warn prints one of telemetry's own warnings.
func (t *telemetry) warn(msg string) { t.msgs.warn(msg) }

// opAttrs are the metric attributes of an operation.
func (t *telemetry) opAttrs(op string, extra ...attribute.KeyValue) metric.MeasurementOption {
	attrs := make([]attribute.KeyValue, 0, 1+len(t.nsAttrs)+len(extra))
	attrs = append(attrs, attrOperation.String(op))
	attrs = append(attrs, extra...)
	attrs = append(attrs, t.nsAttrs...)
	return metric.WithAttributes(attrs...)
}

// Log emits go-cron's own messages as log records, correlated with the
// active run.
func (t *telemetry) Log(severity, message string) {
	if t.logger == nil {
		return
	}
	ctx, secrets := context.Background(), t.secrets.Load()
	if r := t.current.Load(); r != nil {
		ctx, secrets = r.ctx, r.secrets
	}
	sev := log.SeverityInfo
	switch severity {
	case "WARN":
		sev = log.SeverityWarn
	case "ERROR":
		sev = log.SeverityError
	default:
		severity = "INFO"
	}
	t.emit(ctx, sev, severity, logBody(cleanText(secrets.apply(message), true)))
}

func (t *telemetry) emit(ctx context.Context, sev log.Severity, text, body string, attrs ...attribute.KeyValue) {
	var rec log.Record
	now := time.Now()
	rec.SetTimestamp(now)
	rec.SetObservedTimestamp(now)
	rec.SetSeverity(sev)
	rec.SetSeverityText(text)
	rec.SetBody(attribute.StringValue(body))
	rec.AddAttributes(attrs...)
	t.logger.Emit(ctx, rec)
}

// Scheduled starts reporting the next scheduled run time.
func (t *telemetry) Scheduled(info gocron.RunInfo, next func() time.Time) {
	attrs := append([]attribute.KeyValue{attrOperation.String(info.Operation())}, t.nsAttrs...)
	t.schedule.Store(&scheduleState{attrs: attribute.NewSet(attrs...), next: next})
}

func (t *telemetry) observeNextRun(_ context.Context, o metric.Float64Observer) error {
	s := t.schedule.Load()
	if s == nil {
		return nil
	}
	if next := s.next(); !next.IsZero() {
		o.Observe(unixSeconds(next), metric.WithAttributeSet(s.attrs))
	}
	return nil
}

// Skipped counts a scheduled run skipped because of an overlap.
func (t *telemetry) Skipped(info gocron.RunInfo) {
	t.inst.skipped.Add(context.Background(), 1, t.opAttrs(info.Operation()))
}

// Shutdown flushes and stops the providers concurrently. It returns within
// the shutdown timeout plus shutdownGrace, even if an exporter ignores its
// context.
func (t *telemetry) Shutdown() {
	t.shutdownOnce.Do(func() {
		timeout := t.cfg.shutdownTimeout
		ctx, cancel := context.WithTimeout(context.Background(), timeout)
		defer cancel()

		done := make(chan struct{})
		var wg sync.WaitGroup
		for _, s := range t.shutdown {
			wg.Go(func() {
				if err := s.fn(ctx); err != nil {
					t.warn(fmt.Sprintf("%s shutdown: %v", s.signal, err))
				}
			})
		}
		go func() {
			wg.Wait()
			close(done)
		}()

		timer := time.NewTimer(timeout + shutdownGrace)
		defer timer.Stop()
		select {
		case <-done:
		case <-timer.C:
			t.warn(fmt.Sprintf("shutdown did not finish within %s; some telemetry may be lost", timeout))
		}
	})
}

func unixSeconds(t time.Time) float64 {
	return float64(t.UnixNano()) / 1e9
}
