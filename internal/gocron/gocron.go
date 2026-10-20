// Package gocron runs a command on a cron schedule, or once, in its own
// process group, and reports each run to an optional Telemetry.
package gocron

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/robfig/cron/v3"
)

// killGrace is how long a command gets to exit after SIGTERM before its
// whole process group is sent SIGKILL.
const killGrace = 30 * time.Second

// waitDelayMargin is how much longer than the kill grace Wait may block on
// output pipes held open by orphaned children.
var waitDelayMargin = 5 * time.Second

// maxLineBytes caps one line of command output; longer lines are split.
const maxLineBytes = 64 * 1024

var outputMu sync.Mutex

func printTo(w io.Writer, prefix, message string) {
	timestamp := time.Now().Format("2006-01-02 15:04:05")
	outputMu.Lock()
	defer outputMu.Unlock()
	fmt.Fprintf(w, "[%s] %s: %s", timestamp, prefix, message)
}

func timestampedPrint(prefix, message string) {
	printTo(os.Stdout, prefix, message)
}

// lineWriter passes each complete line it receives, without the newline, to
// emit. Lines longer than maxLineBytes are split. Passing it (or a teeWriter)
// as cmd.Stdout/cmd.Stderr lets exec copy the output and makes cmd.Wait
// return only after all output has been handled.
type lineWriter struct {
	emit func(line string)
	buf  []byte
}

func (w *lineWriter) Write(p []byte) (int, error) {
	w.buf = append(w.buf, p...)
	for {
		// Look for a newline only where it would end a line of at most maxLineBytes.
		i := bytes.IndexByte(w.buf[:min(len(w.buf), maxLineBytes+1)], '\n')
		if i >= 0 {
			w.emit(string(w.buf[:i]))
			w.buf = w.buf[i+1:]
			continue
		}
		if len(w.buf) < maxLineBytes {
			break
		}
		w.emit(string(w.buf[:maxLineBytes]))
		w.buf = w.buf[maxLineBytes:]
	}
	return len(p), nil
}

// Flush passes on any trailing output that did not end with a newline.
func (w *lineWriter) Flush() {
	if len(w.buf) > 0 {
		w.emit(string(w.buf))
		w.buf = nil
	}
}

// teeWriter writes output through unchanged and also splits it into lines.
type teeWriter struct {
	w     io.Writer
	lines *lineWriter
}

func (t *teeWriter) Write(p []byte) (int, error) {
	n, err := t.w.Write(p)
	_, _ = t.lines.Write(p[:n])
	return n, err
}

func validateSchedule(schedule string) error {
	// Handle @every syntax
	if strings.HasPrefix(schedule, "@every ") {
		duration := strings.TrimPrefix(schedule, "@every ")
		d, err := time.ParseDuration(duration)
		if err != nil {
			return err
		}
		if d <= 0 {
			return fmt.Errorf("@every duration must be positive")
		}
		return nil
	}

	// Handle standard cron syntax and descriptors
	parser := cron.NewParser(cron.Minute | cron.Hour | cron.Dom | cron.Month | cron.Dow | cron.Descriptor)

	_, err := parser.Parse(schedule)
	return err
}

func commandTimeout() (time.Duration, error) {
	raw := strings.TrimSpace(os.Getenv("COMMAND_TIMEOUT"))
	if raw == "" || raw == "0" || raw == "**None**" {
		return 0, nil
	}
	d, err := time.ParseDuration(raw)
	if err != nil {
		return 0, fmt.Errorf("invalid COMMAND_TIMEOUT %q: %w", raw, err)
	}
	if d < 0 {
		return 0, fmt.Errorf("invalid COMMAND_TIMEOUT %q: must be >= 0", raw)
	}
	return d, nil
}

// childEnv returns go-cron's environment without the variables reserved for
// go-cron itself.
func childEnv() []string {
	var env []string
	for _, kv := range os.Environ() {
		if strings.HasPrefix(kv, TelemetryFileEnv+"=") {
			continue
		}
		env = append(env, kv)
	}
	return env
}

