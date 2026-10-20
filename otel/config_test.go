package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// clearEnv unsets every variable telemetry reads for the rest of the test.
func clearEnv(t *testing.T) {
	t.Helper()
	prefixes := []string{"OTEL_", "POSTGRES_", "S3_", "HOOK_", "AWS_"}
	names := map[string]bool{
		"PGPASSWORD": true, "ENCRYPTION_PASSWORD": true, "ENCRYPTION_PASSWORD_FILE": true,
		"TELEMETRY_SHUTDOWN_TIMEOUT": true, "PGBACKUP_TELEMETRY_FILE": true,
		"TRACEPARENT": true, "TRACESTATE": true, "BAGGAGE": true,
	}
	for _, kv := range os.Environ() {
		k, _, _ := strings.Cut(kv, "=")
		match := names[k]
		for _, p := range prefixes {
			match = match || strings.HasPrefix(k, p)
		}
		if match {
			t.Setenv(k, "")
			os.Unsetenv(k)
		}
	}
	// Register variables that loadConfig may set, so they are restored.
	t.Setenv("OTEL_EXPORTER_OTLP_HEADERS", "")
	os.Unsetenv("OTEL_EXPORTER_OTLP_HEADERS")
}

func setEnv(t *testing.T, env map[string]string) {
	t.Helper()
	for k, v := range env {
		t.Setenv(k, v)
	}
}

// collect returns a warn function and the warnings it received.
func collect() (func(string), *[]string) {
	var got []string
	return func(s string) { got = append(got, s) }, &got
}

