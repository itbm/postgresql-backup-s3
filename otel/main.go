// Command go-cron is go-cron with OpenTelemetry traces, metrics and logs.
package main

import (
	"os"

	"github.com/itbm/postgresql-backup-s3/internal/gocron"
)

// version is set at build time with -ldflags "-X main.version=...".
var version = "dev"

func main() {
	os.Exit(gocron.Main(os.Args[1:], newTelemetry))
}
