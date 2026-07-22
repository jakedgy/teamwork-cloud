package main

import (
	"context"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/jakedgy/teamwork-cloud/internal/config"
)

func TestNewApplicationWiresConfiguredDependencies(t *testing.T) {
	cfg := config.Config{
		CheckTimeout:    time.Second,
		CassandraHost:   "cassandra.example:9042",
		ZooKeeperHost:   "zookeeper.example:2181",
		ArtemisHost:     "artemis.example:61616",
		ArtemisUser:     "artemis",
		ArtemisPassword: "not-for-the-browser",
		ClusterName:     "cluster-a",
		AWSRegion:       "us-west-2",
	}

	handler, monitor, err := newApplication(cfg)
	if err != nil {
		t.Fatalf("newApplication() error = %v", err)
	}
	results := monitor.Snapshot()
	if len(results) != 3 || results[0].Name != "artemis" || results[1].Name != "cassandra" || results[2].Name != "zookeeper" {
		t.Fatalf("monitor results = %+v", results)
	}

	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, "/webapp", nil))
	if recorder.Code != http.StatusOK {
		t.Fatalf("/webapp status = %d", recorder.Code)
	}
	if body := recorder.Body.String(); body == "" || containsAny(body, cfg.ArtemisPassword, "stack trace") {
		t.Fatalf("unsafe or empty response body: %q", body)
	}
}

func TestNewApplicationRejectsMalformedCassandraEndpoint(t *testing.T) {
	cfg := config.Config{CheckTimeout: time.Second, CassandraHost: "missing-port"}
	if handler, monitor, err := newApplication(cfg); err == nil || handler != nil || monitor != nil {
		t.Fatalf("newApplication() = %v, %v, %v; want nil values and error", handler, monitor, err)
	}
}

func TestServeShutsDownAfterContextCancellation(t *testing.T) {
	cfg := config.Config{
		CheckInterval: time.Hour,
		CheckTimeout:  20 * time.Millisecond,
		CassandraHost: "127.0.0.1:1",
		ZooKeeperHost: "127.0.0.1:1",
		ArtemisHost:   "127.0.0.1:1",
	}
	handler, monitor, err := newApplication(cfg)
	if err != nil {
		t.Fatal(err)
	}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- serve(ctx, cfg, listener, handler, monitor) }()

	client := &http.Client{Timeout: time.Second}
	response, err := client.Get("http://" + listener.Addr().String() + "/healthz")
	if err != nil {
		cancel()
		t.Fatalf("GET /healthz: %v", err)
	}
	_ = response.Body.Close()
	cancel()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("serve() error = %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("serve did not stop after context cancellation")
	}
}

func containsAny(value string, candidates ...string) bool {
	for _, candidate := range candidates {
		if candidate != "" && strings.Contains(value, candidate) {
			return true
		}
	}
	return false
}