func TestLoadConfigGate(t *testing.T) {
	cases := []struct {
		name                     string
		env                      map[string]string
		traces, metrics, logs    string
		warnings                 []string // substrings, in order
		forbiddenWarningContents string
	}{
		{name: "nothing set"},
		{
			name:    "generic endpoint",
			env:     map[string]string{"OTEL_EXPORTER_OTLP_ENDPOINT": "http://collector:4318"},
			traces:  "http://collector:4318/v1/traces",
			metrics: "http://collector:4318/v1/metrics",
		},
		{
			name:    "generic endpoint with trailing slash and path",
			env:     map[string]string{"OTEL_EXPORTER_OTLP_ENDPOINT": "https://collector.example/otlp/"},
			traces:  "https://collector.example/otlp/v1/traces",
			metrics: "https://collector.example/otlp/v1/metrics",
		},
		{
			name: "per-signal endpoint used as is",
			env: map[string]string{
				"OTEL_EXPORTER_OTLP_ENDPOINT":        "http://collector:4318",
				"OTEL_EXPORTER_OTLP_TRACES_ENDPOINT": "http://tempo:4318",
			},
			traces:  "http://tempo:4318",
			metrics: "http://collector:4318/v1/metrics",
		},
		{
			name:   "only a per-signal endpoint",
			env:    map[string]string{"OTEL_EXPORTER_OTLP_TRACES_ENDPOINT": "http://tempo:4318/custom"},
			traces: "http://tempo:4318/custom",
		},
		{
			name: "logs need OTEL_LOGS_EXPORTER=otlp",
			env: map[string]string{
				"OTEL_EXPORTER_OTLP_ENDPOINT": "http://collector:4318",
				"OTEL_LOGS_EXPORTER":          "OTLP",
			},
			traces:  "http://collector:4318/v1/traces",
			metrics: "http://collector:4318/v1/metrics",
			logs:    "http://collector:4318/v1/logs",
		},
		{
			name: "logs exporter without an endpoint",
			env:  map[string]string{"OTEL_LOGS_EXPORTER": "otlp"},
		},
		{
			name: "exporter none disables silently",
			env: map[string]string{
				"OTEL_EXPORTER_OTLP_ENDPOINT": "http://collector:4318",
				"OTEL_TRACES_EXPORTER":        "none",
				"OTEL_LOGS_EXPORTER":          "none",
			},
			metrics: "http://collector:4318/v1/metrics",
		},
		{
			name: "unsupported exporter",
			env: map[string]string{
				"OTEL_EXPORTER_OTLP_ENDPOINT": "http://collector:4318",
				"OTEL_METRICS_EXPORTER":       "prometheus",
				"OTEL_TRACES_EXPORTER":        "otlp,console",
			},
			warnings: []string{`traces disabled: OTEL_TRACES_EXPORTER="otlp,console" is not supported`, `metrics disabled: OTEL_METRICS_EXPORTER="prometheus" is not supported`},
		},
		{
			name: "grpc protocol",
			env: map[string]string{
				"OTEL_EXPORTER_OTLP_ENDPOINT": "http://collector:4317",
				"OTEL_EXPORTER_OTLP_PROTOCOL": "grpc",
			},
			warnings: []string{`traces disabled: OTLP protocol "grpc" is not supported`, `metrics disabled: OTLP protocol "grpc"`},
		},
		{
			name: "per-signal protocol overrides the generic one",
			env: map[string]string{
				"OTEL_EXPORTER_OTLP_ENDPOINT":         "http://collector:4318",
				"OTEL_EXPORTER_OTLP_PROTOCOL":         "http/json",
				"OTEL_EXPORTER_OTLP_TRACES_PROTOCOL":  "http/protobuf",
				"OTEL_EXPORTER_OTLP_METRICS_PROTOCOL": "",
			},
			traces:   "http://collector:4318/v1/traces",
			warnings: []string{`metrics disabled: OTLP protocol "http/json"`},
		},
		{
			name: "SDK disabled",
			env: map[string]string{
				"OTEL_EXPORTER_OTLP_ENDPOINT": "http://collector:4318",
				"OTEL_LOGS_EXPORTER":          "otlp",
				"OTEL_SDK_DISABLED":           "TRUE",
				"OTEL_TRACES_EXPORTER":        "console",
			},
		},
		{
			name: "None placeholders are unset",
			env: map[string]string{
				"OTEL_EXPORTER_OTLP_ENDPOINT": "**None**",
				"OTEL_TRACES_EXPORTER":        "",
				"OTEL_SDK_DISABLED":           "**None**",
			},
		},
		{
			name:     "endpoint without a scheme",
			env:      map[string]string{"OTEL_EXPORTER_OTLP_ENDPOINT": "collector:4318"},
			warnings: []string{"traces disabled: OTEL_EXPORTER_OTLP_ENDPOINT is not an http:// or https:// URL with a host", "metrics disabled"},
		},
		{
			name:                     "endpoint without a host does not print credentials",
			env:                      map[string]string{"OTEL_EXPORTER_OTLP_METRICS_ENDPOINT": "http://user:topsecret@:4318"},
			warnings:                 []string{"metrics disabled: OTEL_EXPORTER_OTLP_METRICS_ENDPOINT is not"},
			forbiddenWarningContents: "topsecret",
		},
		{
			name:     "unsupported scheme",
			env:      map[string]string{"OTEL_EXPORTER_OTLP_TRACES_ENDPOINT": "unix:///run/otel.sock"},
			warnings: []string{"traces disabled"},
		},
		{
			name: "insecure with an https endpoint",
			env: map[string]string{
				"OTEL_EXPORTER_OTLP_ENDPOINT": "https://collector:4318",
				"OTEL_EXPORTER_OTLP_INSECURE": "true",
			},
			traces:   "https://collector:4318/v1/traces",
			metrics:  "https://collector:4318/v1/metrics",
			warnings: []string{"OTEL_EXPORTER_OTLP_INSECURE is ignored for https:// endpoints"},
		},
		{
			name: "insecure with an http endpoint",
			env: map[string]string{
				"OTEL_EXPORTER_OTLP_ENDPOINT": "http://collector:4318",
				"OTEL_EXPORTER_OTLP_INSECURE": "true",
			},
			traces:  "http://collector:4318/v1/traces",
			metrics: "http://collector:4318/v1/metrics",
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			clearEnv(t)
			setEnv(t, c.env)
			warn, got := collect()
			cfg := loadConfig(warn)
			if cfg.tracesEndpoint != c.traces || cfg.metricsEndpoint != c.metrics || cfg.logsEndpoint != c.logs {
				t.Errorf("endpoints = %q, %q, %q; want %q, %q, %q",
					cfg.tracesEndpoint, cfg.metricsEndpoint, cfg.logsEndpoint, c.traces, c.metrics, c.logs)
			}
			if len(*got) != len(c.warnings) {
				t.Fatalf("warnings = %q, want %d matching %q", *got, len(c.warnings), c.warnings)
			}
			for i, w := range c.warnings {
				if !strings.Contains((*got)[i], w) {
					t.Errorf("warning %d = %q, want it to contain %q", i, (*got)[i], w)
				}
				if c.forbiddenWarningContents != "" && strings.Contains((*got)[i], c.forbiddenWarningContents) {
					t.Errorf("warning %q leaks %q", (*got)[i], c.forbiddenWarningContents)
				}
			}
		})
	}
}

