package web

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/jakedgy/teamwork-cloud/internal/health"
)

type staticSnapshotter struct {
	results []health.Result
}

func (s staticSnapshotter) Snapshot() []health.Result { return s.results }

func newTestHandler(t *testing.T, results []health.Result) http.Handler {
	t.Helper()
	handler, err := New(staticSnapshotter{results: results}, Metadata{
		ClusterName: "demo-cluster",
		AWSRegion:   "us-east-2",
	})
	if err != nil {
		t.Fatalf("New() error = %v", err)
	}
	return handler
}

func TestRootRedirectsToWebapp(t *testing.T) {
	request := httptest.NewRequest(http.MethodGet, "/", nil)
	recorder := httptest.NewRecorder()
	newTestHandler(t, nil).ServeHTTP(recorder, request)

	if recorder.Code != http.StatusFound {
		t.Fatalf("status = %d, want %d", recorder.Code, http.StatusFound)
	}
	if location := recorder.Header().Get("Location"); location != "/webapp" {
		t.Fatalf("Location = %q, want /webapp", location)
	}
}

func TestSimulatorPagesAreAvailableAndClearlyLabeled(t *testing.T) {
	for _, path := range []string{"/webapp", "/authentication", "/admin", "/admin/license"} {
		t.Run(path, func(t *testing.T) {
			request := httptest.NewRequest(http.MethodGet, path, nil)
			recorder := httptest.NewRecorder()
			newTestHandler(t, nil).ServeHTTP(recorder, request)
			if recorder.Code != http.StatusOK {
				t.Fatalf("status = %d, want %d", recorder.Code, http.StatusOK)
			}
			if !strings.Contains(recorder.Body.String(), "Simulated product layer") {
				t.Fatalf("body does not identify simulation: %s", recorder.Body.String())
			}
			if !strings.Contains(recorder.Header().Get("Content-Type"), "text/html") {
				t.Fatalf("Content-Type = %q", recorder.Header().Get("Content-Type"))
			}
		})
	}
}

func TestLicensePageIsReadOnlyAndExplainsMissingLicense(t *testing.T) {
	request := httptest.NewRequest(http.MethodGet, "/admin/license", nil)
	recorder := httptest.NewRecorder()
	newTestHandler(t, nil).ServeHTTP(recorder, request)
	body := recorder.Body.String()
	for _, text := range []string{"Not activated", "FlexNet", "DSLS"} {
		if !strings.Contains(body, text) {
			t.Errorf("body missing %q", text)
		}
	}
	if strings.Contains(strings.ToLower(body), "<input") {
		t.Fatal("license page contains an input control")
	}
}

func TestHealthAPIIncludesMetadataAndSortedSanitizedResults(t *testing.T) {
	older := time.Date(2026, time.July, 22, 12, 0, 0, 0, time.UTC)
	newer := older.Add(time.Minute)
	handler := newTestHandler(t, []health.Result{
		{Name: "zookeeper", Endpoint: "zookeeper:2181", Status: health.StatusReady, CheckedAt: older},
		{Name: "artemis", Endpoint: "artemis:61616", Status: health.StatusUnavailable, CheckedAt: newer, Error: "password=secret\ngoroutine 19"},
		{Name: "cassandra", Endpoint: "cassandra:9042", Status: health.StatusReady, CheckedAt: older},
	})
	request := httptest.NewRequest(http.MethodGet, "/api/health", nil)
	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, request)

	if recorder.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d", recorder.Code, http.StatusOK)
	}
	var response struct {
		Cluster   string          `json:"cluster"`
		Region    string          `json:"region"`
		CheckedAt time.Time       `json:"checkedAt"`
		Services  []health.Result `json:"services"`
	}
	if err := json.Unmarshal(recorder.Body.Bytes(), &response); err != nil {
		t.Fatalf("decode response: %v; body=%s", err, recorder.Body.String())
	}
	if response.Cluster != "demo-cluster" || response.Region != "us-east-2" {
		t.Fatalf("metadata = %q, %q", response.Cluster, response.Region)
	}
	if !response.CheckedAt.Equal(newer) {
		t.Fatalf("checkedAt = %s, want %s", response.CheckedAt, newer)
	}
	if got := []string{response.Services[0].Name, response.Services[1].Name, response.Services[2].Name}; strings.Join(got, ",") != "artemis,cassandra,zookeeper" {
		t.Fatalf("service order = %v", got)
	}
	if response.Services[0].Error != "check failed" {
		t.Fatalf("error = %q, want sanitized error", response.Services[0].Error)
	}
	if strings.Contains(recorder.Body.String(), "password") || strings.Contains(recorder.Body.String(), "goroutine") {
		t.Fatalf("response leaked credentials or stack details: %s", recorder.Body.String())
	}
}

