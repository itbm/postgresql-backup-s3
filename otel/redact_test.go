package main

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
	"unicode/utf8"
)

func TestRedactor(t *testing.T) {
	clearEnv(t)
	dir := t.TempDir()
	pwFile := filepath.Join(dir, "pw")
	if err := os.WriteFile(pwFile, []byte("file-password-123\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	setEnv(t, map[string]string{
		"POSTGRES_PASSWORD":          "pg-password-1",
		"PGPASSWORD":                 "pg-password-1-longer",
		"S3_SECRET_ACCESS_KEY":       "**None**",
		"AWS_SECRET_ACCESS_KEY":      "aws/secret+key",
		"AWS_SESSION_TOKEN":          "short",
		"ENCRYPTION_PASSWORD_FILE":   pwFile,
		"HOOK_POST_BACKUP_URL":       "https://hc-ping.com/0123-abcd",
		"OTEL_EXPORTER_OTLP_HEADERS": "api-key=hdr%20secret%3D1, x-other = plainvalue9 ,baretoken12345",
		// A password in an endpoint URL, and an endpoint the SDK cannot parse.
		"OTEL_EXPORTER_OTLP_TRACES_ENDPOINT": "https://user:endpoint-pass-1@collector:4318",
		"OTEL_EXPORTER_OTLP_ENDPOINT":        "http://collector:4318/%zz",
	})
	r := newRedactor()
	cases := map[string]string{
		"password pg-password-1-longer and pg-password-1": "password [REDACTED] and [REDACTED]",
		"key aws/secret+key":                              "key [REDACTED]",
		"token short stays":                               "token short stays",
		"file file-password-123 end":                      "file [REDACTED] end",
		"curl https://hc-ping.com/0123-abcd/fail":         "curl [REDACTED]/fail",
		"raw hdr%20secret%3D1 decoded hdr secret=1":       "raw [REDACTED] decoded [REDACTED]",
		"other plainvalue9 bare baretoken12345":           "other [REDACTED] bare [REDACTED]",
		"placeholder **None** stays":                      "placeholder **None** stays",
		"url https://user:endpoint-pass-1@collector:4318": "url https://user:[REDACTED]@collector:4318",
		`parse "http://collector:4318/%zz": invalid`:      `parse "[REDACTED]": invalid`,
		"Post http://collector:4318/v1/traces":            "Post http://collector:4318/v1/traces",
	}
	for in, want := range cases {
		if got := r.apply(in); got != want {
			t.Errorf("apply(%q) = %q, want %q", in, got, want)
		}
	}

	var none *redactor
	if none.apply("x") != "x" || (&redactor{}).apply("x") != "x" {
		t.Error("an empty redactor changed text")
	}
}

func TestCleanText(t *testing.T) {
	cases := []struct {
		in, want string
		keepTab  bool
	}{
		{"plain text", "plain text", true},
		{"tab\tkept", "tab\tkept", true},
		{"tab\tdropped", "tabdropped", false},
		{"bell\a esc\x1b[31m del\x7f c1\u0085 nbsp\u00a0", "bell esc[31m del c1 nbsp\u00a0", true},
		{"bad\xff\xfeutf8", "bad\uFFFD\uFFFDutf8", true},
		{"cr\r\nlf", "crlf", true},
	}
	for _, c := range cases {
		if got := cleanText(c.in, c.keepTab); got != c.want {
			t.Errorf("cleanText(%q, %v) = %q, want %q", c.in, c.keepTab, got, c.want)
		}
	}
}

func TestSanitise(t *testing.T) {
	if got := sanitise(" line one\nline\ttwo\r\n\x00 "); got != "line one line two" {
		t.Errorf("sanitise = %q", got)
	}
	long := sanitise(strings.Repeat("\u00e9", 400))
	if len(long) > maxMessageBytes || !utf8.ValidString(long) || len(long) != 512 {
		t.Errorf("sanitise of a long string: %d bytes, valid %v", len(long), utf8.ValidString(long))
	}
	odd := sanitise("x" + strings.Repeat("\u00e9", 400))
	if len(odd) != 511 || !utf8.ValidString(odd) {
		t.Errorf("sanitise did not cut at a character boundary: %d bytes", len(odd))
	}
}

func TestMessagesRateLimitAndRedact(t *testing.T) {
	var printed []string
	now := time.Unix(1000, 0)
	m := &messages{
		print:  func(sev, msg string) { printed = append(printed, sev+" "+msg) },
		secret: func() *redactor { return redactorFor([]string{"api-key-secret"}) },
		now:    func() time.Time { return now },
	}
	m.handleError(errors.New("export failed: 401 for api-key-secret\nretrying"))
	m.handleError(errors.New("export failed: 401 for api-key-secret\nretrying"))
	m.warn("other")
	now = now.Add(61 * time.Second)
	m.handleError(errors.New("export failed: 401 for api-key-secret\nretrying"))
	m.handleError(nil)
	want := []string{
		"WARN telemetry: export failed: 401 for [REDACTED] retrying",
		"WARN telemetry: other",
		"WARN telemetry: export failed: 401 for [REDACTED] retrying",
	}
	if strings.Join(printed, "|") != strings.Join(want, "|") {
		t.Errorf("printed %q, want %q", printed, want)
	}
}

func TestLogSink(t *testing.T) {
	var printed []string
	m := &messages{print: func(_, msg string) { printed = append(printed, msg) }}
	sink := &logSink{m: m}
	if !sink.Enabled(0) || !sink.Enabled(1) || sink.Enabled(4) || sink.Enabled(8) {
		t.Error("Enabled levels are wrong")
	}
	sink.Info(1, "dropped log records", "dropped", 3)
	sink.Info(4, "info message")
	sink.Error(errors.New("bad escape"), "escape header value", "value", "Bearer%zzsecret")
	sink.WithValues("name", "go-cron").Error(errors.New("missing '='"), "parse headers", "input", "Bearer secret")
	want := []string{
		"telemetry: dropped log records dropped=3",
		"telemetry: escape header value: bad escape",
		`telemetry: parse headers: missing '=' name="go-cron"`,
	}
	if strings.Join(printed, "|") != strings.Join(want, "|") {
		t.Errorf("printed %q, want %q", printed, want)
	}
}

func TestLogBody(t *testing.T) {
	if got := logBody("short line"); got != "short line" {
		t.Errorf("logBody(short) = %q", got)
	}
	long := strings.Repeat("é", maxLogBodyBytes) // two bytes per character
	got := logBody(long)
	if !strings.HasSuffix(got, "…[truncated]") || !utf8.ValidString(got) {
		t.Errorf("logBody(long) does not end in the marker or is not valid UTF-8")
	}
	if body := strings.TrimSuffix(got, "…[truncated]"); len(body) > maxLogBodyBytes {
		t.Errorf("logBody kept %d bytes, want at most %d", len(body), maxLogBodyBytes)
	}
}
