// Worker for the money-transfer sample, connected to Temporal Cloud with an
// API key that HashiCorp Vault issued and will delete when its lease ends.
//
// This is the only file that differs meaningfully from
// temporalio/money-transfer-project-template-go. The workflow, the activities
// and the banking stub are upstream code, unchanged — swapping a static
// credential for a Vault-issued one does not reach into business logic.
//
// Upstream calls client.Dial(client.Options{}), which connects to a local dev
// server with no credential at all. Everything below exists to replace that
// with a credential that expires.
package main

import (
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"log"
	"os"
	"strings"
	"time"

	"go.temporal.io/api/serviceerror"
	"go.temporal.io/sdk/client"
	"go.temporal.io/sdk/worker"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"money-transfer-project-template-go/app"
)

// The API key arrives as a Kubernetes Secret mounted at this path — a file,
// deliberately, not an environment variable. kubelet refreshes a mounted
// Secret in place, so Vault can issue a replacement key and this process picks
// it up where it stands. An environment variable is fixed for the life of the
// process, which would make every rotation a pod restart.
const credentialPath = "/vault/creds/api-key"

// Two separate startup races, each needing its own patience.
//
// Dialing can fail because the Secret is not mounted yet, or because the key is
// too fresh for the auth layer to accept.
//
// Starting the worker can fail *after* a successful dial, and that one is
// easy to miss: connecting needs only the account-level read grant, while
// polling a task queue needs namespace write, and Temporal Cloud propagates the
// second one later than the first. So the first poll gets refused on a
// credential that was good enough to connect with. Without this retry the
// process exits, Kubernetes restarts it, and the worker comes up only once the
// grant happens to have landed — a crash-loop dressed up as a startup delay.
const (
	dialAttempts  = 30
	dialBackoff   = 2 * time.Second
	startAttempts = 30
	startBackoff  = 3 * time.Second
)

func main() {
	address := mustEnv("TEMPORAL_ADDRESS")
	namespace := mustEnv("TEMPORAL_NAMESPACE")

	// Read the file on every request rather than once at startup. The Vault
	// lease behind this key is minutes long: a value captured at boot would be
	// deleted in Temporal Cloud while this worker was still running on it.
	credentials := client.NewAPIKeyDynamicCredentials(
		func(context.Context) (string, error) { return readAPIKey() },
	)

	c, err := dialWithRetry(client.Options{
		HostPort:    address,
		Namespace:   namespace,
		Credentials: credentials,
		// API key authentication requires TLS. An empty config is enough —
		// it verifies Temporal Cloud's certificate against the system roots.
		ConnectionOptions: client.ConnectionOptions{TLS: &tls.Config{}},
	})
	if err != nil {
		log.Fatalln("Unable to create Temporal client.", err)
	}
	defer c.Close()

	log.Printf("connected to %s, namespace %s", address, namespace)
	log.Printf("credential source: %s (re-read on every request)", credentialPath)

	if err := runWorker(c); err != nil {
		log.Fatalln("unable to start Worker", err)
	}
}

// runWorker polls the task queue, retrying while Temporal Cloud is still
// refusing the credential. Any other error is returned immediately: a wrong
// namespace or a missing task queue is not something waiting will fix, and
// retrying it thirty times would only bury the real message.
//
// A fresh worker is built per attempt because Run consumes the one it is given;
// the interrupt channel is not, since asking for it twice would install a second
// signal handler.
func runWorker(c client.Client) error {
	// InterruptCh covers SIGTERM as well as SIGINT, so `kubectl delete pod` and
	// a rollout both drain this worker rather than looking like a crash.
	interrupt := worker.InterruptCh()

	var lastErr error
	for attempt := 1; attempt <= startAttempts; attempt++ {
		w := worker.New(c, app.MoneyTransferTaskQueueName, worker.Options{})

		// This worker hosts both Workflow and Activity functions.
		w.RegisterWorkflow(app.MoneyTransfer)
		w.RegisterActivity(app.Withdraw)
		w.RegisterActivity(app.Deposit)
		w.RegisterActivity(app.Refund)

		log.Printf("polling task queue %s", app.MoneyTransferTaskQueueName)

		err := w.Run(interrupt)
		if err == nil {
			// Clean shutdown: the interrupt channel fired.
			return nil
		}
		if !isAuthError(err) {
			return err
		}
		lastErr = err
		log.Printf("Temporal Cloud refused the credential (attempt %d/%d): %v"+
			" — the namespace grant is probably still propagating",
			attempt, startAttempts, err)
		time.Sleep(startBackoff)
	}
	return lastErr
}

// isAuthError reports whether Temporal Cloud rejected the credential itself, as
// opposed to disliking the request. Both checks are needed, and the first one is
// the one that is easy to get wrong.
//
// A refused namespace grant arrives as *serviceerror.PermissionDenied, which
// carries its gRPC status on a method named Status() rather than the
// GRPCStatus() that status.FromError looks for. So status.Code() reports Unknown
// for it and a code-only check silently misses the exact case this retry exists
// for. errors.As is what actually matches it.
//
// A malformed or deleted key takes the other path: codes.Unauthenticated has no
// serviceerror type and stays a plain gRPC status error.
func isAuthError(err error) bool {
	var permissionDenied *serviceerror.PermissionDenied
	if errors.As(err, &permissionDenied) {
		return true
	}
	switch status.Code(err) {
	case codes.Unauthenticated, codes.PermissionDenied:
		return true
	default:
		return false
	}
}

// readAPIKey returns the current contents of the mounted Secret. An error here
// fails the individual request rather than the process: during a rotation the
// file can be momentarily unreadable, and the SDK's own retry covers that
// better than a restart would.
func readAPIKey() (string, error) {
	raw, err := os.ReadFile(credentialPath)
	if err != nil {
		return "", fmt.Errorf("reading API key from %s: %w", credentialPath, err)
	}
	key := strings.TrimSpace(string(raw))
	if key == "" {
		return "", fmt.Errorf("API key at %s is empty", credentialPath)
	}
	return key, nil
}

// dialWithRetry tolerates a worker that starts before its credential is usable.
// Two independent delays make this necessary: the Secret may not be mounted for
// a moment after the pod starts, and a freshly minted Temporal Cloud key is not
// accepted by the auth layer the instant Vault returns it.
func dialWithRetry(options client.Options) (client.Client, error) {
	var lastErr error
	for attempt := 1; attempt <= dialAttempts; attempt++ {
		c, err := client.Dial(options)
		if err == nil {
			return c, nil
		}
		lastErr = err
		log.Printf("waiting for a usable credential (attempt %d/%d): %v",
			attempt, dialAttempts, err)
		time.Sleep(dialBackoff)
	}
	return nil, lastErr
}

func mustEnv(name string) string {
	value := os.Getenv(name)
	if value == "" {
		log.Fatalf("%s is required", name)
	}
	return value
}
