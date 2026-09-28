package main

import (
	"context"
	"strings"
	"testing"
	"time"
)

func TestValidateSchedule(t *testing.T) {
	valid := []string{"@daily", "@hourly", "@every 1h", "@every 30m", "0 3 * * *", "*/5 * * * *", "CRON_TZ=Europe/London 0 3 * * *"}
	for _, s := range valid {
		if err := validateSchedule(s); err != nil {
			t.Errorf("validateSchedule(%q) = %v, want nil", s, err)
		}
	}
	invalid := []string{"", "@every", "@every nope", "@every 0s", "@every -1m", "61 * * * *", "* * *"}
	for _, s := range invalid {
		if err := validateSchedule(s); err == nil {
			t.Errorf("validateSchedule(%q) = nil, want error", s)
		}
	}
}

func TestCommandTimeout(t *testing.T) {
	cases := []struct {
		raw     string
		want    time.Duration
		wantErr bool
	}{
		{"", 0, false},
		{"0", 0, false},
		{"**None**", 0, false},
		{"2h", 2 * time.Hour, false},
		{" 90s ", 90 * time.Second, false},
		{"-1m", 0, true},
		{"soon", 0, true},
	}
	for _, c := range cases {
		t.Setenv("COMMAND_TIMEOUT", c.raw)
		got, err := commandTimeout()
		if (err != nil) != c.wantErr || got != c.want {
			t.Errorf("commandTimeout(%q) = %v, %v; want %v, err=%v", c.raw, got, err, c.want, c.wantErr)
		}
	}
}

type captureWriter struct{ strings.Builder }

func TestRunCommandCapturesAllOutput(t *testing.T) {
	var out, errOut captureWriter
	err := runCommand(context.Background(), "/bin/sh", []string{"-c", "i=0; while [ $i -lt 500 ]; do echo line$i; i=$((i+1)); done; printf tail; echo oops >&2"}, 0, time.Second, &out, &errOut)
	if err != nil {
		t.Fatalf("runCommand: %v", err)
	}
	if !strings.Contains(out.String(), "line499\ntail") {
		t.Errorf("stdout missing trailing output: %q", out.String()[max(0, out.Len()-40):])
	}
	if errOut.String() != "oops\n" {
		t.Errorf("stderr = %q, want %q", errOut.String(), "oops\n")
	}
}

func TestRunCommandTimeoutKillsProcessGroup(t *testing.T) {
	var out captureWriter
	start := time.Now()
	// The pipeline's children keep stdout open; only a process-group kill ends them quickly.
	err := runCommand(context.Background(), "/bin/sh", []string{"-c", "sleep 60 | cat; echo done"}, 500*time.Millisecond, 2*time.Second, &out, &out)
	elapsed := time.Since(start)
	if err == nil || !strings.Contains(err.Error(), "timed out") {
		t.Fatalf("err = %v, want timeout error", err)
	}
	if elapsed > 5*time.Second {
		t.Fatalf("runCommand took %s; children were not killed", elapsed)
	}
}

func TestRunCommandShutdownRunsTrap(t *testing.T) {
	var out captureWriter
	ctx, cancel := context.WithCancel(context.Background())
	time.AfterFunc(300*time.Millisecond, cancel)
	err := runCommand(ctx, "/bin/sh", []string{"-c", "trap 'echo cleaned; exit 143' TERM; sleep 60 & wait"}, 0, 5*time.Second, &out, &out)
	if err == nil || !strings.Contains(err.Error(), "shutdown") {
		t.Fatalf("err = %v, want shutdown error", err)
	}
	if !strings.Contains(out.String(), "cleaned") {
		t.Errorf("TERM trap did not run; output %q", out.String())
	}
}

func TestLineWriter(t *testing.T) {
	w := &lineWriter{prefix: "X"}
	if _, err := w.Write([]byte("a\nb")); err != nil {
		t.Fatal(err)
	}
	if string(w.buf) != "b" {
		t.Errorf("buffered %q, want %q", w.buf, "b")
	}
	w.Flush()
	if len(w.buf) != 0 {
		t.Errorf("Flush left %q", w.buf)
	}
}
