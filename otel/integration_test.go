package main

import (
	"bytes"
	"encoding/hex"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	collogspb "go.opentelemetry.io/proto/otlp/collector/logs/v1"
	colmetricpb "go.opentelemetry.io/proto/otlp/collector/metrics/v1"
	coltracepb "go.opentelemetry.io/proto/otlp/collector/trace/v1"
	commonpb "go.opentelemetry.io/proto/otlp/common/v1"
	logspb "go.opentelemetry.io/proto/otlp/logs/v1"
	metricpb "go.opentelemetry.io/proto/otlp/metrics/v1"
	tracepb "go.opentelemetry.io/proto/otlp/trace/v1"
	"google.golang.org/protobuf/proto"

	"github.com/itbm/postgresql-backup-s3/internal/gocron"
)

// receiver is an in-process OTLP/HTTP receiver.
type receiver struct {
	srv *httptest.Server

	mu       sync.Mutex
	requests int
	apiKeys  []string
	traces   []*coltracepb.ExportTraceServiceRequest
	metrics  []*colmetricpb.ExportMetricsServiceRequest
	logs     []*collogspb.ExportLogsServiceRequest
}

func newReceiver(t *testing.T) *receiver {
	rc := &receiver{}
	rc.srv = httptest.NewServer(http.HandlerFunc(rc.handle))
	t.Cleanup(rc.srv.Close)
	return rc
}

func (rc *receiver) handle(w http.ResponseWriter, req *http.Request) {
	body, err := io.ReadAll(req.Body)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	var msg, resp proto.Message
	switch req.URL.Path {
	case "/v1/traces":
		msg, resp = &coltracepb.ExportTraceServiceRequest{}, &coltracepb.ExportTraceServiceResponse{}
	case "/v1/metrics":
		msg, resp = &colmetricpb.ExportMetricsServiceRequest{}, &colmetricpb.ExportMetricsServiceResponse{}
	case "/v1/logs":
		msg, resp = &collogspb.ExportLogsServiceRequest{}, &collogspb.ExportLogsServiceResponse{}
	default:
		http.NotFound(w, req)
		return
	}
	if err := proto.Unmarshal(body, msg); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	rc.mu.Lock()
	rc.requests++
	rc.apiKeys = append(rc.apiKeys, req.Header.Get("X-Api-Key"))
	switch m := msg.(type) {
	case *coltracepb.ExportTraceServiceRequest:
		rc.traces = append(rc.traces, m)
	case *colmetricpb.ExportMetricsServiceRequest:
		rc.metrics = append(rc.metrics, m)
	case *collogspb.ExportLogsServiceRequest:
		rc.logs = append(rc.logs, m)
	}
	rc.mu.Unlock()
	out, _ := proto.Marshal(resp)
	w.Header().Set("Content-Type", "application/x-protobuf")
	_, _ = w.Write(out)
}

func (rc *receiver) spans() []*tracepb.Span {
	rc.mu.Lock()
	defer rc.mu.Unlock()
	var spans []*tracepb.Span
	for _, req := range rc.traces {
		for _, rs := range req.ResourceSpans {
			for _, ss := range rs.ScopeSpans {
				spans = append(spans, ss.Spans...)
			}
		}
	}
	return spans
}

// metric returns the last exported data of the named metric.
func (rc *receiver) metric(name string) *metricpb.Metric {
	rc.mu.Lock()
	defer rc.mu.Unlock()
	var found *metricpb.Metric
	for _, req := range rc.metrics {
		for _, rm := range req.ResourceMetrics {
			for _, sm := range rm.ScopeMetrics {
				for _, m := range sm.Metrics {
					if m.Name == name {
						found = m
					}
				}
			}
		}
	}
	return found
}

func (rc *receiver) logRecords() []*logspb.LogRecord {
	rc.mu.Lock()
	defer rc.mu.Unlock()
	var recs []*logspb.LogRecord
	for _, req := range rc.logs {
		for _, rl := range req.ResourceLogs {
			for _, sl := range rl.ScopeLogs {
				recs = append(recs, sl.LogRecords...)
			}
		}
	}
	return recs
}

