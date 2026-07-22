package health

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"net"
	"strings"
)

const maxArtemisResponseBytes = 8 * 1024

// ArtemisChecker performs an authenticated STOMP 1.2 connection handshake.
type ArtemisChecker struct {
	endpoint string
	user     string
	password string
	dialer   net.Dialer
}

func NewArtemisChecker(endpoint, user, password string) *ArtemisChecker {
	return &ArtemisChecker{endpoint: endpoint, user: user, password: password}
}

func (c *ArtemisChecker) Name() string     { return "artemis" }
func (c *ArtemisChecker) Endpoint() string { return c.endpoint }

func (c *ArtemisChecker) Check(ctx context.Context) error {
	if strings.ContainsAny(c.user, "\r\n") || strings.ContainsAny(c.password, "\r\n") {
		return errors.New("artemis credentials invalid")
	}
	conn, err := c.dialer.DialContext(ctx, "tcp", c.endpoint)
	if err != nil {
		return sanitizedCheckError(ctx, "artemis connection failed")
	}
	defer conn.Close()
	stop := bindConnectionToContext(ctx, conn)
	defer stop()

	host, _, err := net.SplitHostPort(c.endpoint)
	if err != nil {
		host = c.endpoint
	}
	frame := fmt.Sprintf(
		"CONNECT\naccept-version:1.2\nhost:%s\nlogin:%s\npasscode:%s\n\n\x00",
		host, c.user, c.password,
	)
	if _, err := conn.Write([]byte(frame)); err != nil {
		return sanitizedCheckError(ctx, "artemis protocol check failed")
	}

	response, err := readNULTerminated(conn, maxArtemisResponseBytes)
	if err != nil {
		return sanitizedCheckError(ctx, "artemis protocol check failed")
	}
	if !validConnectedFrame(response) {
		return errors.New("artemis protocol check failed")
	}
	return nil
}

func validConnectedFrame(frame []byte) bool {
	value := strings.ReplaceAll(string(frame), "\r\n", "\n")
	if strings.Contains(value, "\r") {
		return false
	}
	headerEnd := strings.Index(value, "\n\n")
	if headerEnd < 0 {
		return false
	}
	lines := strings.Split(value[:headerEnd], "\n")
	if len(lines) == 0 || lines[0] != "CONNECTED" {
		return false
	}
	versionFound := false
	for _, line := range lines[1:] {
		name, headerValue, found := strings.Cut(line, ":")
		if !found || name == "" {
			return false
		}
		if name == "version" {
			if versionFound || headerValue != "1.2" {
				return false
			}
			versionFound = true
		}
	}
	return versionFound
}

func readNULTerminated(conn net.Conn, limit int) ([]byte, error) {
	reader := bufio.NewReader(conn)
	response := make([]byte, 0, 128)
	for len(response) < limit {
		value, err := reader.ReadByte()
		if err != nil {
			return nil, err
		}
		if value == 0 {
			return response, nil
		}
		response = append(response, value)
	}
	return nil, errors.New("response exceeds limit")
}
