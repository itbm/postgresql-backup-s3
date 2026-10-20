package gocron

import (
	"context"
	"os"
	"strings"
	"sync"
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

// captureWriter is safe for the two output-copying goroutines exec runs.
type captureWriter struct {
	mu sync.Mutex
	sb strings.Builder
}

func (w *captureWriter) Write(p []byte) (int, error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.sb.Write(p)
}

func (w *captureWriter) String() string {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.sb.String()
}

func sh(script string) (string, []string) {
	return "/bin/sh", []string{"-c", script}
}

func TestRunCommandCapturesAllOutput(t *testing.T) {
	var out, errOut captureWriter
	cmd, args := sh("i=0; while [ $i -lt 500 ]; do echo line$i; i=$((i+1)); done; printf tail; echo oops >&2")
	res := runCommand(context.Background(), cmd, args, nil, 0, time.Second, &out, &errOut)
	if res.Err != nil || res.Outcome != OutcomeSuccess || res.ExitCode != 0 {
		t.Fatalf("runCommand = %+v", res)
	}
	if !strings.HasSuffix(out.String(), "line499\ntail") {
		t.Errorf("stdout missing trailing output: %q", out.String()[max(0, len(out.String())-40):])
	}
	if errOut.String() != "oops\n" {
		t.Errorf("stderr = %q, want %q", errOut.String(), "oops\n")
	}
	if !res.Ended.After(res.Started) {
		t.Errorf("Ended %v is not after Started %v", res.Ended, res.Started)
	}
}

func TestRunCommandPassesEnv(t *testing.T) {
	var out captureWriter
	cmd, args := sh(`printf '%s' "$GOCRON_TEST_VAR"`)
	res := runCommand(context.Background(), cmd, args, []string{"GOCRON_TEST_VAR=hello"}, 0, time.Second, &out, &out)
	if res.Err != nil || out.String() != "hello" {
		t.Fatalf("runCommand = %+v, output %q", res, out.String())
	}
}

func TestRunCommandTimeoutKillsProcessGroup(t *testing.T) {
	var out captureWriter
	start := time.Now()
	// The pipeline's children keep stdout open; only a process-group kill ends them quickly.
	cmd, args := sh("sleep 60 | cat; echo done")
	res := runCommand(context.Background(), cmd, args, nil, 500*time.Millisecond, 2*time.Second, &out, &out)
	elapsed := time.Since(start)
	if res.Outcome != OutcomeTimeout || res.Err == nil || !strings.Contains(res.Err.Error(), "timed out") {
		t.Fatalf("result = %+v, want timeout", res)
	}
	if res.ExitCode != 143 {
		t.Errorf("ExitCode = %d, want 143", res.ExitCode)
	}
	if elapsed > 5*time.Second {
		t.Fatalf("runCommand took %s; children were not killed", elapsed)
	}
}

func TestRunCommandShutdownRunsTrap(t *testing.T) {
	var out captureWriter
	ctx, cancel := context.WithCancel(context.Background())
	time.AfterFunc(300*time.Millisecond, cancel)
	cmd, args := sh("trap 'echo cleaned; exit 143' TERM; sleep 60 & wait")
	res := runCommand(ctx, cmd, args, nil, 0, 5*time.Second, &out, &out)
	if res.Outcome != OutcomeCancelled || res.Err == nil || !strings.Contains(res.Err.Error(), "shutdown") {
		t.Fatalf("result = %+v, want shutdown", res)
	}
	if res.ExitCode != 143 {
		t.Errorf("ExitCode = %d, want 143", res.ExitCode)
	}
	if !strings.Contains(out.String(), "cleaned") {
		t.Errorf("TERM trap did not run; output %q", out.String())
	}
}

// A process the command leaves behind can keep the output pipe open after
// the command exits 0. That must not turn a successful run into a failure.
func TestRunCommandSuccessWithOutputHeldOpen(t *testing.T) {
	old := waitDelayMargin
	waitDelayMargin = 200 * time.Millisecond
	defer func() { waitDelayMargin = old }()

	var lines []string
	w := &lineWriter{emit: func(l string) { lines = append(lines, l) }}
	cmd, args := sh("(sleep 5) & echo started; exit 0")
	res := runCommand(context.Background(), cmd, args, nil, 0, 100*time.Millisecond, w, w)
	if res.Outcome != OutcomeSuccess || res.ExitCode != 0 || res.Err != nil {
		t.Fatalf("result = %+v, want success", res)
	}
	if len(lines) != 1 || lines[0] != "started" {
		t.Errorf("lines = %q", lines)
	}
}

func TestExitCodes(t *testing.T) {
	var out captureWriter
	cases := []struct {
		command string
		args    []string
		want    int
		outcome Outcome
	}{
		{"/bin/sh", []string{"-c", "exit 0"}, 0, OutcomeSuccess},
		{"/bin/sh", []string{"-c", "exit 3"}, 3, OutcomeFailure},
		{"/bin/sh", []string{"-c", "kill -KILL $$"}, 137, OutcomeFailure},
		{"/nonexistent/command", nil, 1, OutcomeFailure},
	}
	for _, c := range cases {
		res := runCommand(context.Background(), c.command, c.args, nil, 0, time.Second, &out, &out)
		if res.ExitCode != c.want || res.Outcome != c.outcome {
			t.Errorf("%s %q: exit %d outcome %s, want %d %s", c.command, c.args, res.ExitCode, res.Outcome, c.want, c.outcome)
		}
	}
}

func TestLineWriter(t *testing.T) {
	var lines []string
	w := &lineWriter{emit: func(l string) { lines = append(lines, l) }}
	if _, err := w.Write([]byte("a\r\nb")); err != nil {
		t.Fatal(err)
	}
	if len(lines) != 1 || lines[0] != "a\r" || string(w.buf) != "b" {
		t.Errorf("lines %q, buffered %q", lines, w.buf)
	}
	w.Flush()
	if len(w.buf) != 0 || len(lines) != 2 || lines[1] != "b" {
		t.Errorf("after Flush: lines %q, buffered %q", lines, w.buf)
	}
}

func TestLineWriterSplitsLongLines(t *testing.T) {
	var lines []string
	w := &lineWriter{emit: func(l string) { lines = append(lines, l) }}
	long := strings.Repeat("x", maxLineBytes*2+10)
	if _, err := w.Write([]byte(long + "\nend\n")); err != nil {
		t.Fatal(err)
	}
	if len(lines) != 4 {
		t.Fatalf("got %d lines, want 4", len(lines))
	}
	if len(lines[0]) != maxLineBytes || len(lines[1]) != maxLineBytes || len(lines[2]) != 10 || lines[3] != "end" {
		t.Errorf("line lengths %d %d %d, last %q", len(lines[0]), len(lines[1]), len(lines[2]), lines[3])
	}
}

func TestChildEnvDropsReservedVariables(t *testing.T) {
	t.Setenv(TelemetryFileEnv, "/tmp/inherited")
	t.Setenv("GOCRON_TEST_KEEP", "yes")
	env := childEnv()
	joined := "\n" + strings.Join(env, "\n") + "\n"
	if strings.Contains(joined, "\n"+TelemetryFileEnv+"=") {
		t.Errorf("childEnv kept %s", TelemetryFileEnv)
	}
	if !strings.Contains(joined, "\nGOCRON_TEST_KEEP=yes\n") {
		t.Errorf("childEnv dropped an ordinary variable")
	}
}

func TestOperation(t *testing.T) {
	cases := []struct {
		info RunInfo
		want string
	}{
		{RunInfo{Command: "/bin/sh", Args: []string{"backup.sh"}}, "backup"},
		{RunInfo{Command: "/bin/sh", Args: []string{"/restore.sh"}}, "restore"},
		{RunInfo{Command: "/usr/bin/true"}, "true"},
	}
	for _, c := range cases {
		if got := c.info.Operation(); got != c.want {
			t.Errorf("Operation(%+v) = %q, want %q", c.info, got, c.want)
		}
	}
}

// fakeTelemetry records the events go-cron reports.
type fakeTelemetry struct {
	mu       sync.Mutex
	wantOut  bool
	events   []string
	lines    []string
	results  []Result
	shutdown int
}

func (f *fakeTelemetry) record(e string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.events = append(f.events, e)
}

func (f *fakeTelemetry) Log(severity, message string)        { f.record("log " + severity + " " + message) }
func (f *fakeTelemetry) Scheduled(RunInfo, func() time.Time) { f.record("scheduled") }
func (f *fakeTelemetry) Skipped(info RunInfo)                { f.record("skipped " + string(info.Trigger)) }
func (f *fakeTelemetry) StartRun(info RunInfo) Run {
	f.record("start " + string(info.Trigger) + " " + info.Operation())
	return &fakeRun{f}
}
func (f *fakeTelemetry) Shutdown() {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.shutdown++
}

type fakeRun struct{ f *fakeTelemetry }

func (r *fakeRun) Env(base []string) []string { return append(base, "GOCRON_TEST_RUN=1") }
func (r *fakeRun) WantsOutput() bool          { return r.f.wantOut }
func (r *fakeRun) Line(stream, line string) {
	r.f.mu.Lock()
	defer r.f.mu.Unlock()
	r.f.lines = append(r.f.lines, stream+": "+line)
}
func (r *fakeRun) TraceID() string { return "0123456789abcdef0123456789abcdef" }
func (r *fakeRun) End(res Result) {
	r.f.mu.Lock()
	defer r.f.mu.Unlock()
	r.f.results = append(r.f.results, res)
}

func writeScript(t *testing.T, body string) string {
	t.Helper()
	path := t.TempDir() + "/job.sh"
	if err := os.WriteFile(path, []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestScheduledRunReportsToTelemetry(t *testing.T) {
	script := writeScript(t, "echo \"run=$GOCRON_TEST_RUN\"\necho warning >&2\nexit 4\n")
	f := &fakeTelemetry{}
	var out captureWriter
	a := &app{out: &out, tel: f}
	var mu sync.Mutex
	a.scheduledRun(context.Background(), &mu, RunInfo{Command: "/bin/sh", Args: []string{script}, Trigger: TriggerSchedule})

	if len(f.results) != 1 || f.results[0].ExitCode != 4 || f.results[0].Outcome != OutcomeFailure {
		t.Fatalf("results = %+v", f.results)
	}
	if strings.Join(f.lines, "|") != "stdout: run=1|stderr: warning" && strings.Join(f.lines, "|") != "stderr: warning|stdout: run=1" {
		t.Errorf("lines = %q", f.lines)
	}
	if !strings.Contains(out.String(), "] STDOUT: run=1\n") || !strings.Contains(out.String(), "(trace_id=0123456789abcdef0123456789abcdef)") {
		t.Errorf("output = %q", out.String())
	}
	if f.events[0] != "log INFO Executing command: /bin/sh ["+script+"]" || f.events[1] != "start schedule job" {
		t.Errorf("events = %q", f.events)
	}

	mu.Lock()
	a.scheduledRun(context.Background(), &mu, RunInfo{Command: "/bin/sh", Args: []string{script}, Trigger: TriggerSchedule})
	mu.Unlock()
	if last := f.events[len(f.events)-1]; last != "skipped schedule" {
		t.Errorf("last event = %q, want skipped", last)
	}
}

func TestRunOnceTeesOutputOnlyWhenWanted(t *testing.T) {
	script := writeScript(t, "echo \"run=$GOCRON_TEST_RUN\"\nexit 2\n")
	for _, want := range []bool{false, true} {
		f := &fakeTelemetry{wantOut: want}
		var out captureWriter
		a := &app{out: &out, tel: f}
		if code := a.runOnce("/bin/sh", []string{script}); code != 2 {
			t.Errorf("wantOut=%v: exit code %d, want 2", want, code)
		}
		if f.shutdown != 1 || len(f.results) != 1 {
			t.Errorf("wantOut=%v: shutdown %d, results %d", want, f.shutdown, len(f.results))
		}
		if want && (len(f.lines) != 1 || f.lines[0] != "stdout: run=1") {
			t.Errorf("wantOut=true: lines = %q", f.lines)
		}
		if !want && len(f.lines) != 0 {
			t.Errorf("wantOut=false: lines = %q", f.lines)
		}
		if !strings.Contains(out.String(), "Command finished with exit code 2 (trace_id=") {
			t.Errorf("wantOut=%v: output = %q", want, out.String())
		}
	}
}
