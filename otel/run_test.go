package main

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/itbm/postgresql-backup-s3/internal/gocron"
)

func envMap(env []string) map[string]string {
	m := map[string]string{}
	for _, kv := range env {
		k, v, _ := strings.Cut(kv, "=")
		m[k] = v
	}
	return m
}

// newTestTelemetry sets up telemetry against an endpoint nothing listens on;
// nothing is sent before Shutdown.
func newTestTelemetry(t *testing.T, env map[string]string) *telemetry {
	t.Helper()
	clearEnv(t)
	t.Setenv("TELEMETRY_SHUTDOWN_TIMEOUT", "100ms")
	setEnv(t, env)
	tel := setup(context.Background(), func(sev, msg string) { t.Logf("%s: %s", sev, msg) })
	if tel == nil {
		t.Fatal("telemetry is disabled")
	}
	t.Cleanup(tel.Shutdown)
	return tel
}

const closedEndpoint = "http://127.0.0.1:1"

func TestNewTelemetryDisabled(t *testing.T) {
	clearEnv(t)
	if _, ok := newTelemetry(func(string, string) {}).(gocron.NoTelemetry); !ok {
		t.Error("newTelemetry without configuration is not NoTelemetry")
	}
	t.Setenv("OTEL_EXPORTER_OTLP_ENDPOINT", closedEndpoint)
	t.Setenv("OTEL_SDK_DISABLED", "true")
	if _, ok := newTelemetry(func(string, string) {}).(gocron.NoTelemetry); !ok {
		t.Error("newTelemetry with OTEL_SDK_DISABLED=true is not NoTelemetry")
	}
}

func TestRunEnv(t *testing.T) {
	base := []string{
		"PATH=/usr/bin",
		"OTEL_EXPORTER_OTLP_HEADERS=api-key=secret",
		"OTEL_EXPORTER_OTLP_TRACES_HEADERS=api-key=secret",
		"OTEL_EXPORTER_OTLP_METRICS_HEADERS=api-key=secret",
		"OTEL_EXPORTER_OTLP_LOGS_HEADERS=api-key=secret",
		"OTEL_EXPORTER_OTLP_HEADERS_FILE=/run/secrets/headers",
		"OTEL_SERVICE_NAME=backups",
		"TRACEPARENT=00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01",
		"TRACESTATE=vendor=x",
		"BAGGAGE=user=alice",
		"PGBACKUP_TELEMETRY_FILE=/tmp/inherited",
	}
	cases := []struct {
		name        string
		env         map[string]string
		traceparent bool // a new TRACEPARENT is injected
		report      bool
		output      bool
	}{
		{"traces", map[string]string{"OTEL_EXPORTER_OTLP_TRACES_ENDPOINT": closedEndpoint}, true, true, false},
		{"metrics", map[string]string{"OTEL_EXPORTER_OTLP_METRICS_ENDPOINT": closedEndpoint}, false, true, false},
		{"logs", map[string]string{"OTEL_EXPORTER_OTLP_LOGS_ENDPOINT": closedEndpoint, "OTEL_LOGS_EXPORTER": "otlp"}, false, false, true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			tel := newTestTelemetry(t, c.env)
			r := tel.StartRun(gocron.RunInfo{Command: "/bin/sh", Args: []string{"backup.sh"}, Trigger: gocron.TriggerOnce}).(*run)
			env := envMap(r.Env(base))

			for _, k := range []string{"OTEL_EXPORTER_OTLP_HEADERS", "OTEL_EXPORTER_OTLP_TRACES_HEADERS", "OTEL_EXPORTER_OTLP_METRICS_HEADERS", "OTEL_EXPORTER_OTLP_LOGS_HEADERS", "OTEL_EXPORTER_OTLP_HEADERS_FILE"} {
				if _, ok := env[k]; ok {
					t.Errorf("%s passed to the command", k)
				}
			}
			if env["PATH"] != "/usr/bin" || env["OTEL_SERVICE_NAME"] != "backups" {
				t.Errorf("ordinary variables lost: %v", env)
			}
			if c.traceparent {
				want := "00-" + r.TraceID() + "-" + r.span.SpanContext().SpanID().String() + "-01"
				if r.TraceID() == "" || env["TRACEPARENT"] != want {
					t.Errorf("TRACEPARENT = %q, want %q", env["TRACEPARENT"], want)
				}
				if _, ok := env["TRACESTATE"]; ok {
					t.Error("inherited TRACESTATE passed on")
				}
				if _, ok := env["BAGGAGE"]; ok {
					t.Error("inherited BAGGAGE passed on")
				}
			} else if env["TRACEPARENT"] != "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01" || env["BAGGAGE"] != "user=alice" {
				t.Errorf("without traces the inherited trace context must pass through: %v", env)
			}
			if !c.traceparent && r.TraceID() != "" {
				t.Errorf("TraceID() = %q without traces", r.TraceID())
			}

			report, ok := env["PGBACKUP_TELEMETRY_FILE"]
			if ok != c.report || report == "/tmp/inherited" {
				t.Fatalf("PGBACKUP_TELEMETRY_FILE = %q (set %v), want set %v", report, ok, c.report)
			}
			if c.report {
				fi, err := os.Lstat(report)
				if err != nil || !fi.Mode().IsRegular() || fi.Mode().Perm() != 0o600 {
					t.Fatalf("report file %v, %v", fi, err)
				}
				di, err := os.Stat(filepath.Dir(report))
				if err != nil || di.Mode().Perm() != 0o700 || filepath.Base(report) != "report" || !strings.HasPrefix(filepath.Base(filepath.Dir(report)), "go-cron-") {
					t.Fatalf("report directory %v, %v", di, err)
				}
			}
			if r.WantsOutput() != c.output {
				t.Errorf("WantsOutput() = %v", r.WantsOutput())
			}

			now := time.Now()
			r.End(gocron.Result{Outcome: gocron.OutcomeSuccess, Started: now, Ended: now})
			r.End(gocron.Result{Outcome: gocron.OutcomeFailure}) // ignored
			if c.report {
				if _, err := os.Stat(filepath.Dir(report)); !os.IsNotExist(err) {
					t.Errorf("report directory not removed: %v", err)
				}
			}
			if tel.current.Load() != nil {
				t.Error("run still current after End")
			}
		})
	}
}

