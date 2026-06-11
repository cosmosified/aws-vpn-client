package cmd

import (
	"bufio"
	"fmt"
	"log"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/ethan605/aws-vpn-client/pkg/samlserver"
)

const (
	managementHost = "127.0.0.1"
	acsPort        = "35001"
)

// crv1Challenge holds the parsed fields of an AWS dynamic challenge:
//
//	CRV1:<flags>:<state-id>:<b64-username>:<challenge-text>
//
// For AWS Client VPN, <challenge-text> is the SAML IdP URL and <state-id> is
// the VPN session id that must be echoed back in the response.
type crv1Challenge struct {
	sid string
	url string
}

// parseCRV1 extracts a CRV1 dynamic challenge from a management
// ">PASSWORD:Verification Failed" line. Returns nil if none is present.
func parseCRV1(line string) *crv1Challenge {
	idx := strings.Index(line, "CRV1:")
	if idx < 0 {
		return nil
	}

	s := line[idx:]
	// Strip the management wrapper, e.g. ['CRV1:...'].
	if end := strings.Index(s, "']"); end >= 0 {
		s = s[:end]
	}

	rest := strings.TrimPrefix(s, "CRV1:")
	// flags : state-id : b64-username : challenge-text (may itself contain ':')
	parts := strings.SplitN(rest, ":", 4)
	if len(parts) < 4 {
		return nil
	}

	return &crv1Challenge{sid: parts[1], url: parts[3]}
}

// connectViaManagement runs a single OpenVPN process and drives the AWS SAML
// dynamic-challenge flow over the management interface, instead of spawning two
// separate openvpn processes and exchanging the credential via a temp file.
//
// NOTE: prototype. The management socket is an unauthenticated TCP listener on
// 127.0.0.1; a production version should use a unix socket or
// --management-client-auth. Requires a live AWS endpoint to validate.
func (c *cmdConfigs) connectViaManagement() error {
	remoteIP := c.digRemoteIP() // also sets c.RemotePort

	strippedConf, err := c.writeStrippedConf()
	if err != nil {
		return err
	}
	c.strippedConf = strippedConf

	mgmtPort := c.MgmtPort
	if mgmtPort == "" {
		mgmtPort = defaultMgmtPort
	}

	// OpenVPN must run as root to create the tun device, routes and DNS. We
	// keep the Go driver (browser launch + ACS server) running as the user, so
	// we spawn openvpn via sudo rather than running the whole CLI as root.
	args := []string{
		c.OvpnBin,
		"--config", c.strippedConf,
		"--remote", remoteIP, c.RemotePort,
		"--management", managementHost, mgmtPort,
		"--management-hold",
		"--management-query-passwords",
		"--auth-retry", "interact",
		"--script-security", "2",
	}
	if c.DNSUpDown != "" {
		args = append(args, "--dns-updown", c.DNSUpDown)
	}
	if c.UpScript != "" {
		args = append(args, "--up", c.UpScript)
	}
	if c.DownScript != "" {
		args = append(args, "--down", c.DownScript)
	}

	if c.Verbose {
		log.Printf("management mode: sudo %s\n", strings.Join(args, " "))
	}

	ovpn := exec.Command("sudo", args...)
	ovpn.Stdout = os.Stdout
	ovpn.Stderr = os.Stderr
	ovpn.Stdin = os.Stdin
	if err := ovpn.Start(); err != nil {
		return fmt.Errorf("failed to start openvpn: %w", err)
	}

	// Let openvpn handle Ctrl-C/SIGTERM (it shares the terminal's process
	// group); the Go driver should not exit first, so openvpn can tear down
	// cleanly. The management loop ends when openvpn closes the socket.
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		for range sigCh {
			// Intentionally swallowed.
		}
	}()

	if err := c.driveManagement(managementHost + ":" + mgmtPort); err != nil {
		_ = ovpn.Process.Kill()
		return err
	}

	return ovpn.Wait()
}

// driveManagement connects to the OpenVPN management socket and runs the
// CRV1/SAML state machine over a single connection.
func (c *cmdConfigs) driveManagement(addr string) error {
	var conn net.Conn
	var err error
	for i := 0; i < 50; i++ {
		conn, err = net.Dial("tcp", addr)
		if err == nil {
			break
		}
		time.Sleep(100 * time.Millisecond)
	}
	if err != nil {
		return fmt.Errorf("could not connect to management interface at %s: %w", addr, err)
	}
	defer conn.Close()

	send := func(cmd string) {
		if c.Verbose {
			log.Printf("mgmt >> %s\n", redact(cmd))
		}
		fmt.Fprintf(conn, "%s\n", cmd)
	}

	// SAML ACS server (started lazily when the challenge arrives).
	samlServer := samlserver.NewServer()
	samlShutdownCh := make(chan bool, 1)

	var (
		challenge   *crv1Challenge
		samlStarted bool
	)

	scanner := bufio.NewScanner(conn)
	// The challenge line carries the full SAML IdP URL, which can be large.
	scanner.Buffer(make([]byte, 1024*1024), 1024*1024)

	for scanner.Scan() {
		line := scanner.Text()
		if c.Verbose {
			log.Printf("mgmt << %s\n", line)
		}

		switch {
		case strings.HasPrefix(line, ">HOLD:"):
			send("state on")
			send("hold release")

		case strings.HasPrefix(line, ">PASSWORD:Verification Failed"):
			if ch := parseCRV1(line); ch != nil {
				challenge = ch
				if !samlStarted {
					samlStarted = true
					go samlServer.Run(samlShutdownCh)
					log.Println("Opening browser for SAML authentication...")
					c.openChallengeURL(challenge.url)
				}
			} else {
				return fmt.Errorf("authentication rejected: %s", line)
			}

		case strings.HasPrefix(line, ">PASSWORD:Need 'Auth' username/password"):
			if challenge == nil {
				// Phase 1: signal SAML support and the local ACS port.
				send(`username "Auth" "N/A"`)
				send(fmt.Sprintf(`password "Auth" "ACS::%s"`, acsPort))
			} else {
				// Phase 2: block until the IdP posts the SAML assertion to the
				// ACS server, then answer the challenge on the same connection.
				log.Println("Waiting for SAML response...")
				samlResponse := <-samlServer.SAMLResponseCh()
				samlShutdownCh <- true

				vpnPassword := fmt.Sprintf("CRV1::%s::%s", challenge.sid, samlResponse)
				send(`username "Auth" "N/A"`)
				send(fmt.Sprintf(`password "Auth" "%s"`, escapeMgmt(vpnPassword)))
			}

		case strings.Contains(line, ",CONNECTED,SUCCESS"):
			log.Println("Successfully connected")

		case strings.HasPrefix(line, ">FATAL:"):
			return fmt.Errorf("openvpn fatal: %s", strings.TrimPrefix(line, ">FATAL:"))
		}
	}

	return scanner.Err()
}

// escapeMgmt escapes a value for use inside a double-quoted management command
// argument (only backslash and double-quote are special).
func escapeMgmt(s string) string {
	s = strings.ReplaceAll(s, `\`, `\\`)
	s = strings.ReplaceAll(s, `"`, `\"`)
	return s
}

// redact hides credential payloads from verbose logs.
func redact(cmd string) string {
	if strings.HasPrefix(cmd, "password ") {
		return `password "Auth" "***"`
	}
	return cmd
}
