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
		escapeSTOMPHeader(host), escapeSTOMPHeader(c.user), escapeSTOMPHeader(c.password),
	)
	if _, err := conn.Write([]byte(frame)); err != nil {
		return sanitizedCheckError(ctx, "artemis protocol check failed")
	}

	response, err := readNULTerminated(conn, maxArtemisResponseBytes)
	if err != nil {
		return sanitizedCheckError(ctx, "artemis protocol check failed")
	}
	command, _, _ := strings.Cut(string(response), "\n")
	if strings.TrimSuffix(command, "\r") != "CONNECTED" {
		return errors.New("artemis protocol check failed")
	}
	return nil
}

func escapeSTOMPHeader(value string) string {
	value = strings.ReplaceAll(value, "\\", "\\\\")
	value = strings.ReplaceAll(value, "\r", "\\r")
	value = strings.ReplaceAll(value, "\n", "\\n")
	return strings.ReplaceAll(value, ":", "\\c")
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
