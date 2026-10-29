// Package server holds the HTTP routes and security middleware.
package server

import (
	"encoding/json"
	"log/slog"
	"net/http"

	"github.com/example/devsecops-home-test/app/internal/store"
)

const maxRequestBody = 1 << 20 // 1 MiB

// New returns the API handler with security headers applied to every response.
func New(st store.Store, logger *slog.Logger) http.Handler {
	mux := http.NewServeMux()

	// Health check for the ALB target group. It must not depend on the database,
	// so a database outage does not take every task out of service at once.
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	})

	mux.HandleFunc("GET /api/v1/items", func(w http.ResponseWriter, r *http.Request) {
		items, err := st.ListItems(r.Context())
		if err != nil {
			// Log the detail server-side; never return internal errors to the client.
			logger.Error("list items", "error", err)
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "internal error"})
			return
		}
		writeJSON(w, http.StatusOK, items)
	})

	return securityHeaders(http.MaxBytesHandler(mux, maxRequestBody))
}

func securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := w.Header()
		h.Set("Content-Security-Policy", "default-src 'none'; frame-ancestors 'none'")
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("X-Frame-Options", "DENY")
		h.Set("Referrer-Policy", "no-referrer")
		h.Set("Cache-Control", "no-store")
		// TLS terminates at the ALB, which only listens on HTTPS.
		h.Set("Strict-Transport-Security", "max-age=31536000; includeSubDomains")
		next.ServeHTTP(w, r)
	})
}

func writeJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}
