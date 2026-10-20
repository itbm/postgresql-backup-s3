package main

import (
	"cmp"
	"fmt"
	"net/url"
	"os"
	"slices"
	"strings"
	"sync"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/go-logr/logr"
)

const (
	redacted = "[REDACTED]"
	// minSecretLen is the shortest value redacted; shorter values would
	// match too much ordinary output.
	minSecretLen = 8
	// maxSecretFileBytes caps how much of a *_FILE secret is read.
	maxSecretFileBytes = 4 << 10
	// maxMessageBytes caps telemetry's own messages and span status text.
	maxMessageBytes = 512
)

// secretVars hold secrets as their values.
var secretVars = []string{
	"POSTGRES_PASSWORD", "PGPASSWORD", "S3_SECRET_ACCESS_KEY", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN", "ENCRYPTION_PASSWORD",
	// Hook URLs often carry a token.
	"HOOK_PRE_BACKUP_URL", "HOOK_POST_BACKUP_URL", "HOOK_BACKUP_ERROR_URL",
	"HOOK_PRE_RESTORE_URL", "HOOK_POST_RESTORE_URL", "HOOK_RESTORE_ERROR_URL",
}

// secretFileVars name files whose contents are secrets.
var secretFileVars = []string{"POSTGRES_PASSWORD_FILE", "S3_SECRET_ACCESS_KEY_FILE", "ENCRYPTION_PASSWORD_FILE"}

// headerVars hold OTLP headers, whose values are often API keys.
var headerVars = []string{
	"OTEL_EXPORTER_OTLP_HEADERS", "OTEL_EXPORTER_OTLP_TRACES_HEADERS",
	"OTEL_EXPORTER_OTLP_METRICS_HEADERS", "OTEL_EXPORTER_OTLP_LOGS_HEADERS",
}

// endpointVars hold OTLP endpoint URLs. The SDK prints a URL it cannot parse,
// and a URL can carry a password.
var endpointVars = []string{
	"OTEL_EXPORTER_OTLP_ENDPOINT", "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT",
	"OTEL_EXPORTER_OTLP_METRICS_ENDPOINT", "OTEL_EXPORTER_OTLP_LOGS_ENDPOINT",
}

// redactor replaces known secret values with [REDACTED]. A nil or empty
// redactor leaves text unchanged.
type redactor struct {
	r *strings.Replacer
}

// newRedactor collects the secrets from the current environment and secret
// files.
func newRedactor() *redactor {
	var secrets []string
	add := func(v string) {
		if len(v) >= minSecretLen && v != envNone {
			secrets = append(secrets, v)
		}
	}
	for _, key := range secretVars {
		v := os.Getenv(key)
		add(v)
		add(strings.TrimSpace(v))
	}
	for _, key := range secretFileVars {
		if name := getenv(key); name != "" {
			if data, _, err := readSmallFile(name, maxSecretFileBytes); err == nil {
				add(strings.TrimRight(data, "\r\n"))
			}
		}
	}
	for _, key := range headerVars {
		for pair := range strings.SplitSeq(os.Getenv(key), ",") {
			_, v, ok := strings.Cut(pair, "=")
			if !ok {
				// Not a key=value pair, so perhaps a bare token.
				add(strings.TrimSpace(pair))
				continue
			}
			// The SDK sends the value decoded and trimmed.
			add(strings.TrimSpace(v))
			if dec, err := url.PathUnescape(v); err == nil {
				add(strings.TrimSpace(dec))
			}
		}
	}
	for _, key := range endpointVars {
		if v := getenv(key); v != "" {
			u, err := url.Parse(v)
			switch {
			case err != nil:
				add(v)
			case u.User != nil:
				pw, _ := u.User.Password()
				add(pw)
			}
		}
	}
	return redactorFor(secrets)
}

func redactorFor(secrets []string) *redactor {
	if len(secrets) == 0 {
		return &redactor{}
	}
	// strings.Replacer tries the old strings in argument order, so put
	// longer secrets first: a secret that contains another is then
	// replaced whole.
	slices.SortFunc(secrets, func(a, b string) int {
		return cmp.Or(cmp.Compare(len(b), len(a)), strings.Compare(a, b))
	})
	secrets = slices.Compact(secrets)
	pairs := make([]string, 0, 2*len(secrets))
	for _, s := range secrets {
		pairs = append(pairs, s, redacted)
	}
	return &redactor{r: strings.NewReplacer(pairs...)}
}

func (r *redactor) apply(s string) string {
	if r == nil || r.r == nil {
		return s
	}
	return r.r.Replace(s)
}