func TestHealthAPIDoesNotMutateSnapshotterResults(t *testing.T) {
	results := []health.Result{
		{Name: "zookeeper", Error: "private detail"},
		{Name: "artemis"},
	}
	handler := newTestHandler(t, results)
	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, "/api/health", nil))

	if results[0].Name != "zookeeper" || results[0].Error != "private detail" {
		t.Fatalf("source results mutated: %+v", results)
	}
}

func TestHealthzStaysHealthyBeforeFirstDependencyCheck(t *testing.T) {
	handler := newTestHandler(t, []health.Result{{
		Name: "artemis", Status: health.StatusStarting,
	}})
	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, "/healthz", nil))
	if recorder.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d", recorder.Code, http.StatusOK)
	}
}

func TestReadyzReturnsUnavailableBeforeFirstDependencyCheck(t *testing.T) {
	handler := newTestHandler(t, []health.Result{{
		Name: "artemis", Status: health.StatusStarting,
	}})
	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, "/readyz", nil))
	if recorder.Code != http.StatusServiceUnavailable {
		t.Fatalf("status = %d, want %d", recorder.Code, http.StatusServiceUnavailable)
	}
}

func TestReadyzWaitsUntilEveryDependencyHasBeenChecked(t *testing.T) {
	handler := newTestHandler(t, []health.Result{
		{Name: "artemis", Status: health.StatusUnavailable, CheckedAt: time.Now(), Error: "check failed"},
		{Name: "cassandra", Status: health.StatusStarting},
	})
	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, "/readyz", nil))
	if recorder.Code != http.StatusServiceUnavailable {
		t.Fatalf("status = %d, want %d", recorder.Code, http.StatusServiceUnavailable)
	}
}

func TestReadyzStaysHealthyWhenCheckedDependencyIsUnavailable(t *testing.T) {
	handler := newTestHandler(t, []health.Result{{
		Name: "artemis", Status: health.StatusUnavailable, CheckedAt: time.Now(), Error: "password=secret\ngoroutine 12",
	}})
	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, "/readyz", nil))
	if recorder.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d", recorder.Code, http.StatusOK)
	}
	if strings.Contains(recorder.Body.String(), "password") || strings.Contains(recorder.Body.String(), "goroutine") {
		t.Fatalf("readiness response leaked health details: %q", recorder.Body.String())
	}
}

func TestResponsesSetBrowserSecurityHeaders(t *testing.T) {
	for _, path := range []string{"/webapp", "/api/health", "/missing"} {
		recorder := httptest.NewRecorder()
		newTestHandler(t, nil).ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, path, nil))
		if got := recorder.Header().Get("Content-Security-Policy"); got != "default-src 'self'" {
			t.Errorf("%s CSP = %q", path, got)
		}
		if got := recorder.Header().Get("X-Content-Type-Options"); got != "nosniff" {
			t.Errorf("%s X-Content-Type-Options = %q", path, got)
		}
		if got := recorder.Header().Get("Referrer-Policy"); got != "no-referrer" {
			t.Errorf("%s Referrer-Policy = %q", path, got)
		}
	}
}

func TestStaticAssetsAreEmbedded(t *testing.T) {
	for _, path := range []string{"/static/styles.css", "/static/app.js"} {
		recorder := httptest.NewRecorder()
		newTestHandler(t, nil).ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, path, nil))
		if recorder.Code != http.StatusOK || recorder.Body.Len() == 0 {
			t.Fatalf("%s status=%d length=%d", path, recorder.Code, recorder.Body.Len())
		}
	}
}

func TestUnknownRouteReturnsNotFound(t *testing.T) {
	recorder := httptest.NewRecorder()
	newTestHandler(t, nil).ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, "/unknown", nil))
	if recorder.Code != http.StatusNotFound {
		t.Fatalf("status = %d, want %d", recorder.Code, http.StatusNotFound)
	}
}

func TestNewRejectsNilSnapshotter(t *testing.T) {
	if handler, err := New(nil, Metadata{}); err == nil || handler != nil {
		t.Fatalf("New(nil) = %v, %v; want nil handler and error", handler, err)
	}
}
