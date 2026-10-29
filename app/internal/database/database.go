// Package database opens the PostgreSQL pool using IAM database authentication.
//
// The app has no database password. For every new connection it signs a
// 15-minute token with its ECS task-role credentials (rds-db:connect on app_user).
package database

import (
	"context"
	"errors"
	"fmt"
	"net"
	"os"
	"strconv"

	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/feature/rds/auth"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// Config holds non-secret connection settings, all supplied as environment variables.
type Config struct {
	Host        string
	Port        int
	Name        string
	User        string
	Region      string
	SSLRootCert string // RDS CA bundle, required for sslmode=verify-full
}

// ConfigFromEnv reads DB_HOST, DB_PORT, DB_NAME, DB_USER, AWS_REGION and DB_SSL_ROOT_CERT.
func ConfigFromEnv() (Config, error) {
	cfg := Config{
		Host:        os.Getenv("DB_HOST"),
		Name:        os.Getenv("DB_NAME"),
		User:        os.Getenv("DB_USER"),
		Region:      os.Getenv("AWS_REGION"),
		SSLRootCert: os.Getenv("DB_SSL_ROOT_CERT"),
		Port:        5432,
	}
	if p := os.Getenv("DB_PORT"); p != "" {
		port, err := strconv.Atoi(p)
		if err != nil {
			return Config{}, fmt.Errorf("invalid DB_PORT: %w", err)
		}
		cfg.Port = port
	}
	if cfg.Host == "" || cfg.Name == "" || cfg.User == "" || cfg.Region == "" || cfg.SSLRootCert == "" {
		return Config{}, errors.New("DB_HOST, DB_NAME, DB_USER, AWS_REGION and DB_SSL_ROOT_CERT are required")
	}
	return cfg, nil
}

// NewPool returns a pool whose connections authenticate with fresh IAM tokens over verified TLS.
func NewPool(ctx context.Context, cfg Config) (*pgxpool.Pool, error) {
	awsCfg, err := config.LoadDefaultConfig(ctx, config.WithRegion(cfg.Region))
	if err != nil {
		return nil, fmt.Errorf("load AWS config: %w", err)
	}

	dsn := fmt.Sprintf("host=%s port=%d dbname=%s user=%s sslmode=verify-full sslrootcert=%s",
		cfg.Host, cfg.Port, cfg.Name, cfg.User, cfg.SSLRootCert)
	poolCfg, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		return nil, fmt.Errorf("parse database config: %w", err)
	}

	endpoint := net.JoinHostPort(cfg.Host, strconv.Itoa(cfg.Port))
	poolCfg.BeforeConnect = func(ctx context.Context, cc *pgx.ConnConfig) error {
		token, err := auth.BuildAuthToken(ctx, endpoint, cfg.Region, cfg.User, awsCfg.Credentials)
		if err != nil {
			return fmt.Errorf("build IAM auth token: %w", err)
		}
		cc.Password = token
		return nil
	}

	return pgxpool.NewWithConfig(ctx, poolCfg)
}