func (rc *receiver) count() int {
	rc.mu.Lock()
	defer rc.mu.Unlock()
	return rc.requests
}

// attrs flattens OTLP attributes to strings.
func attrs(kvs []*commonpb.KeyValue) map[string]string {
	m := map[string]string{}
	for _, kv := range kvs {
		switch v := kv.Value.Value.(type) {
		case *commonpb.AnyValue_StringValue:
			m[kv.Key] = v.StringValue
		case *commonpb.AnyValue_IntValue:
			m[kv.Key] = fmt.Sprint(v.IntValue)
		case *commonpb.AnyValue_BoolValue:
			m[kv.Key] = fmt.Sprint(v.BoolValue)
		case *commonpb.AnyValue_DoubleValue:
			m[kv.Key] = fmt.Sprint(v.DoubleValue)
		default:
			m[kv.Key] = kv.Value.String()
		}
	}
	return m
}

// wantAttrs checks that got has the wanted values; a wanted value of "-"
// means the key must be absent.
func wantAttrs(t *testing.T, what string, got map[string]string, want map[string]string) {
	t.Helper()
	for k, v := range want {
		g, ok := got[k]
		switch {
		case v == "-" && ok:
			t.Errorf("%s: unexpected %s=%q", what, k, g)
		case v != "-" && g != v:
			t.Errorf("%s: %s=%q, want %q", what, k, g, v)
		}
	}
}

// reportScript is a stub backup.sh that writes report records the way
// common.sh does and prints to both streams.
const reportScript = `
f=$PGBACKUP_TELEMETRY_FILE
rec() { if [ -n "$f" ] && [ -f "$f" ] && [ ! -h "$f" ]; then printf '%s\n' "$*" >> "$f"; fi; }
ts() { t=$(date +%s%N); case $t in *[!0-9]*) t=$(date +%s)000000000 ;; esac; printf '%s' "$t"; }
env > "$ENV_OUT"
`

func writeScript(t *testing.T, name, body string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), name)
	if err := os.WriteFile(path, []byte(reportScript+body), 0o644); err != nil {
		t.Fatal(err)
	}
	return path
}

// integrationEnv sets up the environment of a backup container sending to
// endpoint.
func integrationEnv(t *testing.T, endpoint string) string {
	t.Helper()
	clearEnv(t)
	envOut := filepath.Join(t.TempDir(), "env")
	setEnv(t, map[string]string{
		"OTEL_EXPORTER_OTLP_ENDPOINT": endpoint,
		"OTEL_EXPORTER_OTLP_HEADERS":  "x-api-key=hdr-secret-value",
		"OTEL_METRIC_EXPORT_INTERVAL": "600000", // export only at shutdown
		"OTEL_RESOURCE_ATTRIBUTES":    "deployment.environment.name=test",
		"POSTGRES_HOST":               "db.example",
		"POSTGRES_PORT":               "5433",
		"POSTGRES_DATABASE":           "appdb",
		"POSTGRES_PASSWORD":           "s3cr3t-db-password",
		"S3_BUCKET":                   "my-bucket",
		"S3_PREFIX":                   "/backups/daily/",
		"S3_REGION":                   "eu-west-2",
		"ENV_OUT":                     envOut,
	})
	return envOut
}

func readEnvFile(t *testing.T, path string) map[string]string {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return envMap(strings.Split(strings.TrimSpace(string(data)), "\n"))
}

func traceHex(b []byte) string { return hex.EncodeToString(b) }

