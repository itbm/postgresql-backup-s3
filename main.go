// Command go-cron runs a command on a cron schedule, or once with --once.
package main

import (
	"os"

	"github.com/itbm/postgresql-backup-s3/internal/gocron"
)

func main() {
	os.Exit(gocron.Main(os.Args[1:], nil))
}
