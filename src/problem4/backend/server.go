package main

import (
	"encoding/json"
	"log/slog"
	"net/http"
	"time"
)

// newHandler returns the API routes. It is kept free of process concerns
// (flags, signals, listeners) so tests can drive it with httptest.
func newHandler(release string, logger *slog.Logger) http.Handler {
	mux := http.NewServeMux()

	// Liveness/readiness for the ALB target group health check. Deliberately
	// dependency-free: a failing downstream must not make the ALB pull every
	// instance at once.
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	})

	// The deploy pipeline's smoke test asserts this equals the commit it
	// rolled out, which proves the new build is the one serving traffic.
	mux.HandleFunc("GET /api/version", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusOK, map[string]string{"release": release})
	})

	return accessLog(logger, mux)
}

func writeJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (r *statusRecorder) WriteHeader(code int) {
	r.status = code
	r.ResponseWriter.WriteHeader(code)
}

func accessLog(logger *slog.Logger, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(rec, r)
		logger.Info("request",
			"method", r.Method,
			"path", r.URL.Path,
			"status", rec.status,
			"duration_ms", time.Since(start).Milliseconds(),
		)
	})
}