func TestIntegrationSuccess(t *testing.T) {
	rc := newReceiver(t)
	envOut := integrationEnv(t, rc.srv.URL)
	t.Setenv("OTEL_LOGS_EXPORTER", "otlp")
	t.Setenv("TRACEPARENT", "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01")
	script := writeScript(t, "backup.sh", `
rec "begin dump $(ts)"
echo "dumping appdb with password s3cr3t-db-password"
echo "progress 50%" >&2
rec "end dump $(ts) 0"
rec "set dump.format plain"
rec "set compression gzip"
rec "begin verify $(ts)"
rec "end verify $(ts) 0"
rec "set encrypted no"
rec "set s3.key backups/daily/appdb_2026-10-20T02:00:00Z.sql.gz"
rec "begin upload $(ts)"
rec "end upload $(ts) 0"
rec "set backup.size_bytes 12345"
rec "begin custom-step $(ts)"
rec "end custom-step $(ts) 0"
rec "set retention.deleted 2"
rec "set retention.kept 5"
rec "set unknown.key value"
rec "not a record"
printf 'no trailing newline'
exit 0
`)

	if code := gocron.Main([]string{"--once", "/bin/sh", script}, newTelemetry); code != 0 {
		t.Fatalf("exit code %d, want 0", code)
	}

	// Traces.
	spans := rc.spans()
	var root *tracepb.Span
	phases := map[string]*tracepb.Span{}
	for _, s := range spans {
		if len(s.ParentSpanId) == 0 {
			root = s
		} else {
			phases[s.Name] = s
		}
	}
	if root == nil || len(spans) != 5 {
		t.Fatalf("got %d spans, root %v", len(spans), root)
	}
	traceID, rootID := traceHex(root.TraceId), traceHex(root.SpanId)
	if root.Name != "backup" || root.Kind != tracepb.Span_SPAN_KIND_INTERNAL || root.Status.GetCode() != tracepb.Status_STATUS_CODE_UNSET {
		t.Errorf("root span %q kind %v status %v", root.Name, root.Kind, root.Status)
	}
	wantAttrs(t, "root", attrs(root.Attributes), map[string]string{
		"pgbackup.operation":            "backup",
		"pgbackup.trigger":              "once",
		"pgbackup.schedule":             "-",
		"db.system.name":                "postgresql",
		"db.namespace":                  "appdb",
		"server.address":                "db.example",
		"server.port":                   "5433",
		"aws.s3.bucket":                 "my-bucket",
		"cloud.region":                  "eu-west-2",
		"pgbackup.outcome":              "success",
		"process.exit.code":             "0",
		"error.type":                    "-",
		"pgbackup.failed_phase":         "-",
		"pgbackup.backup.size":          "12345",
		"aws.s3.key":                    "backups/daily/appdb_2026-10-20T02:00:00Z.sql.gz",
		"pgbackup.retention.deleted":    "2",
		"pgbackup.retention.kept":       "5",
		"pgbackup.dump.format":          "plain",
		"pgbackup.compression":          "gzip",
		"pgbackup.encrypted":            "false",
		"pgbackup.report.ignored_lines": "2",
	})
	if len(root.Links) != 1 || traceHex(root.Links[0].TraceId) != "0af7651916cd43dd8448eb211c80319c" || traceID == "0af7651916cd43dd8448eb211c80319c" {
		t.Errorf("root links %v; the inbound TRACEPARENT must be a link, not the parent", root.Links)
	}
	if len(root.Events) != 0 {
		t.Errorf("root span has events: %v", root.Events)
	}
	for _, name := range []string{"dump", "verify", "upload", "custom-step"} {
		p := phases[name]
		if p == nil {
			t.Errorf("no %s span", name)
			continue
		}
		if traceHex(p.TraceId) != traceID || traceHex(p.ParentSpanId) != rootID || p.Kind != tracepb.Span_SPAN_KIND_INTERNAL {
			t.Errorf("%s span is not an internal child of the root", name)
		}
		if p.StartTimeUnixNano < root.StartTimeUnixNano || p.EndTimeUnixNano > root.EndTimeUnixNano || p.EndTimeUnixNano < p.StartTimeUnixNano {
			t.Errorf("%s span %d-%d outside root %d-%d", name, p.StartTimeUnixNano, p.EndTimeUnixNano, root.StartTimeUnixNano, root.EndTimeUnixNano)
		}
		if p.Status.GetCode() != tracepb.Status_STATUS_CODE_UNSET || attrs(p.Attributes)["pgbackup.phase"] != name {
			t.Errorf("%s span status %v attributes %v", name, p.Status, attrs(p.Attributes))
		}
	}
	wantAttrs(t, "dump", attrs(phases["dump"].Attributes), map[string]string{
		"db.system.name": "postgresql", "db.namespace": "appdb", "server.address": "db.example", "server.port": "5433", "aws.s3.bucket": "-",
	})
	wantAttrs(t, "upload", attrs(phases["upload"].Attributes), map[string]string{
		"aws.s3.bucket": "my-bucket", "aws.s3.key": "backups/daily/appdb_2026-10-20T02:00:00Z.sql.gz", "db.namespace": "-",
	})
	wantAttrs(t, "custom-step", attrs(phases["custom-step"].Attributes), map[string]string{"db.namespace": "-", "aws.s3.bucket": "-"})

	// Resource and scope.
	rc.mu.Lock()
	rs := rc.traces[0].ResourceSpans[0]
	rc.mu.Unlock()
	wantAttrs(t, "resource", attrs(rs.Resource.Attributes), map[string]string{
		"service.name":                "postgresql-backup-s3",
		"service.version":             "dev",
		"service.instance.id":         "0ce51144-5233-5e4f-b515-16abac112d27",
		"deployment.environment.name": "test",
		"telemetry.sdk.language":      "go",
		"host.name":                   "-",
		"process.pid":                 "-",
	})
	if s := rs.ScopeSpans[0].Scope; s.Name != scopeName || s.Version != "dev" {
		t.Errorf("scope %q %q", s.Name, s.Version)
	}

	// Metrics.
	type point struct {
		attrs map[string]string
		value float64
	}
	points := func(name string) []point {
		m := rc.metric(name)
		if m == nil {
			t.Errorf("no %s metric", name)
			return nil
		}
		var ps []point
		switch d := m.Data.(type) {
		case *metricpb.Metric_Gauge:
			for _, dp := range d.Gauge.DataPoints {
				ps = append(ps, point{attrs(dp.Attributes), dp.GetAsDouble() + float64(dp.GetAsInt())})
			}
		case *metricpb.Metric_Sum:
			for _, dp := range d.Sum.DataPoints {
				ps = append(ps, point{attrs(dp.Attributes), dp.GetAsDouble() + float64(dp.GetAsInt())})
			}
		case *metricpb.Metric_Histogram:
			for _, dp := range d.Histogram.DataPoints {
				ps = append(ps, point{attrs(dp.Attributes), float64(dp.Count)})
			}
		}
		return ps
	}
	one := func(name string, wantUnit string, want map[string]string) float64 {
		t.Helper()
		if m := rc.metric(name); m != nil && m.Unit != wantUnit {
			t.Errorf("%s unit %q, want %q", name, m.Unit, wantUnit)
		}
		ps := points(name)
		if len(ps) != 1 {
			t.Errorf("%s has %d data points, want 1", name, len(ps))
			return 0
		}
		if len(ps[0].attrs) != len(want) {
			t.Errorf("%s attributes %v, want %v", name, ps[0].attrs, want)
		}
		wantAttrs(t, name, ps[0].attrs, want)
		return ps[0].value
	}
	opNS := map[string]string{"pgbackup.operation": "backup", "db.namespace": "appdb"}
	ns := map[string]string{"db.namespace": "appdb"}
	if v := one("pgbackup.runs", "{run}", map[string]string{"pgbackup.operation": "backup", "pgbackup.outcome": "success", "db.namespace": "appdb"}); v != 1 {
		t.Errorf("pgbackup.runs = %v", v)
	}
	if v := one("pgbackup.run.duration", "s", map[string]string{"pgbackup.operation": "backup", "pgbackup.outcome": "success", "db.namespace": "appdb"}); v != 1 {
		t.Errorf("pgbackup.run.duration count = %v", v)
	}
	if v := one("pgbackup.last_success.timestamp", "s", opNS); v < float64(time.Now().Add(-time.Minute).Unix()) || v > float64(time.Now().Unix()+1) {
		t.Errorf("pgbackup.last_success.timestamp = %v", v)
	}
	if v := one("pgbackup.backup.size", "By", ns); v != 12345 {
		t.Errorf("pgbackup.backup.size = %v", v)
	}
	if v := one("pgbackup.retention.deleted", "{object}", ns); v != 2 {
		t.Errorf("pgbackup.retention.deleted = %v", v)
	}
	if v := one("pgbackup.retention.kept", "{object}", ns); v != 5 {
		t.Errorf("pgbackup.retention.kept = %v", v)
	}
	if v := one("pgbackup.run.active", "{run}", opNS); v != 0 {
		t.Errorf("pgbackup.run.active = %v", v)
	}
	if rc.metric("pgbackup.last_failure.timestamp") != nil || rc.metric("pgbackup.skipped_runs") != nil || rc.metric("pgbackup.schedule.next_run.timestamp") != nil {
		t.Error("unexpected metrics for a successful --once run")
	}
	var phaseNames []string
	for _, p := range points("pgbackup.phase.duration") {
		if p.attrs["pgbackup.phase.outcome"] != "success" || p.attrs["pgbackup.operation"] != "backup" || p.attrs["db.namespace"] != "appdb" || p.value != 1 {
			t.Errorf("phase duration point %v", p)
		}
		phaseNames = append(phaseNames, p.attrs["pgbackup.phase"])
	}
	if strings.Join(sortedCopy(phaseNames), ",") != "dump,other,upload,verify" {
		t.Errorf("phase duration phases %v", phaseNames)
	}
	if m := rc.metric("pgbackup.run.duration"); m != nil {
		dp := m.GetHistogram().DataPoints[0]
		if len(dp.ExplicitBounds) != len(durationBuckets) || dp.ExplicitBounds[len(dp.ExplicitBounds)-1] != 86400 {
			t.Errorf("run.duration bounds %v", dp.ExplicitBounds)
		}
		if len(dp.Exemplars) == 0 || traceHex(dp.Exemplars[0].TraceId) != traceID {
			t.Errorf("run.duration exemplars %v do not link to trace %s", dp.Exemplars, traceID)
		}
	}

	// Logs.
	var lines []string
	for _, r := range rc.logRecords() {
		a := attrs(r.Attributes)
		lines = append(lines, a["log.iostream"]+"|"+r.SeverityText+"|"+r.Body.GetStringValue())
		if traceHex(r.TraceId) != traceID || traceHex(r.SpanId) != rootID {
			t.Errorf("log %q not correlated with the root span", r.Body.GetStringValue())
		}
		if r.TimeUnixNano == 0 {
			t.Errorf("log %q has no timestamp", r.Body.GetStringValue())
		}
		if strings.Contains(r.Body.GetStringValue(), "s3cr3t-db-password") {
			t.Errorf("log %q leaks the password", r.Body.GetStringValue())
		}
	}
	want := []string{
		"stdout|INFO|dumping appdb with password [REDACTED]",
		"stderr|INFO|progress 50%",
		"stdout|INFO|no trailing newline",
		"|INFO|Command finished with exit code 0 (trace_id=" + traceID + ")",
	}
	if strings.Join(sortedCopy(lines), "\n") != strings.Join(sortedCopy(want), "\n") {
		t.Errorf("log records:\n%s\nwant:\n%s", strings.Join(lines, "\n"), strings.Join(want, "\n"))
	}

	// Headers reach the receiver but not the command.
	rc.mu.Lock()
	for _, k := range rc.apiKeys {
		if k != "hdr-secret-value" {
			t.Errorf("request with X-Api-Key %q", k)
		}
	}
	rc.mu.Unlock()
	env := readEnvFile(t, envOut)
	if _, ok := env["OTEL_EXPORTER_OTLP_HEADERS"]; ok {
		t.Error("the command saw OTEL_EXPORTER_OTLP_HEADERS")
	}
	if env["TRACEPARENT"] != "00-"+traceID+"-"+rootID+"-01" {
		t.Errorf("TRACEPARENT = %q", env["TRACEPARENT"])
	}
	report := env["PGBACKUP_TELEMETRY_FILE"]
	if report == "" {
		t.Fatal("the command did not get PGBACKUP_TELEMETRY_FILE")
	}
	if _, err := os.Stat(filepath.Dir(report)); !os.IsNotExist(err) {
		t.Errorf("report directory left behind: %v", err)
	}
}

