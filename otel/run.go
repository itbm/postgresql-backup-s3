package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"go.opentelemetry.io/contrib/propagators/envcar"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
	"go.opentelemetry.io/otel/log"
	"go.opentelemetry.io/otel/metric"
	"go.opentelemetry.io/otel/propagation"
	semconv "go.opentelemetry.io/otel/semconv/v1.43.0"
	"go.opentelemetry.io/otel/trace"

	"github.com/itbm/postgresql-backup-s3/internal/gocron"
)

// childEnvRemoved are never passed to the command: it makes no network calls,
// so it has no use for the OTLP headers, which often hold API keys.
var childEnvRemoved = map[string]bool{
	"OTEL_EXPORTER_OTLP_HEADERS":         true,
	"OTEL_EXPORTER_OTLP_TRACES_HEADERS":  true,
	"OTEL_EXPORTER_OTLP_METRICS_HEADERS": true,
	"OTEL_EXPORTER_OTLP_LOGS_HEADERS":    true,
	"OTEL_EXPORTER_OTLP_HEADERS_FILE":    true,
	gocron.TelemetryFileEnv:              true,
}

// traceContextEnv is replaced by the run's own trace context.
var traceContextEnv = map[string]bool{"TRACEPARENT": true, "TRACESTATE": true, "BAGGAGE": true}

// run is one run of the command.
type run struct {
	t       *telemetry
	op      string
	start   time.Time
	ctx     context.Context // carries the root span
	span    trace.Span
	secrets *redactor
	dir     string // the private directory holding the run report
	report  string // the run report's path, or ""
	endOnce sync.Once
}

// StartRun starts the run's root span and creates its report file.
func (t *telemetry) StartRun(info gocron.RunInfo) gocron.Run {
	r := &run{t: t, op: info.Operation(), start: time.Now(), secrets: newRedactor()}
	t.secrets.Store(r.secrets)

	attrs := []attribute.KeyValue{
		attrOperation.String(r.op),
		attrTrigger.String(string(info.Trigger)),
	}
	if info.Schedule != "" {
		attrs = append(attrs, attrSchedule.String(info.Schedule))
	}
	attrs = append(attrs, t.dbAttrs...)
	if t.target.bucket != "" {
		attrs = append(attrs, semconv.AWSS3Bucket(t.target.bucket))
	}
	if t.target.region != "" {
		attrs = append(attrs, semconv.CloudRegion(t.target.region))
	}
	r.ctx, r.span = t.tracer.Start(context.Background(), r.op,
		trace.WithNewRoot(),
		trace.WithSpanKind(trace.SpanKindInternal),
		trace.WithTimestamp(r.start),
		trace.WithAttributes(attrs...),
		trace.WithLinks(t.links...))

	if t.tracesOn || t.metricsOn {
		var err error
		if r.dir, r.report, err = createReport(); err != nil {
			t.warn(fmt.Sprintf("cannot create the run report: %v", err))
		}
	}
	t.inst.active.Add(r.ctx, 1, t.opAttrs(r.op))
	t.current.Store(r)
	return r
}

// createReport creates an empty report file, readable only by go-cron's
// user, in a new private directory.
func createReport() (dir, path string, err error) {
	dir, err = os.MkdirTemp("", "go-cron-")
	if err != nil {
		return "", "", err
	}
	path = filepath.Join(dir, "report")
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		_ = os.RemoveAll(dir)
		return "", "", err
	}
	if err := f.Close(); err != nil {
		_ = os.RemoveAll(dir)
		return "", "", err
	}
	return dir, path, nil
}

// Env returns the command's environment: base without the OTLP headers,
// with the run's trace context and the report file.
func (r *run) Env(base []string) []string {
	env := make([]string, 0, len(base)+3)
	for _, kv := range base {
		k, _, _ := strings.Cut(kv, "=")
		if childEnvRemoved[k] || (r.t.tracesOn && traceContextEnv[k]) {
			continue
		}
		env = append(env, kv)
	}
	if r.t.tracesOn {
		propagation.TraceContext{}.Inject(r.ctx, &envcar.Carrier{
			SetEnvFunc: func(key, value string) { env = append(env, key+"="+value) },
		})
	}
	if r.report != "" {
		env = append(env, gocron.TelemetryFileEnv+"="+r.report)
	}
	return env
}

// WantsOutput reports whether command output becomes log records.
func (r *run) WantsOutput() bool { return r.t.logger != nil }

// Line emits a line of command output as a log record.
func (r *run) Line(stream, line string) {
	if r.t.logger == nil {
		return
	}
	iostream := semconv.LogIostreamStdout
	if stream == "stderr" {
		iostream = semconv.LogIostreamStderr
	}
	// The scripts print progress on stderr, so both streams are INFO.
	r.t.emit(r.ctx, log.SeverityInfo, "INFO", cleanText(r.secrets.apply(line), true), iostream)
}

// TraceID returns the root span's trace ID when the trace is exported.
func (r *run) TraceID() string {
	if sc := r.span.SpanContext(); sc.IsSampled() {
		return sc.TraceID().String()
	}
	return ""
}

// End records the run's phases, metrics and outcome, and ends its root span.
// It reads the report and does not wait for any export.
func (r *run) End(res gocron.Result) {
	r.endOnce.Do(func() { r.end(res) })
}

