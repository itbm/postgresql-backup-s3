package main

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

var outputMu sync.Mutex

func timestampedPrint(prefix, message string) {
	timestamp := time.Now().Format("2006-01-02 15:04:05")
	outputMu.Lock()
	defer outputMu.Unlock()
	fmt.Printf("[%s] %s: %s", timestamp, prefix, message)
}

// lineWriter prints each complete line it receives with a timestamp and prefix.
// Passing it as cmd.Stdout/cmd.Stderr lets exec copy the output and makes
// cmd.Wait return only after all output has been written.
type lineWriter struct {
	prefix string
	buf    []byte
}

func (w *lineWriter) Write(p []byte) (int, error) {
	w.buf = append(w.buf, p...)
	for {
		i := bytes.IndexByte(w.buf, '\n')
		if i < 0 {
			break
		}
		timestampedPrint(w.prefix, string(w.buf[:i+1]))
		w.buf = w.buf[i+1:]
	}
	return len(p), nil
}

// Flush prints any trailing output that did not end with a newline.
func (w *lineWriter) Flush() {
	if len(w.buf) > 0 {
		timestampedPrint(w.prefix, string(w.buf)+"\n")
		w.buf = nil
	}
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

// runCommand runs command in its own process group. When ctx is cancelled or
// the timeout expires, the whole group gets SIGTERM and, after grace, SIGKILL,
// so child processes such as pg_dump and aws cannot outlive the command.
func runCommand(ctx context.Context, command string, args []string, timeout, grace time.Duration, stdout, stderr io.Writer) error {
	runCtx := ctx
	if timeout > 0 {
		var cancel context.CancelFunc
		runCtx, cancel = context.WithTimeout(ctx, timeout)
		defer cancel()
	}

	cmd := exec.CommandContext(runCtx, command, args...)
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
	cmd.WaitDelay = grace + 5*time.Second

	err := cmd.Run()

	timerMu.Lock()
	if killTimer != nil {
		killTimer.Stop()
	}
	timerMu.Unlock()

	if err != nil && runCtx.Err() != nil {
		if ctx.Err() != nil {
			return fmt.Errorf("command stopped by shutdown: %w", err)
		}
		if errors.Is(runCtx.Err(), context.DeadlineExceeded) {
			return fmt.Errorf("command timed out after %s: %w", timeout, err)
		}
	}
	return err
}

func main() {
	if len(os.Args) < 3 {
		fmt.Println("Usage: go-cron <schedule> <command> [args...]")
		os.Exit(1)
	}

	schedule := os.Args[1]
	command := os.Args[2]
	args := os.Args[3:]

	// Validate schedule
	if err := validateSchedule(schedule); err != nil {
		timestampedPrint("ERROR", fmt.Sprintf("Invalid schedule format: %v\n", err))
		os.Exit(1)
	}

	// Validate command
	if _, err := exec.LookPath(command); err != nil {
		timestampedPrint("ERROR", fmt.Sprintf("Command not found: %s\n", command))
		os.Exit(1)
	}

	timeout, err := commandTimeout()
	if err != nil {
		timestampedPrint("ERROR", fmt.Sprintf("%v\n", err))
		os.Exit(1)
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()

	c := cron.New()
	var mu sync.Mutex

	_, err = c.AddFunc(schedule, func() {
		if ctx.Err() != nil {
			return
		}
		if !mu.TryLock() {
			timestampedPrint("WARN", "Previous command still running; skipping this run\n")
			return
		}
		defer mu.Unlock()

		timestampedPrint("INFO", fmt.Sprintf("Executing command: %s %v\n", command, args))

		stdout := &lineWriter{prefix: "STDOUT"}
		stderr := &lineWriter{prefix: "STDERR"}
		err := runCommand(ctx, command, args, timeout, killGrace, stdout, stderr)
		stdout.Flush()
		stderr.Flush()

		if err != nil {
			timestampedPrint("ERROR", fmt.Sprintf("Command finished with error: %v\n", err))
		} else {
			timestampedPrint("INFO", "Command finished successfully\n")
		}
	})

	if err != nil {
		timestampedPrint("ERROR", fmt.Sprintf("Error adding cron job: %v\n", err))
		os.Exit(1)
	}

	timestampedPrint("INFO", fmt.Sprintf("Cron job scheduled: %s\n", schedule))
	timestampedPrint("INFO", fmt.Sprintf("Command to run: %s %v\n", command, strings.Join(args, " ")))
	if timeout > 0 {
		timestampedPrint("INFO", fmt.Sprintf("Command timeout: %s\n", timeout))
	} else {
		timestampedPrint("INFO", "Command timeout: disabled\n")
	}

	c.Start()
	<-ctx.Done()
	stop()

	timestampedPrint("INFO", "Shutdown signal received; waiting for any running command to stop\n")
	<-c.Stop().Done()
	timestampedPrint("INFO", "Shutdown complete\n")
}