func TestLoadConfigCleansEmptyOTelVariables(t *testing.T) {
	clearEnv(t)
	setEnv(t, map[string]string{
		"OTEL_SERVICE_NAME":          "",
		"OTEL_RESOURCE_ATTRIBUTES":   "**None**",
		"OTEL_BSP_SCHEDULE_DELAY":    " ",
		"OTEL_METRIC_EXPORT_TIMEOUT": "1000",
		"NOT_OTEL":                   "**None**",
	})
	loadConfig(func(string) {})
	for _, k := range []string{"OTEL_SERVICE_NAME", "OTEL_RESOURCE_ATTRIBUTES", "OTEL_BSP_SCHEDULE_DELAY"} {
		if _, ok := os.LookupEnv(k); ok {
			t.Errorf("%s is still set", k)
		}
	}
	if os.Getenv("OTEL_METRIC_EXPORT_TIMEOUT") != "1000" || os.Getenv("NOT_OTEL") != "**None**" {
		t.Error("loadConfig changed a variable it should keep")
	}
}

func TestShutdownTimeout(t *testing.T) {
	cases := []struct {
		raw  string
		want time.Duration
		warn bool
	}{
		{"", defaultShutdownTimeout, false},
		{"**None**", defaultShutdownTimeout, false},
		{"2s", 2 * time.Second, false},
		{"250ms", 250 * time.Millisecond, false},
		{"soon", defaultShutdownTimeout, true},
		{"0s", defaultShutdownTimeout, true},
		{"-1s", defaultShutdownTimeout, true},
	}
	for _, c := range cases {
		clearEnv(t)
		t.Setenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://collector:4318")
		t.Setenv("TELEMETRY_SHUTDOWN_TIMEOUT", c.raw)
		warn, got := collect()
		cfg := loadConfig(warn)
		if cfg.shutdownTimeout != c.want || (len(*got) > 0) != c.warn {
			t.Errorf("TELEMETRY_SHUTDOWN_TIMEOUT=%q: timeout %v, warnings %q; want %v, warning %v", c.raw, cfg.shutdownTimeout, *got, c.want, c.warn)
		}
	}
}