func sortedCopy(s []string) []string {
	c := append([]string(nil), s...)
	for i := range c {
		for j := i + 1; j < len(c); j++ {
			if c[j] < c[i] {
				c[i], c[j] = c[j], c[i]
			}
		}
	}
	return c
}

func TestIntegrationFailure(t *testing.T) {
	rc := newReceiver(t)
	integrationEnv(t, rc.srv.URL)
	t.Setenv("POSTGRES_DATABASE", "all")
	t.Setenv("POSTGRES_PORT", "5432")
	t.Setenv("S3_ENDPOINT", "https://minio.example:9000")
	script := writeScript(t, "backup.sh", `
rec "begin dump $(ts)"
rec "end dump $(ts) 0"
rec "begin verify $(ts)"
rec "end verify $(ts) 2"
rec "begin upload $(ts)"
echo "upload failed" >&2
exit 3
`)
	if code := gocron.Main([]string{"--once", "/bin/sh", script}, newTelemetry); code != 3 {
		t.Fatalf("exit code %d, want 3", code)
	}

	phases := map[string]*tracepb.Span{}
	var root *tracepb.Span
	for _, s := range rc.spans() {
		if len(s.ParentSpanId) == 0 {
			root = s
		} else {
			phases[s.Name] = s
		}
	}
	if root == nil || len(phases) != 3 {
		t.Fatalf("root %v, phases %v", root, phases)
	}
	if root.Status.GetCode() != tracepb.Status_STATUS_CODE_ERROR || root.Status.Message != "exit status 3" {
		t.Errorf("root status %v", root.Status)
	}
	wantAttrs(t, "root", attrs(root.Attributes), map[string]string{
		"pgbackup.outcome":              "failure",
		"process.exit.code":             "3",
		"error.type":                    "exit_status",
		"pgbackup.failed_phase":         "verify",
		"db.namespace":                  "-",
		"server.port":                   "-",
		"cloud.region":                  "-",
		"pgbackup.backup.size":          "-",
		"pgbackup.report.ignored_lines": "-",
	})
	if s := phases["verify"]; s.Status.GetCode() != tracepb.Status_STATUS_CODE_ERROR || s.Status.Message != "exit status 2" || attrs(s.Attributes)["pgbackup.phase.status"] != "2" {
		t.Errorf("verify span status %v attributes %v", s.Status, attrs(s.Attributes))
	}
	if s := phases["upload"]; s.Status.GetCode() != tracepb.Status_STATUS_CODE_ERROR || s.Status.Message != "phase did not complete" || s.EndTimeUnixNano != root.EndTimeUnixNano {
		t.Errorf("upload span status %v, end %d, root end %d", s.Status, s.EndTimeUnixNano, root.EndTimeUnixNano)
	}
	if s := phases["dump"]; s.Status.GetCode() != tracepb.Status_STATUS_CODE_UNSET {
		t.Errorf("dump span status %v", s.Status)
	}

	runs := rc.metric("pgbackup.runs").GetSum().DataPoints
	if len(runs) != 1 || runs[0].GetAsInt() != 1 {
		t.Fatalf("pgbackup.runs %v", runs)
	}
	wantAttrs(t, "pgbackup.runs", attrs(runs[0].Attributes), map[string]string{
		"pgbackup.operation": "backup", "pgbackup.outcome": "failure", "error.type": "exit_status", "db.namespace": "-",
	})
	if rc.metric("pgbackup.last_failure.timestamp") == nil || rc.metric("pgbackup.last_success.timestamp") != nil || rc.metric("pgbackup.backup.size") != nil {
		t.Error("wrong timestamp or size gauges for a failed run")
	}
	outcomes := map[string]string{}
	for _, dp := range rc.metric("pgbackup.phase.duration").GetHistogram().DataPoints {
		a := attrs(dp.Attributes)
		outcomes[a["pgbackup.phase"]] = a["pgbackup.phase.outcome"]
	}
	if fmt.Sprint(outcomes) != "map[dump:success upload:incomplete verify:failure]" {
		t.Errorf("phase outcomes %v", outcomes)
	}
	if len(rc.logRecords()) != 0 {
		t.Error("log records exported without OTEL_LOGS_EXPORTER=otlp")
	}
}

