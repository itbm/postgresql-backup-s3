package main

// The run report is how backup.sh and restore.sh tell go-cron about their
// phases without making network calls. go-cron creates an empty file in a
// private directory for each run and passes its path in
// PGBACKUP_TELEMETRY_FILE. The script appends one record per line, with
// fields separated by one space:
//
//	begin <phase> <unix_time>
//	end <phase> <unix_time> <status>
//	set <key> <value>
//
// The unit of a timestamp follows from its number of digits (up to 10
// seconds, 13 milliseconds, 16 microseconds, 19 nanoseconds), so BusyBox
// date, which has no %N, still works at one-second precision. After the
// command exits, go-cron turns the records into phase spans, metrics and
// root span attributes.

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"os"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"time"
)

const (
	maxReportBytes   = 1 << 20
	maxReportLine    = 4 << 10
	maxReportPhases  = 64
	maxReportSets    = 32
	maxReportStrings = 1024
)

var phaseName = regexp.MustCompile(`^[a-z][a-z0-9-]{0,31}$`)

// knownPhases are the phase names used as metric attribute values; others
// are recorded as "other" in metrics.
var knownPhases = map[string]bool{
	"pre-backup": true, "dump": true, "verify": true, "encrypt": true, "upload": true,
	"retention": true, "post-backup": true, "backup-error": true,
	"resolve": true, "pre-restore": true, "download": true, "decrypt": true, "drop": true,
	"create": true, "restore": true, "post-restore": true, "restore-error": true,
}

type phase struct {
	name       string
	start, end time.Time
	ended      bool
	status     int
}

// outcome is the pgbackup.phase.outcome metric attribute.
func (p *phase) outcome() string {
	switch {
	case !p.ended:
		return "incomplete"
	case p.status != 0:
		return "failure"
	}
	return "success"
}

// report is a parsed run report.
type report struct {
	phases      []*phase // in the order they began
	failedPhase string   // the first phase that ended with a non-zero status

	sizeBytes, retentionDeleted, retentionKept *int64
	s3Key, dumpFormat, compression             string
	encrypted                                  *bool

	ignored int // lines ignored as invalid or over a limit
}

// readReport reads the report file at path, refusing anything but a regular
// file.
func readReport(path string) (*report, error) {
	fi, err := os.Lstat(path)
	if err != nil {
		return nil, err
	}
	if !fi.Mode().IsRegular() {
		return nil, errors.New("run report is not a regular file")
	}
	// O_NOFOLLOW refuses a symbolic link swapped in after the Lstat, and
	// O_NONBLOCK keeps a FIFO from blocking the run.
	f, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	if fi, err := f.Stat(); err != nil {
		return nil, err
	} else if !fi.Mode().IsRegular() {
		return nil, errors.New("run report is not a regular file")
	}
	data, err := io.ReadAll(io.LimitReader(f, maxReportBytes+1))
	if err != nil {
		return nil, err
	}
	truncated := len(data) > maxReportBytes
	if truncated {
		data = data[:maxReportBytes]
	}
	return parseReport(data, truncated), nil
}

// parseReport parses report records. truncated says that data stops in the
// middle of the file, so its last line is incomplete.
func parseReport(data []byte, truncated bool) *report {
	rep := &report{}
	lines := bytes.Split(data, []byte{'\n'})
	if truncated {
		if len(lines[len(lines)-1]) > 0 {
			rep.ignored++
		}
		lines = lines[:len(lines)-1]
	}
	open := map[string][]*phase{}
	sets := 0
	for _, line := range lines {
		switch {
		case len(line) == 0:
		case len(line) > maxReportLine:
			rep.ignored++
		case !rep.parseLine(string(line), open, &sets):
			rep.ignored++
		}
	}
	return rep
}