func (r *run) end(res gocron.Result) {
	t := r.t
	defer t.current.CompareAndSwap(r, nil)

	ended := res.Ended
	if ended.IsZero() {
		ended = time.Now()
	}
	if ended.Before(r.start) {
		ended = r.start
	}

	rep := &report{}
	if r.report != "" {
		got, err := readReport(r.report)
		if err != nil {
			t.warn(fmt.Sprintf("cannot read the run report: %v", err))
		} else {
			rep = got
		}
		_ = os.RemoveAll(r.dir)
	}
	rep.clamp(r.start, ended)

	r.recordPhases(rep)

	outcome := string(res.Outcome)
	errType := errorType(res)
	attrs := []attribute.KeyValue{
		attrOutcome.String(outcome),
		semconv.ProcessExitCode(res.ExitCode),
	}
	if errType != "" {
		attrs = append(attrs, semconv.ErrorTypeKey.String(errType))
	}
	if rep.failedPhase != "" {
		attrs = append(attrs, attrFailedPhase.String(rep.failedPhase))
	}
	attrs = append(attrs, rep.rootAttributes()...)
	r.span.SetAttributes(attrs...)
	if res.Outcome != gocron.OutcomeSuccess {
		desc := outcome
		if res.Err != nil {
			desc = sanitise(r.secrets.apply(res.Err.Error()))
		}
		r.span.SetStatus(codes.Error, desc)
	}
	r.span.End(trace.WithTimestamp(ended))

	ctx, inst := r.ctx, t.inst
	started := res.Started
	if started.IsZero() {
		started = r.start
	}
	if errType != "" {
		inst.runs.Add(ctx, 1, t.opAttrs(r.op, attrOutcome.String(outcome), semconv.ErrorTypeKey.String(errType)))
	} else {
		inst.runs.Add(ctx, 1, t.opAttrs(r.op, attrOutcome.String(outcome)))
	}
	inst.runDuration.Record(ctx, ended.Sub(started).Seconds(), t.opAttrs(r.op, attrOutcome.String(outcome)))
	if res.Outcome == gocron.OutcomeSuccess {
		inst.lastSuccess.Record(ctx, unixSeconds(ended), t.opAttrs(r.op))
	} else {
		inst.lastFailure.Record(ctx, unixSeconds(ended), t.opAttrs(r.op))
	}
	ns := metric.WithAttributes(t.nsAttrs...)
	if rep.sizeBytes != nil {
		inst.backupSize.Record(ctx, *rep.sizeBytes, ns)
	}
	if rep.retentionDeleted != nil {
		inst.retentionDeleted.Record(ctx, *rep.retentionDeleted, ns)
	}
	if rep.retentionKept != nil {
		inst.retentionKept.Record(ctx, *rep.retentionKept, ns)
	}
	inst.active.Add(ctx, -1, t.opAttrs(r.op))
}

// recordPhases creates a child span and records a duration for each phase.
func (r *run) recordPhases(rep *report) {
	t := r.t
	for _, p := range rep.phases {
		attrs := []attribute.KeyValue{attrPhase.String(p.name)}
		switch p.name {
		case "dump", "verify", "restore", "drop", "create":
			attrs = append(attrs, t.dbAttrs...)
		case "upload", "download":
			if t.target.bucket != "" {
				attrs = append(attrs, semconv.AWSS3Bucket(t.target.bucket))
			}
			if rep.s3Key != "" {
				attrs = append(attrs, semconv.AWSS3Key(rep.s3Key))
			}
		}
		if p.ended && p.status != 0 {
			attrs = append(attrs, attrPhaseStatus.Int(p.status))
		}
		_, span := t.tracer.Start(r.ctx, p.name,
			trace.WithSpanKind(trace.SpanKindInternal),
			trace.WithTimestamp(p.start),
			trace.WithAttributes(attrs...))
		if p.outcome() != "success" {
			span.SetStatus(codes.Error, p.statusText())
		}
		span.End(trace.WithTimestamp(p.end))

		name := p.name
		if !knownPhases[name] {
			name = "other"
		}
		t.inst.phaseDuration.Record(r.ctx, p.end.Sub(p.start).Seconds(),
			t.opAttrs(r.op, attrPhase.String(name), attrPhaseOutcome.String(p.outcome())))
	}
}

// rootAttributes are the root span attributes from the report.
func (rep *report) rootAttributes() []attribute.KeyValue {
	var attrs []attribute.KeyValue
	if rep.sizeBytes != nil {
		attrs = append(attrs, attrBackupSize.Int64(*rep.sizeBytes))
	}
	if rep.s3Key != "" {
		attrs = append(attrs, semconv.AWSS3Key(rep.s3Key))
	}
	if rep.retentionDeleted != nil {
		attrs = append(attrs, attrRetentionDel.Int64(*rep.retentionDeleted))
	}
	if rep.retentionKept != nil {
		attrs = append(attrs, attrRetentionKept.Int64(*rep.retentionKept))
	}
	if rep.dumpFormat != "" {
		attrs = append(attrs, attrDumpFormat.String(rep.dumpFormat))
	}
	if rep.compression != "" {
		attrs = append(attrs, attrCompression.String(rep.compression))
	}
	if rep.encrypted != nil {
		attrs = append(attrs, attrEncrypted.Bool(*rep.encrypted))
	}
	if rep.ignored > 0 {
		attrs = append(attrs, attrIgnoredLines.Int(rep.ignored))
	}
	return attrs
}

// errorType is the error.type of a run that did not succeed, or "".
func errorType(res gocron.Result) string {
	switch res.Outcome {
	case gocron.OutcomeSuccess:
		return ""
	case gocron.OutcomeTimeout:
		return "timeout"
	case gocron.OutcomeCancelled:
		return "cancelled"
	}
	var exitErr *exec.ExitError
	switch {
	case res.Err != nil && !errors.As(res.Err, &exitErr):
		return "start_error"
	case res.ExitCode > 128:
		return "signal"
	}
	return "exit_status"
}