// captureStderr returns what fn writes to os.Stderr.
func captureStderr(t *testing.T, fn func()) string {
	t.Helper()
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	old := os.Stderr
	t.Cleanup(func() { os.Stderr = old })
	os.Stderr = w
	done := make(chan string)
	go func() {
		var buf bytes.Buffer
		_, _ = io.Copy(&buf, r)
		r.Close()
		done <- buf.String()
	}()
	fn()
	os.Stderr = old
	w.Close()
	return <-done
}

func TestIntegrationStalledCollector(t *testing.T) {
	release := make(chan struct{})
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		select {
		case <-release:
		case <-req.Context().Done():
		}
	}))
	t.Cleanup(srv.Close)
	t.Cleanup(func() { close(release) })
	integrationEnv(t, srv.URL)
	t.Setenv("OTEL_LOGS_EXPORTER", "otlp")
	t.Setenv("TELEMETRY_SHUTDOWN_TIMEOUT", "500ms")
	script := writeScript(t, "backup.sh", `rec "begin dump $(ts)"; echo working; exit 0`)

	var code int
	start := time.Now()
	out := captureStderr(t, func() {
		code = gocron.Main([]string{"--once", "/bin/sh", script}, newTelemetry)
	})
	if elapsed := time.Since(start); elapsed > 3*time.Second {
		t.Errorf("go-cron took %v with a stalled collector", elapsed)
	}
	if code != 0 {
		t.Errorf("exit code %d, want 0", code)
	}
	if !strings.Contains(out, "WARN: telemetry: ") {
		t.Errorf("no telemetry warning on stderr:\n%s", out)
	}
}

