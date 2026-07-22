package config

import (
	"fmt"
	"os"
	"time"
)

const (
	listenAddrEnv      = "TWC_LAB_LISTEN_ADDR"
	checkIntervalEnv   = "TWC_LAB_CHECK_INTERVAL"
	checkTimeoutEnv    = "TWC_LAB_CHECK_TIMEOUT"
	cassandraHostEnv   = "TWC_LAB_CASSANDRA_HOST"
	zooKeeperHostEnv   = "TWC_LAB_ZOOKEEPER_HOST"
	artemisHostEnv     = "TWC_LAB_ARTEMIS_HOST"
	artemisUserEnv     = "TWC_LAB_ARTEMIS_USER"
	artemisPasswordEnv = "TWC_LAB_ARTEMIS_PASSWORD"
	clusterNameEnv     = "TWC_LAB_CLUSTER_NAME"
	awsRegionEnv       = "TWC_LAB_AWS_REGION"
)

// Config contains the simulator service configuration.
type Config struct {
	ListenAddr                   string
	CheckInterval, CheckTimeout  time.Duration
	CassandraHost, ZooKeeperHost string
	ArtemisHost                  string
	ArtemisUser, ArtemisPassword string
	ClusterName, AWSRegion       string
}

// FromEnv reads the simulator configuration from the process environment.
func FromEnv() (Config, error) {
	return FromLookup(os.LookupEnv)
}

// FromLookup reads the simulator configuration from lookup, which makes it
// straightforward to use alternate sources in tests.
func FromLookup(lookup func(string) (string, bool)) (Config, error) {
	checkInterval, err := duration(lookup, checkIntervalEnv, 10*time.Second)
	if err != nil {
		return Config{}, err
	}
	checkTimeout, err := duration(lookup, checkTimeoutEnv, 3*time.Second)
	if err != nil {
		return Config{}, err
	}

	return Config{
		ListenAddr:      stringValue(lookup, listenAddrEnv, ":8080"),
		CheckInterval:   checkInterval,
		CheckTimeout:    checkTimeout,
		CassandraHost:   stringValue(lookup, cassandraHostEnv, "twc-lab-cassandra:9042"),
		ZooKeeperHost:   stringValue(lookup, zooKeeperHostEnv, "twc-lab-zookeeper:2181"),
		ArtemisHost:     stringValue(lookup, artemisHostEnv, "twc-lab-artemis:61616"),
		ArtemisUser:     stringValue(lookup, artemisUserEnv, "artemis"),
		ArtemisPassword: stringValue(lookup, artemisPasswordEnv, ""),
		ClusterName:     stringValue(lookup, clusterNameEnv, "twc-lab"),
		AWSRegion:       stringValue(lookup, awsRegionEnv, "us-east-2"),
	}, nil
}

func stringValue(lookup func(string) (string, bool), key, fallback string) string {
	if value, ok := lookup(key); ok {
		return value
	}
	return fallback
}

func duration(lookup func(string) (string, bool), key string, fallback time.Duration) (time.Duration, error) {
	value, ok := lookup(key)
	if !ok {
		return fallback, nil
	}

	parsed, err := time.ParseDuration(value)
	if err != nil || parsed <= 0 {
		return 0, fmt.Errorf("invalid %s", key)
	}
	return parsed, nil
}
