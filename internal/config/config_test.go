package config

import (
	"strings"
	"testing"
	"time"
)

func TestFromLookupDefaults(t *testing.T) {
	got, err := FromLookup(func(string) (string, bool) { return "", false })
	if err != nil {
		t.Fatalf("FromLookup() error = %v", err)
	}

	want := Config{
		ListenAddr:      ":8080",
		CheckInterval:   10 * time.Second,
		CheckTimeout:    3 * time.Second,
		CassandraHost:   "twc-lab-cassandra:9042",
		ZooKeeperHost:   "twc-lab-zookeeper:2181",
		ArtemisHost:     "twc-lab-artemis:61616",
		ArtemisUser:     "artemis",
		ArtemisPassword: "",
		ClusterName:     "twc-lab",
		AWSRegion:       "us-east-2",
	}
	if got != want {
		t.Errorf("FromLookup() = %#v, want %#v", got, want)
	}
}

func TestFromLookupOverridesDurationsAndEndpoints(t *testing.T) {
	values := map[string]string{
		"TWC_LAB_CHECK_INTERVAL": "45s",
		"TWC_LAB_CHECK_TIMEOUT":  "7s",
		"TWC_LAB_CASSANDRA_HOST": "cassandra.example:9042",
		"TWC_LAB_ZOOKEEPER_HOST": "zookeeper.example:2181",
		"TWC_LAB_ARTEMIS_HOST":   "artemis.example:61616",
	}

	got, err := FromLookup(mapLookup(values))
	if err != nil {
		t.Fatalf("FromLookup() error = %v", err)
	}
	if got.CheckInterval != 45*time.Second || got.CheckTimeout != 7*time.Second {
		t.Errorf("durations = %v, %v; want 45s, 7s", got.CheckInterval, got.CheckTimeout)
	}
	if got.CassandraHost != "cassandra.example:9042" || got.ZooKeeperHost != "zookeeper.example:2181" || got.ArtemisHost != "artemis.example:61616" {
		t.Errorf("endpoints = %q, %q, %q", got.CassandraHost, got.ZooKeeperHost, got.ArtemisHost)
	}
}

func TestFromLookupRejectsInvalidDurations(t *testing.T) {
	for _, tc := range []struct {
		name                    string
		key                     string
		value                   string
		positiveDurationMessage bool
	}{
		{name: "zero", key: "TWC_LAB_CHECK_INTERVAL", value: "0s", positiveDurationMessage: true},
		{name: "negative", key: "TWC_LAB_CHECK_TIMEOUT", value: "-1s", positiveDurationMessage: true},
		{name: "malformed", key: "TWC_LAB_CHECK_INTERVAL", value: "soon"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			_, err := FromLookup(mapLookup(map[string]string{tc.key: tc.value}))
			if err == nil {
				t.Fatal("FromLookup() error = nil, want error")
			}
			if !strings.Contains(err.Error(), tc.key) {
				t.Errorf("FromLookup() error = %q, want environment variable %q", err, tc.key)
			}
			if tc.positiveDurationMessage && !strings.Contains(err.Error(), "must be a positive duration") {
				t.Errorf("FromLookup() error = %q, want positive duration guidance", err)
			}
		})
	}
}

func mapLookup(values map[string]string) func(string) (string, bool) {
	return func(key string) (string, bool) {
		value, ok := values[key]
		return value, ok
	}
}
