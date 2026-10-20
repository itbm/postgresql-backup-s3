package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

func TestParseTimestamp(t *testing.T) {
	want := time.Date(2026, 10, 20, 2, 0, 0, 123456789, time.UTC)
	cases := []struct {
		in   string
		want time.Time
		ok   bool
	}{
		{"1792461600", want.Truncate(time.Second), true},
		{"1792461600123", want.Truncate(time.Millisecond), true},
		{"1792461600123456", want.Truncate(time.Microsecond), true},
		{"1792461600123456789", want, true},
		{"0", time.Unix(0, 0), true},
		{"17924616001", time.Time{}, false},
		{"179246160012", time.Time{}, false},
		{"17924616001234", time.Time{}, false},
		{"17924616001234567", time.Time{}, false},
		{"179246160012345678", time.Time{}, false},
		{"17924616001234567890", time.Time{}, false},
		{"9999999999999999999", time.Time{}, false}, // overflows int64
		{"", time.Time{}, false},
		{"-1792461600", time.Time{}, false},
		{"+1792461600", time.Time{}, false},
		{"1792461600%N", time.Time{}, false},
	}
	for _, c := range cases {
		got, ok := parseTimestamp(c.in)
		if ok != c.ok || !got.Equal(c.want) {
			t.Errorf("parseTimestamp(%q) = %v, %v; want %v, %v", c.in, got, ok, c.want, c.ok)
		}
	}
}

func TestParseReport(t *testing.T) {
	data := strings.Join([]string{
		"begin pre-backup 1792461600000000000",
		"end pre-backup 1792461600010000000 0",
		"begin dump 1792461600010000000",
		"set dump.format plain",
		"set compression gzip",
		"end dump 1792461638400000000 0",
		"begin verify 1792461638400",
		"end verify 1792461639600 0",
		"set encrypted no",
		"begin upload 1792461639600000",
		"set s3.key backup/app db_2026-10-20T02:00:00Z.sql.gz",
		"end upload 1792461642 2",
		"set backup.size_bytes 734003200",
		"set retention.deleted 1",
		"set retention.kept 13",
		"begin backup-error 1792461642",
		"",
		"set unknown.key value",       // not allowlisted
		"begin Dump 1792461642",       // bad name
		"begin dump",                  // missing timestamp
		"begin dump 1792461642 extra", // extra field
		"begin  dump 1792461642",      // two spaces
		"end retention 1792461642 0",  // never began
		"end backup-error 1792461642 x",
		"set backup.size_bytes -1",
		"set dump.format directory",
		"set encrypted maybe",
		"set s3.key",
		"frobnicate",
		"",
	}, "\n")
	rep := parseReport([]byte(data), false)

	if rep.ignored != 12 {
		t.Errorf("ignored = %d, want 12", rep.ignored)
	}
	var got []string
	for _, p := range rep.phases {
		got = append(got, fmt.Sprintf("%s/%s/%d", p.name, p.outcome(), p.status))
	}
	want := "pre-backup/success/0 dump/success/0 verify/success/0 upload/failure/2 backup-error/incomplete/0"
	if strings.Join(got, " ") != want {
		t.Errorf("phases = %q, want %q", strings.Join(got, " "), want)
	}
	if rep.failedPhase != "upload" {
		t.Errorf("failedPhase = %q", rep.failedPhase)
	}
	if rep.phases[2].start != time.UnixMilli(1792461638400) || rep.phases[3].end != time.Unix(1792461642, 0) {
		t.Errorf("verify start %v, upload end %v", rep.phases[2].start, rep.phases[3].end)
	}
	if rep.sizeBytes == nil || *rep.sizeBytes != 734003200 || *rep.retentionDeleted != 1 || *rep.retentionKept != 13 {
		t.Errorf("counts = %v, %v, %v", rep.sizeBytes, rep.retentionDeleted, rep.retentionKept)
	}
	if rep.s3Key != "backup/app db_2026-10-20T02:00:00Z.sql.gz" || rep.dumpFormat != "plain" || rep.compression != "gzip" || rep.encrypted == nil || *rep.encrypted {
		t.Errorf("strings = %q, %q, %q, %v", rep.s3Key, rep.dumpFormat, rep.compression, rep.encrypted)
	}
}

func TestParseReportPairing(t *testing.T) {
	rep := parseReport([]byte("begin retention 100\nbegin retention 200\nend retention 300 0\nend retention 400 1\nend retention 500 0\n"), false)
	if len(rep.phases) != 2 || rep.ignored != 1 {
		t.Fatalf("phases %d, ignored %d", len(rep.phases), rep.ignored)
	}
	outer, inner := rep.phases[0], rep.phases[1]
	if inner.end != time.Unix(300, 0) || inner.status != 0 || outer.end != time.Unix(400, 0) || outer.status != 1 {
		t.Errorf("inner %+v, outer %+v", inner, outer)
	}
	if rep.failedPhase != "retention" {
		t.Errorf("failedPhase = %q", rep.failedPhase)
	}
}

