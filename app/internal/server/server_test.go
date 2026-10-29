package server

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/example/devsecops-home-test/app/internal/store"
)

type failingStore struct{}

func (failingStore) ListItems(context.Context) ([]store.Item, error) {
	return nil, errors.New("connection refused: db.internal:5432")
}

func newTestServer(st store.Store) *httptest.Server {
	return httptest.NewServer(New(st, slog.New(slog.NewTextHandler(io.Discard, nil))))
}

func TestHealthz(t *testing.T) {
	ts := newTestServer(store.NewMemory())
	defer ts.Close()

	resp, err := http.Get(ts.URL + "/healthz")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want 200", resp.StatusCode)
	}
}

func TestListItems(t *testing.T) {
	ts := newTestServer(store.NewMemory())
	defer ts.Close()

	resp, err := http.Get(ts.URL + "/api/v1/items")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()

	var items []store.Item
	if err := json.NewDecoder(resp.Body).Decode(&items); err != nil {
		t.Fatal(err)
	}
	if len(items) == 0 {
		t.Fatal("expected sample items")
	}
}

func TestSecurityHeaders(t *testing.T) {
	ts := newTestServer(store.NewMemory())
	defer ts.Close()

	resp, err := http.Get(ts.URL + "/healthz")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()

	for _, h := range []string{"Content-Security-Policy", "X-Content-Type-Options", "X-Frame-Options", "Cache-Control", "Strict-Transport-Security"} {
		if resp.Header.Get(h) == "" {
			t.Errorf("missing header %s", h)
		}
	}
}

func TestMethodNotAllowed(t *testing.T) {
	ts := newTestServer(store.NewMemory())
	defer ts.Close()

	resp, err := http.Post(ts.URL+"/api/v1/items", "application/json", strings.NewReader("{}"))
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusMethodNotAllowed {
		t.Fatalf("status = %d, want 405", resp.StatusCode)
	}
}

func TestStoreErrorIsNotLeaked(t *testing.T) {
	ts := newTestServer(failingStore{})
	defer ts.Close()

	resp, err := http.Get(ts.URL + "/api/v1/items")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()

	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusInternalServerError {
		t.Fatalf("status = %d, want 500", resp.StatusCode)
	}
	if strings.Contains(string(body), "db.internal") {
		t.Fatalf("internal error leaked to client: %s", body)
	}
}