func TestIntegrationClosedPort(t *testing.T) {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	endpoint := "http://" + l.Addr().String()
	l.Close()
	integrationEnv(t, endpoint)
	t.Setenv("OTEL_LOGS_EXPORTER", "otlp")
	t.Setenv("TELEMETRY_SHUTDOWN_TIMEOUT", "1s")
	script := writeScript(t, "backup.sh", "echo working\nexit 5\n")

	var code int
	start := time.Now()
	out := captureStderr(t, func() {
		code = gocron.Main([]string{"--once", "/bin/sh", script}, newTelemetry)
	})
	elapsed := time.Since(start)
	if code != 5 {
		t.Errorf("exit code %d, want 5", code)
	}
	if elapsed > 4*time.Second {
		t.Errorf("go-cron took %v with an unreachable collector", elapsed)
	}
	if !strings.Contains(out, "INFO: Command finished with exit code 5 (trace_id=") || !strings.Contains(out, "WARN: telemetry: ") {
		t.Errorf("stderr:\n%s", out)
	}
	if strings.Contains(out, "hdr-secret-value") {
		t.Errorf("stderr leaks a header value:\n%s", out)
	}
}

func TestIntegrationDisabled(t *testing.T) {
	cases := map[string]map[string]string{
		"no endpoint":  {"OTEL_EXPORTER_OTLP_ENDPOINT": ""},
		"SDK disabled": {"OTEL_SDK_DISABLED": "true", "OTEL_LOGS_EXPORTER": "otlp"},
		"all exporters none": {
			"OTEL_TRACES_EXPORTER": "none", "OTEL_METRICS_EXPORTER": "none", "OTEL_LOGS_EXPORTER": "none",
		},
	}
	for name, env := range cases {
		t.Run(name, func(t *testing.T) {
			rc := newReceiver(t)
			envOut := integrationEnv(t, rc.srv.URL)
			t.Setenv("PGBACKUP_TELEMETRY_FILE", "/tmp/inherited-report")
			setEnv(t, env)
			script := writeScript(t, "backup.sh", `rec "begin dump $(ts)"; echo hello; exit 4`)
			var code int
			out := captureStderr(t, func() {
				code = gocron.Main([]string{"--once", "/bin/sh", script}, newTelemetry)
			})
			if code != 4 {
				t.Errorf("exit code %d, want 4", code)
			}
			if rc.count() != 0 {
				t.Errorf("receiver got %d requests", rc.count())
			}
			got := readEnvFile(t, envOut)
			for _, k := range []string{"PGBACKUP_TELEMETRY_FILE", "TRACEPARENT", "TRACESTATE"} {
				if v, ok := got[k]; ok {
					t.Errorf("the command saw %s=%q", k, v)
				}
			}
			// Exactly as without OpenTelemetry: --once prints nothing of its own.
			if out != "" {
				t.Errorf("go-cron printed %q", out)
			}
		})
	}
}

