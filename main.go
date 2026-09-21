package main

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"
	"sync"
	"time"

	"github.com/robfig/cron/v3"
)

func timestampedPrint(prefix, message string) {
	timestamp := time.Now().Format("2006-01-02 15:04:05")
	fmt.Printf("[%s] %s: %s", timestamp, prefix, message)
}

func streamOutput(prefix string, reader io.Reader) {
	scanner := bufio.NewScanner(reader)
	for scanner.Scan() {
		timestampedPrint(prefix, scanner.Text()+"\n")
	}
	if err := scanner.Err(); err != nil {
		timestampedPrint("ERROR", fmt.Sprintf("Error reading output: %v\n", err))
	}
}

func validateSchedule(schedule string) error {
	// Handle @every syntax
	if strings.HasPrefix(schedule, "@every ") {
		duration := strings.TrimPrefix(schedule, "@every ")
		_, err := time.ParseDuration(duration)
		return err
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

	c := cron.New()
	var mu sync.Mutex

	_, err = c.AddFunc(schedule, func() {
		if !mu.TryLock() {
			timestampedPrint("WARN", "Previous command still running; skipping this run\n")
			return
		}
		defer mu.Unlock()

		timestampedPrint("INFO", fmt.Sprintf("Executing command: %s %v\n", command, args))

		ctx := context.Background()
		var cancel context.CancelFunc
		if timeout > 0 {
			ctx, cancel = context.WithTimeout(context.Background(), timeout)
			defer cancel()
		}

		cmd := exec.CommandContext(ctx, command, args...)

		stdout, err := cmd.StdoutPipe()
		if err != nil {
			timestampedPrint("ERROR", fmt.Sprintf("Error creating stdout pipe: %v\n", err))
			return
		}

		stderr, err := cmd.StderrPipe()
		if err != nil {
			timestampedPrint("ERROR", fmt.Sprintf("Error creating stderr pipe: %v\n", err))
			return
		}

		err = cmd.Start()
		if err != nil {
			timestampedPrint("ERROR", fmt.Sprintf("Error starting command: %v\n", err))
			return
		}

		go streamOutput("STDOUT", stdout)
		go streamOutput("STDERR", stderr)

		err = cmd.Wait()
		if err != nil {
			if timeout > 0 && ctx.Err() == context.DeadlineExceeded {
				timestampedPrint("ERROR", fmt.Sprintf("Command timed out after %s\n", timeout))
			} else {
				timestampedPrint("ERROR", fmt.Sprintf("Command finished with error: %v\n", err))
			}
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

	c.Run()
}