func (rep *report) parseLine(line string, open map[string][]*phase, sets *int) bool {
	kind, rest, _ := strings.Cut(line, " ")
	switch kind {
	case "begin":
		f := strings.Split(rest, " ")
		if len(f) != 2 || !phaseName.MatchString(f[0]) || len(rep.phases) >= maxReportPhases {
			return false
		}
		start, ok := parseTimestamp(f[1])
		if !ok {
			return false
		}
		p := &phase{name: f[0], start: start}
		rep.phases = append(rep.phases, p)
		open[p.name] = append(open[p.name], p)
		return true

	case "end":
		f := strings.Split(rest, " ")
		if len(f) != 3 || len(open[f[0]]) == 0 {
			return false
		}
		end, ok := parseTimestamp(f[1])
		status, err := strconv.ParseUint(f[2], 10, 31)
		if !ok || err != nil {
			return false
		}
		// An end closes the most recent open begin with the same name.
		stack := open[f[0]]
		p := stack[len(stack)-1]
		open[f[0]] = stack[:len(stack)-1]
		p.end, p.ended, p.status = end, true, int(status)
		if p.status != 0 && rep.failedPhase == "" {
			rep.failedPhase = p.name
		}
		return true

	case "set":
		key, value, ok := strings.Cut(rest, " ")
		if !ok || key == "" || value == "" {
			return false
		}
		if *sets++; *sets > maxReportSets {
			return false
		}
		return rep.set(key, value)
	}
	return false
}

// set records an allowlisted key; other keys are ignored.
func (rep *report) set(key, value string) bool {
	switch key {
	case "backup.size_bytes":
		return setCount(&rep.sizeBytes, value)
	case "retention.deleted":
		return setCount(&rep.retentionDeleted, value)
	case "retention.kept":
		return setCount(&rep.retentionKept, value)
	case "s3.key":
		rep.s3Key = reportString(value)
	case "dump.format":
		if value != "plain" && value != "custom" {
			return false
		}
		rep.dumpFormat = value
	case "compression":
		rep.compression = reportString(value)
	case "encrypted":
		if value != "yes" && value != "no" {
			return false
		}
		b := value == "yes"
		rep.encrypted = &b
	default:
		return false
	}
	return true
}

func setCount(dst **int64, value string) bool {
	n, err := strconv.ParseInt(value, 10, 64)
	if err != nil || n < 0 {
		return false
	}
	*dst = &n
	return true
}

// reportString makes a string value valid UTF-8 of at most maxReportStrings
// bytes.
func reportString(s string) string {
	return truncate(strings.ToValidUTF8(s, "\uFFFD"), maxReportStrings)
}

// parseTimestamp parses a Unix time in seconds (up to 10 digits),
// milliseconds (13), microseconds (16) or nanoseconds (19).
func parseTimestamp(s string) (time.Time, bool) {
	if s == "" || len(s) > 19 || strings.Trim(s, "0123456789") != "" {
		return time.Time{}, false
	}
	n, err := strconv.ParseInt(s, 10, 64)
	if err != nil {
		return time.Time{}, false
	}
	switch len(s) {
	case 13:
		return time.UnixMilli(n), true
	case 16:
		return time.UnixMicro(n), true
	case 19:
		return time.Unix(0, n), true
	}
	if len(s) <= 10 {
		return time.Unix(n, 0), true
	}
	return time.Time{}, false
}

// clamp keeps the phases within the run, from start to end. A phase still
// open when the command exited ends at end.
func (rep *report) clamp(start, end time.Time) {
	for _, p := range rep.phases {
		p.start = clampTime(p.start, start, end)
		if p.ended {
			p.end = clampTime(p.end, p.start, end)
		} else {
			p.end = end
		}
	}
}

func clampTime(t, lo, hi time.Time) time.Time {
	if t.Before(lo) {
		return lo
	}
	if t.After(hi) {
		return hi
	}
	return t
}

// statusText is the span status description of a phase that failed.
func (p *phase) statusText() string {
	if !p.ended {
		return "phase did not complete"
	}
	return fmt.Sprintf("exit status %d", p.status)
}