func TestHeadersFile(t *testing.T) {
	dir := t.TempDir()
	file := filepath.Join(dir, "headers")
	if err := os.WriteFile(file, []byte("api-key=s3cr3t-api-key,x-tenant=a\n\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	t.Run("read", func(t *testing.T) {
		clearEnv(t)
		t.Setenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://collector:4318")
		t.Setenv("OTEL_EXPORTER_OTLP_HEADERS_FILE", file)
		warn, got := collect()
		loadConfig(warn)
		if h := os.Getenv("OTEL_EXPORTER_OTLP_HEADERS"); h != "api-key=s3cr3t-api-key,x-tenant=a" || len(*got) != 0 {
			t.Errorf("headers %q, warnings %q", h, *got)
		}
	})
	t.Run("both set", func(t *testing.T) {
		clearEnv(t)
		t.Setenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://collector:4318")
		t.Setenv("OTEL_EXPORTER_OTLP_HEADERS_FILE", file)
		t.Setenv("OTEL_EXPORTER_OTLP_HEADERS", "api-key=direct")
		warn, got := collect()
		loadConfig(warn)
		if h := os.Getenv("OTEL_EXPORTER_OTLP_HEADERS"); h != "api-key=direct" || len(*got) != 1 || !strings.Contains((*got)[0], "ignoring OTEL_EXPORTER_OTLP_HEADERS_FILE") {
			t.Errorf("headers %q, warnings %q", h, *got)
		}
	})
	t.Run("missing", func(t *testing.T) {
		clearEnv(t)
		t.Setenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://collector:4318")
		t.Setenv("OTEL_EXPORTER_OTLP_HEADERS_FILE", filepath.Join(dir, "missing"))
		warn, got := collect()
		cfg := loadConfig(warn)
		if _, ok := os.LookupEnv("OTEL_EXPORTER_OTLP_HEADERS"); ok || len(*got) != 1 || !cfg.enabled() {
			t.Errorf("headers set %v, warnings %q, enabled %v", ok, *got, cfg.enabled())
		}
	})
	t.Run("telemetry disabled", func(t *testing.T) {
		clearEnv(t)
		t.Setenv("OTEL_EXPORTER_OTLP_HEADERS_FILE", file)
		loadConfig(func(s string) { t.Errorf("unexpected warning %q", s) })
		if _, ok := os.LookupEnv("OTEL_EXPORTER_OTLP_HEADERS"); ok {
			t.Error("headers file read although telemetry is disabled")
		}
	})
}

func TestUUIDv5(t *testing.T) {
	// RFC 9562 namespace for DNS names.
	dns := [16]byte{0x6b, 0xa7, 0xb8, 0x10, 0x9d, 0xad, 0x11, 0xd1, 0x80, 0xb4, 0x00, 0xc0, 0x4f, 0xd4, 0x30, 0xc8}
	if got, want := uuidV5(dns, "www.example.com"), "2ed6657d-e927-568b-95e1-2665a8aea6a2"; got != want {
		t.Errorf("uuidV5(DNS, www.example.com) = %s, want %s", got, want)
	}
}

func TestTarget(t *testing.T) {
	// Expected IDs computed independently with Python's uuid.uuid5.
	cases := []struct {
		name      string
		env       map[string]string
		id        string
		namespace string
		host      string
		port      int
		region    string
	}{
		{
			name: "full",
			env: map[string]string{
				"POSTGRES_HOST": "db.example", "POSTGRES_PORT": "5433", "POSTGRES_DATABASE": "appdb",
				"S3_BUCKET": "my-bucket", "S3_PREFIX": "/backups/daily/", "S3_REGION": "eu-west-2",
			},
			id: "0ce51144-5233-5e4f-b515-16abac112d27", namespace: "appdb", host: "db.example", port: 5433, region: "eu-west-2",
		},
		{
			name: "defaults and placeholders",
			env: map[string]string{
				"POSTGRES_HOST": "**None**", "POSTGRES_DATABASE": "**None**", "S3_BUCKET": "**None**",
				"S3_PREFIX": "**None**", "S3_REGION": "us-west-1", "S3_ENDPOINT": "https://minio:9000",
			},
			id: "6c5869f5-ed06-5fe0-8a3b-0c8bf2f11700",
		},
		{
			name: "linked container host and all databases",
			env: map[string]string{
				"POSTGRES_PORT_5432_TCP_ADDR": "10.0.0.5", "POSTGRES_PORT": "5432", "POSTGRES_DATABASE": "all", "S3_BUCKET": "b",
			},
			id: "97011c6a-c4ef-5644-8022-a39edd46db49", host: "10.0.0.5",
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			clearEnv(t)
			setEnv(t, c.env)
			tg := loadTarget()
			if got := tg.instanceID(); got != c.id {
				t.Errorf("instanceID() = %s, want %s (target %+v)", got, c.id, tg)
			}
			if tg.namespace() != c.namespace || tg.host != c.host || tg.portNumber() != c.port || tg.region != c.region {
				t.Errorf("target %+v: namespace %q, port %d", tg, tg.namespace(), tg.portNumber())
			}
		})
	}
}