func TestIntegrationScheduled(t *testing.T) {
	rc := newReceiver(t)
	integrationEnv(t, rc.srv.URL)
	t.Setenv("OTEL_LOGS_EXPORTER", "otlp")
	var printed []string
	var mu sync.Mutex
	tel, ok := newTelemetry(func(sev, msg string) {
		mu.Lock()
		printed = append(printed, sev+" "+msg)
		mu.Unlock()
	}).(*telemetry)
	if !ok {
		t.Fatal("telemetry is disabled")
	}

	info := gocron.RunInfo{Command: "/bin/sh", Args: []string{"/restore.sh"}, Trigger: gocron.TriggerSchedule, Schedule: "@daily"}
	next := time.Date(2026, 10, 21, 0, 0, 0, 0, time.UTC)
	tel.Scheduled(info, func() time.Time { return next })
	tel.Log("INFO", "Cron job scheduled: @daily")
	r := tel.StartRun(info)
	tel.Log("WARN", "Previous command still running; skipping this run")
	tel.Skipped(info)
	r.Line("stdout", "restoring")
	now := time.Now()
	r.End(gocron.Result{Outcome: gocron.OutcomeTimeout, ExitCode: 143, Err: fmt.Errorf("command timed out after 1h0m0s: signal: terminated"), Started: now, Ended: now})
	tel.Log("ERROR", "Command finished with error: boom")
	tel.Shutdown()
	tel.Shutdown() // idempotent

	spans := rc.spans()
	if len(spans) != 1 {
		t.Fatalf("got %d spans", len(spans))
	}
	root := spans[0]
	wantAttrs(t, "root", attrs(root.Attributes), map[string]string{
		"pgbackup.operation": "restore", "pgbackup.trigger": "schedule", "pgbackup.schedule": "@daily",
		"pgbackup.outcome": "timeout", "error.type": "timeout", "process.exit.code": "143",
	})
	if root.Status.Message != "command timed out after 1h0m0s: signal: terminated" {
		t.Errorf("root status %v", root.Status)
	}

	if dps := rc.metric("pgbackup.skipped_runs").GetSum().GetDataPoints(); len(dps) != 1 || dps[0].GetAsInt() != 1 {
		t.Errorf("pgbackup.skipped_runs %v", dps)
	}
	if dps := rc.metric("pgbackup.schedule.next_run.timestamp").GetGauge().GetDataPoints(); len(dps) != 1 || dps[0].GetAsDouble() != float64(next.Unix()) {
		t.Errorf("pgbackup.schedule.next_run.timestamp %v", dps)
	} else {
		wantAttrs(t, "next_run", attrs(dps[0].Attributes), map[string]string{"pgbackup.operation": "restore", "db.namespace": "appdb"})
	}
	if dps := rc.metric("pgbackup.runs").GetSum().GetDataPoints(); len(dps) != 1 || attrs(dps[0].Attributes)["error.type"] != "timeout" {
		t.Errorf("pgbackup.runs %v", dps)
	}

	traceID := traceHex(root.TraceId)
	got := map[string]string{}
	for _, rec := range rc.logRecords() {
		correlated := traceHex(rec.TraceId) == traceID
		got[rec.Body.GetStringValue()] = fmt.Sprintf("%s/%d/%v", rec.SeverityText, rec.SeverityNumber, correlated)
	}
	want := map[string]string{
		"Cron job scheduled: @daily":                        "INFO/9/false",
		"Previous command still running; skipping this run": "WARN/13/true",
		"restoring":                         "INFO/9/true",
		"Command finished with error: boom": "ERROR/17/false",
	}
	if fmt.Sprint(got) != fmt.Sprint(want) {
		t.Errorf("log records %v, want %v", got, want)
	}
	mu.Lock()
	defer mu.Unlock()
	if len(printed) != 0 {
		t.Errorf("telemetry printed %q", printed)
	}
}
