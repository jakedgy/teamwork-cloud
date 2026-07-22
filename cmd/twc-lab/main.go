package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"net"
	"net/http"
	"os/signal"
	"syscall"
	"time"

	"github.com/jakedgy/teamwork-cloud/internal/config"
	"github.com/jakedgy/teamwork-cloud/internal/health"
	"github.com/jakedgy/teamwork-cloud/internal/web"
)

func main() {
	cfg, err := config.FromEnv()
	if err != nil {
		log.Fatal(err)
	}

	log.Printf("starting twc-lab listen_addr=%q cluster=%q region=%q", cfg.ListenAddr, cfg.ClusterName, cfg.AWSRegion)
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	if err := run(ctx, cfg); err != nil {
		log.Fatal(err)
	}
}

func run(ctx context.Context, cfg config.Config) error {
	handler, monitor, err := newApplication(cfg)
	if err != nil {
		return err
	}
	listener, err := net.Listen("tcp", cfg.ListenAddr)
	if err != nil {
		return fmt.Errorf("listen for simulator: %w", err)
	}
	defer listener.Close()
	return serve(ctx, cfg, listener, handler, monitor)
}

func serve(ctx context.Context, cfg config.Config, listener net.Listener, handler http.Handler, monitor *health.Monitor) error {
	server := &http.Server{
		Addr: cfg.ListenAddr,
		// Bound header reads and idle keep-alive connections to limit resource use.
		ReadHeaderTimeout: 5 * time.Second,
		IdleTimeout:       60 * time.Second,
		Handler:           handler,
	}

	monitorCtx, cancelMonitor := context.WithCancel(ctx)
	defer cancelMonitor()
	go monitor.Run(monitorCtx, cfg.CheckInterval)

	errCh := make(chan error, 1)
	go func() {
		errCh <- server.Serve(listener)
	}()

	select {
	case err := <-errCh:
		if errors.Is(err, http.ErrServerClosed) {
			return nil
		}
		return fmt.Errorf("serve simulator: %w", err)
	case <-ctx.Done():
		cancelMonitor()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := server.Shutdown(shutdownCtx); err != nil {
			return errors.New("simulator shutdown failed")
		}
		if err := <-errCh; err != nil && !errors.Is(err, http.ErrServerClosed) {
			return fmt.Errorf("serve simulator: %w", err)
		}
		return nil
	}
}

func newApplication(cfg config.Config) (http.Handler, *health.Monitor, error) {
	cassandra, err := health.NewCassandraChecker(cfg.CassandraHost)
	if err != nil {
		return nil, nil, err
	}
	monitor, err := health.NewMonitor([]health.Checker{
		cassandra,
		health.NewZooKeeperChecker(cfg.ZooKeeperHost),
		health.NewArtemisChecker(cfg.ArtemisHost, cfg.ArtemisUser, cfg.ArtemisPassword),
	}, cfg.CheckTimeout)
	if err != nil {
		return nil, nil, err
	}
	handler, err := web.New(monitor, web.Metadata{ClusterName: cfg.ClusterName, AWSRegion: cfg.AWSRegion})
	if err != nil {
		return nil, nil, err
	}
	return handler, monitor, nil
}
