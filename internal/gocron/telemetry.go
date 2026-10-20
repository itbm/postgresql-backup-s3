package gocron

import (
	"path/filepath"
	"strings"
	"time"
)

// TelemetryFileEnv names the per-run report file that telemetry gives the
// command. go-cron never passes on a value inherited from its own environment.
const TelemetryFileEnv = "PGBACKUP_TELEMETRY_FILE"

// Trigger says what started a run.
type Trigger string

const (
	TriggerSchedule Trigger = "schedule"
	TriggerOnce     Trigger = "once"
	TriggerStart    Trigger = "start"
)

// Outcome classifies how a run ended.
type Outcome string

const (
	OutcomeSuccess   Outcome = "success"
	OutcomeFailure   Outcome = "failure"
	OutcomeTimeout   Outcome = "timeout"
	OutcomeCancelled Outcome = "cancelled"
)

// RunInfo describes a run of the command.
type RunInfo struct {
	Command  string
	Args     []string
	Trigger  Trigger
	Schedule string // empty for --once
	Timeout  time.Duration
}

// Operation names what the run does: the script name without its .sh
// extension ("backup" for /bin/sh backup.sh), or the command name.
func (r RunInfo) Operation() string {
	name := r.Command
	if len(r.Args) > 0 {
		name = r.Args[len(r.Args)-1]
	}
	return strings.TrimSuffix(filepath.Base(name), ".sh")
}

// Result is how a run ended.
type Result struct {
	Outcome  Outcome
	ExitCode int   // the exit code go-cron --once returns
	Err      error // nil on success
	Started  time.Time
	Ended    time.Time
}

// Printer prints a timestamped go-cron message without passing it to
// telemetry. message has no trailing newline.
type Printer func(severity, message string)

// Telemetry receives go-cron's lifecycle events. Implementations must be safe
// for concurrent use; Run.Line is called from the output-copying goroutines.
type Telemetry interface {
	// Log is called for each go-cron message after it is printed. severity is
	// INFO, WARN or ERROR; message has no trailing newline.
	Log(severity, message string)
	// Scheduled is called once in scheduled mode. next returns the time of
	// the next scheduled run.
	Scheduled(info RunInfo, next func() time.Time)
	// Skipped is called when a scheduled run is skipped because the
	// previous one is still running.
	Skipped(info RunInfo)
	// StartRun is called just before the command starts.
	StartRun(info RunInfo) Run
	// Shutdown flushes telemetry before go-cron exits. It must return within
	// a bounded time.
	Shutdown()
}

// Run receives the events of a single run.
type Run interface {
	// Env returns the command's environment, given go-cron's own
	// environment without reserved variables.
	Env(base []string) []string
	// WantsOutput reports whether Line should be called. When it is false,
	// --once passes the command go-cron's own stdout and stderr.
	WantsOutput() bool
	// Line is called for each line of output, without the newline. stream is
	// "stdout" or "stderr".
	Line(stream, line string)
	// TraceID returns the run's trace ID, or "" when there is none.
	TraceID() string
	// End is called once, after the command has finished.
	End(res Result)
}

// NoTelemetry is the Telemetry used when none is configured.
type NoTelemetry struct{}

func (NoTelemetry) Log(string, string)                  {}
func (NoTelemetry) Scheduled(RunInfo, func() time.Time) {}
func (NoTelemetry) Skipped(RunInfo)                     {}
func (NoTelemetry) StartRun(RunInfo) Run                { return noRun{} }
func (NoTelemetry) Shutdown()                           {}

type noRun struct{}

func (noRun) Env(base []string) []string { return base }
func (noRun) WantsOutput() bool          { return false }
func (noRun) Line(string, string)        {}
func (noRun) TraceID() string            { return "" }
func (noRun) End(Result)                 {}