func TestParseReportLimits(t *testing.T) {
	var b strings.Builder
	for i := range 70 {
		fmt.Fprintf(&b, "begin p%d 1792461600\nend p%d 1792461601 0\n", i, i)
	}
	for range 40 {
		b.WriteString("set compression zstd\n")
	}
	b.WriteString("set s3.key " + strings.Repeat("k", maxReportLine) + "\n")
	rep := parseReport([]byte(b.String()), false)
	// 6 begins and their 6 ends over the phase limit, 8 sets over the set
	// limit and one line over the line limit.
	if len(rep.phases) != maxReportPhases || rep.ignored != 6+6+8+1 {
		t.Errorf("phases %d, ignored %d", len(rep.phases), rep.ignored)
	}
}

func TestReportStrings(t *testing.T) {
	long := strings.Repeat("a", maxReportStrings-1) + "\u00e9" + "tail"
	rep := parseReport([]byte("set s3.key "+long+"\nset compression bad\xffname\n"), false)
	if len(rep.s3Key) != maxReportStrings-1 || rep.s3Key != strings.Repeat("a", maxReportStrings-1) {
		t.Errorf("s3.key has %d bytes", len(rep.s3Key))
	}
	if rep.compression != "bad\uFFFDname" {
		t.Errorf("compression = %q", rep.compression)
	}
}

func TestClamp(t *testing.T) {
	start, end := time.Unix(1000, 0), time.Unix(2000, 0)
	rep := &report{phases: []*phase{
		{name: "early", start: time.Unix(10, 0), end: time.Unix(1500, 0), ended: true},
		{name: "late", start: time.Unix(1800, 0), end: time.Unix(3000, 0), ended: true},
		{name: "backwards", start: time.Unix(1500, 0), end: time.Unix(1200, 0), ended: true},
		{name: "open", start: time.Unix(1900, 0)},
	}}
	rep.clamp(start, end)
	want := [][2]int64{{1000, 1500}, {1800, 2000}, {1500, 1500}, {1900, 2000}}
	for i, p := range rep.phases {
		if p.start.Unix() != want[i][0] || p.end.Unix() != want[i][1] {
			t.Errorf("%s: %d to %d, want %v", p.name, p.start.Unix(), p.end.Unix(), want[i])
		}
	}
	if rep.phases[3].statusText() != "phase did not complete" || rep.phases[3].outcome() != "incomplete" {
		t.Errorf("open phase: %q, %q", rep.phases[3].statusText(), rep.phases[3].outcome())
	}
}

func TestReadReport(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "report")
	if err := os.WriteFile(path, []byte("begin dump 1792461600\nend dump 1792461601 0\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	rep, err := readReport(path)
	if err != nil || len(rep.phases) != 1 || rep.ignored != 0 {
		t.Fatalf("readReport = %+v, %v", rep, err)
	}

	link := filepath.Join(dir, "link")
	if err := os.Symlink(path, link); err != nil {
		t.Fatal(err)
	}
	if _, err := readReport(link); err == nil {
		t.Error("readReport followed a symbolic link")
	}
	if _, err := readReport(dir); err == nil {
		t.Error("readReport read a directory")
	}
	fifo := filepath.Join(dir, "fifo")
	if err := syscall.Mkfifo(fifo, 0o600); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() { _, err := readReport(fifo); done <- err }()
	select {
	case err := <-done:
		if err == nil {
			t.Error("readReport read a FIFO")
		}
	case <-time.After(5 * time.Second):
		t.Fatal("readReport blocked on a FIFO")
	}
	if _, err := readReport(filepath.Join(dir, "missing")); err == nil {
		t.Error("readReport of a missing file succeeded")
	}
}

func TestReadReportSizeLimit(t *testing.T) {
	path := filepath.Join(t.TempDir(), "report")
	line := "set compression gzip\n"
	var b strings.Builder
	b.WriteString("begin dump 1792461600\nend dump 1792461601 0\n")
	for b.Len() < maxReportBytes+100 {
		b.WriteString("begin\n") // bad records, counted until the limit
	}
	b.WriteString(line)
	if err := os.WriteFile(path, []byte(b.String()), 0o600); err != nil {
		t.Fatal(err)
	}
	rep, err := readReport(path)
	if err != nil {
		t.Fatal(err)
	}
	// Everything after the first two lines is ignored: whole "begin" lines
	// within 1 MiB, then the partial line the limit cuts.
	wantIgnored := (maxReportBytes - len("begin dump 1792461600\nend dump 1792461601 0\n") + len("begin\n") - 1) / len("begin\n")
	if len(rep.phases) != 1 || rep.compression != "" || rep.ignored != wantIgnored {
		t.Errorf("phases %d, compression %q, ignored %d, want %d", len(rep.phases), rep.compression, rep.ignored, wantIgnored)
	}
}
