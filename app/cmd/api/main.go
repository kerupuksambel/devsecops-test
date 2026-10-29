// Command api is a minimal backend API used as the target of the security pipeline.
package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/example/devsecops-home-test/app/internal/database"
	"github.com/example/devsecops-home-test/app/internal/server"
	"github.com/example/devsecops-home-test/app/internal/store"
)

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	if err := run(logger); err != nil {
		logger.Error("api stopped", "error", err)
		os.Exit(1)
	}
}

func run(logger *slog.Logger) error {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	// Without DB_HOST the API serves fixed sample data. CI uses this mode for DAST,
	// so no database or credentials are needed outside AWS.
	var st store.Store = store.NewMemory()
	if os.Getenv("DB_HOST") != "" {
		cfg, err := database.ConfigFromEnv()
		if err != nil {
			return err
		}
		pool, err := database.NewPool(ctx, cfg)
		if err != nil {
			return err
		}
		defer pool.Close()
		st = store.NewPostgres(pool)
		logger.Info("using PostgreSQL store with IAM database authentication", "host", cfg.Host, "user", cfg.User)
	}

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	srv := &http.Server{
		Addr:              ":" + port,
		Handler:           server.New(st, logger),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      10 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	errCh := make(chan error, 1)
	go func() {
		logger.Info("listening", "addr", srv.Addr)
		errCh <- srv.ListenAndServe()
	}()

	select {
	case err := <-errCh:
		if !errors.Is(err, http.ErrServerClosed) {
			return err
		}
		return nil
	case <-ctx.Done():
	}

	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	return srv.Shutdown(shutdownCtx)
}