func TestErrorType(t *testing.T) {
	exitErr := exec.Command("/bin/sh", "-c", "exit 3").Run()
	sigErr := exec.Command("/bin/sh", "-c", "kill -9 $$").Run()
	startErr := exec.Command("/nonexistent/command").Run()
	cases := []struct {
		res  gocron.Result
		want string
	}{
		{gocron.Result{Outcome: gocron.OutcomeSuccess}, ""},
		{gocron.Result{Outcome: gocron.OutcomeTimeout, ExitCode: 143, Err: exitErr}, "timeout"},
		{gocron.Result{Outcome: gocron.OutcomeCancelled, ExitCode: 143, Err: exitErr}, "cancelled"},
		{gocron.Result{Outcome: gocron.OutcomeFailure, ExitCode: 3, Err: exitErr}, "exit_status"},
		{gocron.Result{Outcome: gocron.OutcomeFailure, ExitCode: 137, Err: sigErr}, "signal"},
		{gocron.Result{Outcome: gocron.OutcomeFailure, ExitCode: 1, Err: startErr}, "start_error"},
		{gocron.Result{Outcome: gocron.OutcomeFailure, ExitCode: 1, Err: errors.New("wrapped: " + startErr.Error())}, "start_error"},
	}
	for _, c := range cases {
		if got := errorType(c.res); got != c.want {
			t.Errorf("errorType(%v, %d, %v) = %q, want %q", c.res.Outcome, c.res.ExitCode, c.res.Err, got, c.want)
		}
	}
}

func TestShutdownHardStop(t *testing.T) {
	var printed []string
	var mu sync.Mutex
	tel := &telemetry{
		cfg: config{shutdownTimeout: 100 * time.Millisecond},
		msgs: &messages{print: func(_, msg string) {
			mu.Lock()
			printed = append(printed, msg)
			mu.Unlock()
		}},
	}
	stuck := make(chan struct{})
	t.Cleanup(func() { close(stuck) })
	tel.shutdown = []namedShutdown{
		{"traces", func(context.Context) error { <-stuck; return nil }}, // ignores its context
		{"metrics", func(ctx context.Context) error { <-ctx.Done(); return ctx.Err() }},
	}
	start := time.Now()
	tel.Shutdown()
	if elapsed := time.Since(start); elapsed < 100*time.Millisecond || elapsed > 100*time.Millisecond+shutdownGrace+500*time.Millisecond {
		t.Errorf("Shutdown took %v", elapsed)
	}
	mu.Lock()
	defer mu.Unlock()
	joined := strings.Join(printed, "\n")
	if !strings.Contains(joined, "telemetry: shutdown did not finish within 100ms") || !strings.Contains(joined, "telemetry: metrics shutdown: context deadline exceeded") {
		t.Errorf("printed %q", printed)
	}
}
