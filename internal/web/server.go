// Package web serves the public, read-only simulator experience.
package web

import (
	"embed"
	"encoding/json"
	"errors"
	"html/template"
	"io/fs"
	"net/http"
	"sort"
	"time"

	"github.com/jakedgy/teamwork-cloud/internal/health"
)

//go:embed templates/*.html static/*
var assets embed.FS

// Snapshotter supplies the latest dependency states.
type Snapshotter interface {
	Snapshot() []health.Result
}

// Metadata identifies the lab deployment shown in the simulator.
type Metadata struct {
	ClusterName string `json:"clusterName"`
	AWSRegion   string `json:"awsRegion"`
}

type page struct {
	Title    string
	Active   string
	Metadata Metadata
}

type healthEnvelope struct {
	Cluster   string          `json:"cluster"`
	Region    string          `json:"region"`
	CheckedAt time.Time       `json:"checkedAt"`
	Services  []health.Result `json:"services"`
}

// New creates the complete simulator HTTP handler from embedded assets.
func New(snapshotter Snapshotter, metadata Metadata) (http.Handler, error) {
	if snapshotter == nil {
		return nil, errors.New("health snapshotter must not be nil")
	}

	pages := map[string]*template.Template{}
	for _, name := range []string{"webapp", "authentication", "admin", "license"} {
		parsed, err := template.ParseFS(assets, "templates/layout.html", "templates/"+name+".html")
		if err != nil {
			return nil, errors.New("initialize web templates")
		}
		pages[name] = parsed
	}
	staticFiles, err := fs.Sub(assets, "static")
	if err != nil {
		return nil, errors.New("initialize static assets")
	}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /{$}", func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, "/webapp", http.StatusFound)
	})
	render := func(name, title, active string) http.HandlerFunc {
		return func(w http.ResponseWriter, _ *http.Request) {
			w.Header().Set("Content-Type", "text/html; charset=utf-8")
			if err := pages[name].ExecuteTemplate(w, "layout", page{Title: title, Active: active, Metadata: metadata}); err != nil {
				return
			}
		}
	}
	mux.HandleFunc("GET /webapp", render("webapp", "Deployment Lab", "webapp"))
	mux.HandleFunc("GET /authentication", render("authentication", "Authentication", "authentication"))
	mux.HandleFunc("GET /admin", render("admin", "Administration", "admin"))
	mux.HandleFunc("GET /admin/license", render("license", "License", "license"))
	mux.Handle("GET /static/", http.StripPrefix("/static/", http.FileServer(http.FS(staticFiles))))
	mux.HandleFunc("GET /api/health", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		results := append([]health.Result(nil), snapshotter.Snapshot()...)
		for index := range results {
			results[index].Error = safeResultError(results[index].Error)
		}
		sort.Slice(results, func(i, j int) bool { return results[i].Name < results[j].Name })
		var checkedAt time.Time
		for _, result := range results {
			if result.CheckedAt.After(checkedAt) {
				checkedAt = result.CheckedAt
			}
		}
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		_ = json.NewEncoder(w).Encode(healthEnvelope{
			Cluster: metadata.ClusterName, Region: metadata.AWSRegion,
			CheckedAt: checkedAt, Services: results,
		})
	})
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok\n"))
	})
	mux.HandleFunc("GET /readyz", func(w http.ResponseWriter, _ *http.Request) {
		results := snapshotter.Snapshot()
		if len(results) == 0 {
			http.Error(w, "not ready", http.StatusServiceUnavailable)
			return
		}
		for _, result := range results {
			if result.CheckedAt.IsZero() {
				http.Error(w, "not ready", http.StatusServiceUnavailable)
				return
			}
		}
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		_, _ = w.Write([]byte("ok\n"))
	})

	return securityHeaders(mux), nil
}

func safeResultError(value string) string {
	switch value {
	case "", "check failed", "check timed out", "check canceled":
		return value
	default:
		return "check failed"
	}
}

func securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Security-Policy", "default-src 'self'")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Referrer-Policy", "no-referrer")
		next.ServeHTTP(w, r)
	})
}