// runCommand runs command in its own process group with the environment env.
// When ctx is cancelled or the timeout expires, the whole group gets SIGTERM
// and, after grace, SIGKILL, so child processes such as pg_dump and aws
// cannot outlive the command.
func runCommand(ctx context.Context, command string, args, env []string, timeout, grace time.Duration, stdout, stderr io.Writer) Result {
	runCtx := ctx
	if timeout > 0 {
		var cancel context.CancelFunc
		runCtx, cancel = context.WithTimeout(ctx, timeout)
		defer cancel()
	}

	cmd := exec.CommandContext(runCtx, command, args...)
	cmd.Env = env
	cmd.Stdout = stdout
	cmd.Stderr = stderr
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}

	var killTimer *time.Timer
	var timerMu sync.Mutex
	cmd.Cancel = func() error {
		pgid := cmd.Process.Pid
		err := syscall.Kill(-pgid, syscall.SIGTERM)
		timerMu.Lock()
		killTimer = time.AfterFunc(grace, func() {
			_ = syscall.Kill(-pgid, syscall.SIGKILL)
		})
		timerMu.Unlock()
		return err
	}
	// Bound how long Wait blocks on output pipes held open by orphaned children.
	cmd.WaitDelay = grace + waitDelayMargin

	res := Result{Started: time.Now()}
	err := cmd.Run()
	res.Ended = time.Now()

	timerMu.Lock()
	if killTimer != nil {
		killTimer.Stop()
	}
	timerMu.Unlock()

	state := cmd.ProcessState
	switch {
	case err != nil && ctx.Err() != nil:
		res.Outcome = OutcomeCancelled
		res.Err = fmt.Errorf("command stopped by shutdown: %w", err)
	case err != nil && errors.Is(runCtx.Err(), context.DeadlineExceeded):
		res.Outcome = OutcomeTimeout
		res.Err = fmt.Errorf("command timed out after %s: %w", timeout, err)
	case state != nil && state.Success():
		// Wait returns ErrWaitDelay when the command succeeded but a process
		// it started kept the output open; the command still succeeded.
		res.Outcome = OutcomeSuccess
	case err != nil:
		res.Outcome = OutcomeFailure
		res.Err = err
	default:
		res.Outcome = OutcomeSuccess
	}
	if res.Outcome != OutcomeSuccess {
		res.ExitCode = exitStatus(state)
	}
	return res
}

// exitStatus maps a finished process to the exit code go-cron --once returns:
// its exit code, 128+N when killed by signal N, or 1 when it did not start
// or exited 0 after being stopped.
func exitStatus(state *os.ProcessState) int {
	if state == nil {
		return 1
	}
	if status, ok := state.Sys().(syscall.WaitStatus); ok && status.Signaled() {
		return 128 + int(status.Signal())
	}
	if code := state.ExitCode(); code > 0 {
		return code
	}
	return 1
}

const usage = `Usage:
  go-cron [--run-on-start] <schedule> <command> [args...]
  go-cron --once <command> [args...]`

// app holds what a go-cron process shares between runs.
type app struct {
	out io.Writer // where go-cron's own messages go
	tel Telemetry
}

func newApp(out io.Writer, newTelemetry func(Printer) Telemetry) *app {
	a := &app{out: out, tel: NoTelemetry{}}
	if newTelemetry != nil {
		if t := newTelemetry(func(severity, message string) { printTo(out, severity, message+"\n") }); t != nil {
			a.tel = t
		}
	}
	return a
}

// say prints a go-cron message and passes it to telemetry.
func (a *app) say(severity, message string) {
	printTo(a.out, severity, message)
	a.tel.Log(severity, strings.TrimSuffix(message, "\n"))
}

// traceSuffix returns " (trace_id=...)" when the run has a trace.
func traceSuffix(run Run) string {
	if id := run.TraceID(); id != "" {
		return " (trace_id=" + id + ")"
	}
	return ""
}

// runOnce runs command a single time, passing its output through unchanged,
// and forwards SIGTERM/SIGINT to its whole process group.
func (a *app) runOnce(command string, args []string) int {
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()

	run := a.tel.StartRun(RunInfo{Command: command, Args: args, Trigger: TriggerOnce})
	var stdout, stderr io.Writer = os.Stdout, os.Stderr
	var lines []*lineWriter
	if run.WantsOutput() {
		outLines := &lineWriter{emit: func(line string) { run.Line("stdout", line) }}
		errLines := &lineWriter{emit: func(line string) { run.Line("stderr", line) }}
		stdout = &teeWriter{w: os.Stdout, lines: outLines}
		stderr = &teeWriter{w: os.Stderr, lines: errLines}
		lines = []*lineWriter{outLines, errLines}
	}

	res := runCommand(ctx, command, args, run.Env(childEnv()), 0, killGrace, stdout, stderr)
	for _, l := range lines {
		l.Flush()
	}
	if res.Err != nil && res.Outcome == OutcomeCancelled {
		fmt.Fprintf(os.Stderr, "%v\n", res.Err)
	}
	if suffix := traceSuffix(run); suffix != "" {
		a.say("INFO", fmt.Sprintf("Command finished with exit code %d%s\n", res.ExitCode, suffix))
	}
	run.End(res)
	a.tel.Shutdown()
	return res.ExitCode
}