// cleanText makes s valid UTF-8 and removes control characters, keeping tabs
// when keepTab is set.
func cleanText(s string, keepTab bool) string {
	clean := utf8.ValidString(s)
	for i := 0; clean && i < len(s); i++ {
		if c := s[i]; (c < 0x20 && !(keepTab && c == '\t')) || c == 0x7f || c == 0xc2 {
			clean = false // 0xc2 starts the C1 controls U+0080 to U+009F
		}
	}
	if clean {
		return s
	}
	var b strings.Builder
	b.Grow(len(s))
	// Ranging over a string yields U+FFFD for each invalid byte.
	for _, r := range s {
		if !unicode.IsControl(r) || (keepTab && r == '\t') {
			b.WriteRune(r)
		}
	}
	return b.String()
}

// truncate cuts the valid UTF-8 string s to at most n bytes without
// splitting a character.
func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	for n > 0 && !utf8.RuneStart(s[n]) {
		n--
	}
	return s[:n]
}

// sanitise turns s into one line of valid UTF-8 without control characters,
// at most maxMessageBytes long.
func sanitise(s string) string {
	s = strings.NewReplacer("\r\n", " ", "\n", " ", "\r", " ", "\t", " ").Replace(s)
	return strings.TrimSpace(truncate(cleanText(s, false), maxMessageBytes))
}

// messages prints telemetry's own warnings and the SDK's errors through the
// Printer, redacted and sanitised, printing each distinct message at most
// once a minute.
type messages struct {
	print  func(severity, message string)
	secret func() *redactor
	now    func() time.Time

	mu   sync.Mutex
	seen map[string]time.Time
}

// maxSeenMessages bounds the rate limiter's memory.
const maxSeenMessages = 256

func (m *messages) warn(msg string) {
	if m == nil || m.print == nil {
		return
	}
	var r *redactor
	if m.secret != nil {
		r = m.secret()
	}
	msg = sanitise(r.apply(msg))
	if msg == "" {
		return
	}
	now := time.Now()
	if m.now != nil {
		now = m.now()
	}
	m.mu.Lock()
	if last, ok := m.seen[msg]; ok && now.Sub(last) < time.Minute {
		m.mu.Unlock()
		return
	}
	if m.seen == nil || len(m.seen) >= maxSeenMessages {
		m.seen = map[string]time.Time{}
	}
	m.seen[msg] = now
	m.mu.Unlock()
	m.print("WARN", "telemetry: "+msg)
}

// handleError is the OpenTelemetry error handler.
func (m *messages) handleError(err error) {
	if err != nil {
		m.warn(err.Error())
	}
}

// logSink passes the SDK's errors and warnings (verbosity 0 and 1) to
// messages and drops its info and debug messages.
type logSink struct {
	m      *messages
	values []any
}

var _ logr.LogSink = (*logSink)(nil)

func (*logSink) Init(logr.RuntimeInfo)  {}
func (*logSink) Enabled(level int) bool { return level <= 1 }

func (l *logSink) Info(level int, msg string, kv ...any) {
	if level <= 1 {
		l.m.warn(formatLog(msg, nil, append(slices.Clip(l.values), kv...)))
	}
}

func (l *logSink) Error(err error, msg string, kv ...any) {
	l.m.warn(formatLog(msg, err, append(slices.Clip(l.values), kv...)))
}

func (l *logSink) WithValues(kv ...any) logr.LogSink {
	return &logSink{m: l.m, values: append(slices.Clip(l.values), kv...)}
}

func (l *logSink) WithName(string) logr.LogSink { return l }

// loggableKeys are the SDK log keys whose string values are safe to print.
// Others, such as "value" and "input" when parsing headers, can hold secrets.
var loggableKeys = map[string]bool{"name": true, "file": true, "environment variable": true}

// formatLog formats an SDK log message with its error and the key-value
// pairs that cannot hold secrets.
func formatLog(msg string, err error, kv []any) string {
	var b strings.Builder
	b.WriteString(msg)
	if err != nil {
		b.WriteString(": ")
		b.WriteString(err.Error())
	}
	for i := 0; i+1 < len(kv); i += 2 {
		key := fmt.Sprint(kv[i])
		switch v := kv[i+1].(type) {
		case error, bool, int, int32, int64, uint, uint32, uint64, float64, time.Duration:
			fmt.Fprintf(&b, " %s=%v", key, v)
		case string:
			if loggableKeys[key] {
				fmt.Fprintf(&b, " %s=%q", key, v)
			}
		}
	}
	return b.String()
}
