package main

import (
	"crypto/sha1"
	"errors"
	"fmt"
	"io"
	"net/url"
	"os"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// envNone is the image's placeholder for a variable that is not set.
const envNone = "**None**"

const (
	defaultShutdownTimeout = 5 * time.Second
	// maxHeadersFileBytes caps OTEL_EXPORTER_OTLP_HEADERS_FILE.
	maxHeadersFileBytes = 64 << 10
)

// signalSpec describes one OpenTelemetry signal.
type signalSpec struct {
	name  string // "traces", "metrics" or "logs"
	env   string // its name in OTEL_* variables
	path  string // appended to OTEL_EXPORTER_OTLP_ENDPOINT
	optIn bool   // enabled only when OTEL_<SIGNAL>_EXPORTER=otlp
}

var (
	tracesSignal  = signalSpec{name: "traces", env: "TRACES", path: "/v1/traces"}
	metricsSignal = signalSpec{name: "metrics", env: "METRICS", path: "/v1/metrics"}
	// Logs can contain row values and SQL from restore errors, so an
	// endpoint alone does not enable them.
	logsSignal = signalSpec{name: "logs", env: "LOGS", path: "/v1/logs", optIn: true}
)

// config is the telemetry configuration read from the environment. An empty
// endpoint means the signal is disabled.
type config struct {
	tracesEndpoint  string
	metricsEndpoint string
	logsEndpoint    string
	shutdownTimeout time.Duration
}

func (c config) enabled() bool {
	return c.tracesEndpoint != "" || c.metricsEndpoint != "" || c.logsEndpoint != ""
}

// isUnset reports whether v counts as not set: empty or **None**.
func isUnset(v string) bool {
	v = strings.TrimSpace(v)
	return v == "" || v == envNone
}

// getenv returns the trimmed value of key, or "" when it is unset, empty or
// **None**.
func getenv(key string) string {
	v := os.Getenv(key)
	if isUnset(v) {
		return ""
	}
	return strings.TrimSpace(v)
}

// cleanOTelEnv unsets every OTEL_* variable that is empty or **None**, so the
// SDK sees it as unset.
func cleanOTelEnv() {
	for _, kv := range os.Environ() {
		k, v, _ := strings.Cut(kv, "=")
		if strings.HasPrefix(k, "OTEL_") && isUnset(v) {
			_ = os.Unsetenv(k)
		}
	}
}

// loadConfig reads the telemetry configuration from the environment. warn
// receives configuration problems, each of which disables only what it
// affects. When no signal is enabled it returns a disabled config without
// side effects other than cleaning the OTEL_* variables.
func loadConfig(warn func(string)) config {
	cleanOTelEnv()
	var c config
	if strings.EqualFold(getenv("OTEL_SDK_DISABLED"), "true") {
		return c
	}
	c.tracesEndpoint = signalEndpoint(tracesSignal, warn)
	c.metricsEndpoint = signalEndpoint(metricsSignal, warn)
	c.logsEndpoint = signalEndpoint(logsSignal, warn)
	if !c.enabled() {
		return c
	}

	warnInsecureHTTPS(c, warn)
	loadHeadersFile(warn)

	c.shutdownTimeout = defaultShutdownTimeout
	if v := getenv("TELEMETRY_SHUTDOWN_TIMEOUT"); v != "" {
		d, err := time.ParseDuration(v)
		if err != nil || d <= 0 {
			warn(fmt.Sprintf("invalid TELEMETRY_SHUTDOWN_TIMEOUT %q; using %s", v, defaultShutdownTimeout))
		} else {
			c.shutdownTimeout = d
		}
	}
	return c
}

// signalEndpoint applies the gate for one signal and returns its OTLP/HTTP
// endpoint URL, or "" when the signal is disabled.
func signalEndpoint(sig signalSpec, warn func(string)) string {
	exporter := strings.ToLower(getenv("OTEL_" + sig.env + "_EXPORTER"))
	switch exporter {
	case "none":
		return ""
	case "", "otlp":
	default:
		warn(fmt.Sprintf("%s disabled: OTEL_%s_EXPORTER=%q is not supported; use otlp or none", sig.name, sig.env, exporter))
		return ""
	}
	if sig.optIn && exporter != "otlp" {
		return ""
	}

	endpointVar := "OTEL_EXPORTER_OTLP_" + sig.env + "_ENDPOINT"
	raw := getenv(endpointVar)
	perSignal := raw != ""
	if !perSignal {
		endpointVar = "OTEL_EXPORTER_OTLP_ENDPOINT"
		raw = getenv(endpointVar)
	}
	if raw == "" {
		return ""
	}

	protocol := getenv("OTEL_EXPORTER_OTLP_" + sig.env + "_PROTOCOL")
	if protocol == "" {
		protocol = getenv("OTEL_EXPORTER_OTLP_PROTOCOL")
	}
	if protocol != "" && protocol != "http/protobuf" {
		warn(fmt.Sprintf("%s disabled: OTLP protocol %q is not supported; use http/protobuf", sig.name, protocol))
		return ""
	}

	endpoint, err := endpointURL(raw, perSignal, sig.path)
	if err != nil {
		// The value is not printed: it can contain credentials.
		warn(fmt.Sprintf("%s disabled: %s %v", sig.name, endpointVar, err))
		return ""
	}
	return endpoint
}

// endpointURL validates an OTLP/HTTP endpoint. A per-signal endpoint is used
// as is; the generic endpoint gets the signal's path appended.
func endpointURL(raw string, perSignal bool, signalPath string) (string, error) {
	u, err := url.Parse(raw)
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Hostname() == "" {
		return "", errors.New("is not an http:// or https:// URL with a host")
	}
	if !perSignal {
		u.Path = strings.TrimRight(u.Path, "/") + signalPath
		u.RawPath = ""
	}
	return u.String(), nil
}

// warnInsecureHTTPS warns once when OTEL_EXPORTER_OTLP_INSECURE would have no
// effect: the endpoint URL's scheme decides whether TLS is used.
func warnInsecureHTTPS(c config, warn func(string)) {
	for _, s := range []struct {
		sig      signalSpec
		endpoint string
	}{{tracesSignal, c.tracesEndpoint}, {metricsSignal, c.metricsEndpoint}, {logsSignal, c.logsEndpoint}} {
		if !strings.HasPrefix(s.endpoint, "https://") {
			continue
		}
		for _, key := range []string{"OTEL_EXPORTER_OTLP_INSECURE", "OTEL_EXPORTER_OTLP_" + s.sig.env + "_INSECURE"} {
			if strings.EqualFold(getenv(key), "true") {
				warn(key + " is ignored for https:// endpoints; the endpoint URL's scheme decides whether TLS is used")
				return
			}
		}
	}
}

// loadHeadersFile sets OTEL_EXPORTER_OTLP_HEADERS for go-cron's own process
// from OTEL_EXPORTER_OTLP_HEADERS_FILE.
func loadHeadersFile(warn func(string)) {
	file := getenv("OTEL_EXPORTER_OTLP_HEADERS_FILE")
	if file == "" {
		return
	}
	if getenv("OTEL_EXPORTER_OTLP_HEADERS") != "" {
		warn("OTEL_EXPORTER_OTLP_HEADERS and OTEL_EXPORTER_OTLP_HEADERS_FILE are both set; ignoring OTEL_EXPORTER_OTLP_HEADERS_FILE")
		return
	}
	data, truncated, err := readSmallFile(file, maxHeadersFileBytes)
	switch {
	case err != nil:
		warn(fmt.Sprintf("cannot read OTEL_EXPORTER_OTLP_HEADERS_FILE: %v", err))
		return
	case truncated:
		warn(fmt.Sprintf("OTEL_EXPORTER_OTLP_HEADERS_FILE is larger than %d bytes; ignoring it", maxHeadersFileBytes))
		return
	}
	if headers := strings.TrimRight(data, "\r\n"); headers != "" {
		_ = os.Setenv("OTEL_EXPORTER_OTLP_HEADERS", headers)
	}
}

// readSmallFile reads at most limit bytes of the regular file name. It
// reports whether the file was longer. It never blocks on a FIFO.
func readSmallFile(name string, limit int64) (string, bool, error) {
	f, err := os.OpenFile(name, os.O_RDONLY|syscall.O_NONBLOCK, 0)
	if err != nil {
		return "", false, err
	}
	defer f.Close()
	if fi, err := f.Stat(); err != nil {
		return "", false, err
	} else if !fi.Mode().IsRegular() {
		return "", false, fmt.Errorf("%s is not a regular file", name)
	}
	data, err := io.ReadAll(io.LimitReader(f, limit+1))
	if err != nil {
		return "", false, err
	}
	if int64(len(data)) > limit {
		return string(data[:limit]), true, nil
	}
	return string(data), false, nil
}

// target describes the database and bucket that runs work on, from the
// variables backup.sh and restore.sh use.
type target struct {
	database string // POSTGRES_DATABASE as set, including "all"
	host     string
	port     string // POSTGRES_PORT as set, default 5432
	bucket   string
	prefix   string // S3_PREFIX without leading and trailing slashes
	region   string // S3_REGION, only when S3_ENDPOINT is not set
}

func loadTarget() target {
	t := target{
		database: getenv("POSTGRES_DATABASE"),
		host:     getenv("POSTGRES_HOST"),
		port:     getenv("POSTGRES_PORT"),
		bucket:   getenv("S3_BUCKET"),
		prefix:   "backup",
	}
	if t.host == "" {
		t.host = getenv("POSTGRES_PORT_5432_TCP_ADDR")
	}
	if t.port == "" {
		t.port = "5432"
	}
	if p := getenv("S3_PREFIX"); p != "" {
		t.prefix = strings.Trim(p, "/")
	}
	if getenv("S3_ENDPOINT") == "" {
		t.region = getenv("S3_REGION")
	}
	return t
}

// namespace is the db.namespace value: the database, or "" for all databases.
func (t target) namespace() string {
	if t.database == "all" {
		return ""
	}
	return t.database
}

// portNumber is the server.port value, or 0 when it is the default 5432 or
// not a number.
func (t target) portNumber() int {
	n, err := strconv.Atoi(t.port)
	if err != nil || n <= 0 || n > 65535 || n == 5432 {
		return 0
	}
	return n
}

// instanceNamespace is the UUID namespace the semantic conventions give for
// service.instance.id.
var instanceNamespace = [16]byte{0x4d, 0x63, 0x00, 0x9a, 0x8d, 0x0f, 0x11, 0xee, 0xaa, 0xd7, 0x4c, 0x79, 0x6e, 0xd8, 0xe3, 0x20}

// instanceID is the default service.instance.id: a name-based UUID of what
// the backups are of and where they go, so the identity stays the same
// across pods, restarts and upgrades.
func (t target) instanceID() string {
	name := fmt.Sprintf("postgresql://%s:%s/%s s3://%s/%s", t.host, t.port, t.database, t.bucket, t.prefix)
	return uuidV5(instanceNamespace, name)
}

// uuidV5 returns the RFC 9562 version 5 UUID of name in namespace.
func uuidV5(namespace [16]byte, name string) string {
	h := sha1.New()
	h.Write(namespace[:])
	h.Write([]byte(name))
	var u [16]byte
	copy(u[:], h.Sum(nil))
	u[6] = u[6]&0x0f | 0x50 // version 5
	u[8] = u[8]&0x3f | 0x80 // RFC 9562 variant
	return fmt.Sprintf("%x-%x-%x-%x-%x", u[0:4], u[4:6], u[6:8], u[8:10], u[10:16])
}