// scheduledRun is one run of a scheduled command. Runs that would overlap a
// running one are skipped.
func (a *app) scheduledRun(ctx context.Context, mu *sync.Mutex, info RunInfo) {
	if ctx.Err() != nil {
		return
	}
	if !mu.TryLock() {
		a.say("WARN", "Previous command still running; skipping this run\n")
		a.tel.Skipped(info)
		return
	}
	defer mu.Unlock()

	a.say("INFO", fmt.Sprintf("Executing command: %s %v\n", info.Command, info.Args))

	run := a.tel.StartRun(info)
	stdout := &lineWriter{emit: func(line string) {
		printTo(a.out, "STDOUT", line+"\n")
		run.Line("stdout", line)
	}}
	stderr := &lineWriter{emit: func(line string) {
		printTo(a.out, "STDERR", line+"\n")
		run.Line("stderr", line)
	}}
	res := runCommand(ctx, info.Command, info.Args, run.Env(childEnv()), info.Timeout, killGrace, stdout, stderr)
	stdout.Flush()
	stderr.Flush()

	if res.Err != nil {
		a.say("ERROR", fmt.Sprintf("Command finished with error: %v%s\n", res.Err, traceSuffix(run)))
	} else {
		a.say("INFO", "Command finished successfully"+traceSuffix(run)+"\n")
	}
	run.End(res)
}

func (a *app) runScheduled(schedule, command string, args []string, timeout time.Duration, runOnStart bool) int {
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()

	c := cron.New()
	var mu sync.Mutex
	info := RunInfo{Command: command, Args: args, Trigger: TriggerSchedule, Schedule: schedule, Timeout: timeout}

	id, err := c.AddFunc(schedule, func() { a.scheduledRun(ctx, &mu, info) })
	if err != nil {
		a.say("ERROR", fmt.Sprintf("Error adding cron job: %v\n", err))
		return 1
	}
	a.tel.Scheduled(info, func() time.Time { return c.Entry(id).Next })

	a.say("INFO", fmt.Sprintf("Cron job scheduled: %s\n", schedule))
	a.say("INFO", fmt.Sprintf("Command to run: %s %v\n", command, strings.Join(args, " ")))
	if timeout > 0 {
		a.say("INFO", fmt.Sprintf("Command timeout: %s\n", timeout))
	} else {
		a.say("INFO", "Command timeout: disabled\n")
	}

	c.Start()
	if runOnStart {
		a.say("INFO", "Running command once before the first scheduled run\n")
		startInfo := info
		startInfo.Trigger = TriggerStart
		go a.scheduledRun(ctx, &mu, startInfo)
	}
	<-ctx.Done()
	stop()

	a.say("INFO", "Shutdown signal received; waiting for any running command to stop\n")
	<-c.Stop().Done()
	// Also wait for a run started by --run-on-start, which cron does not track.
	mu.Lock()
	a.say("INFO", "Shutdown complete\n")
	a.tel.Shutdown()
	return 0
}

// Main runs go-cron with args (without the program name) and returns the
// process exit code. newTelemetry, when not nil, is called once the mode is
// known, with a Printer that writes go-cron messages to the right stream:
// stdout in scheduled mode and stderr with --once.
func Main(args []string, newTelemetry func(Printer) Telemetry) int {
	argv := args
	once := false
	runOnStart := false
	for len(argv) > 0 && strings.HasPrefix(argv[0], "--") {
		switch argv[0] {
		case "--once":
			once = true
		case "--run-on-start":
			runOnStart = true
		default:
			fmt.Println(usage)
			return 1
		}
		argv = argv[1:]
	}

	if once {
		if len(argv) < 1 || runOnStart {
			fmt.Println(usage)
			return 1
		}
		return newApp(os.Stderr, newTelemetry).runOnce(argv[0], argv[1:])
	}

	if len(argv) < 2 {
		fmt.Println(usage)
		return 1
	}

	schedule := argv[0]
	command := argv[1]
	cmdArgs := argv[2:]

	// Validate schedule
	if err := validateSchedule(schedule); err != nil {
		timestampedPrint("ERROR", fmt.Sprintf("Invalid schedule format: %v\n", err))
		return 1
	}

	// Validate command
	if _, err := exec.LookPath(command); err != nil {
		timestampedPrint("ERROR", fmt.Sprintf("Command not found: %s\n", command))
		return 1
	}

	timeout, err := commandTimeout()
	if err != nil {
		timestampedPrint("ERROR", fmt.Sprintf("%v\n", err))
		return 1
	}

	return newApp(os.Stdout, newTelemetry).runScheduled(schedule, command, cmdArgs, timeout, runOnStart)
}
