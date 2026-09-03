// Starts one money transfer against Temporal Cloud, from your laptop.
//
// The worker runs in minikube; this does not. Keeping the starter outside the
// cluster means you can fire a transfer whenever you like while the room
// watches the pod logs pick it up.
//
// Static credentials are correct here, unlike in the worker: this process
// lives for a few seconds, so it cannot outlive its key. The worker, which
// runs indefinitely, re-reads its key on every request instead.
package main

import (
	"context"
	"crypto/tls"
	"fmt"
	"log"
	"os"
	"time"

	"go.temporal.io/sdk/client"

	"money-transfer-project-template-go/app"
)

func main() {
	c, err := client.Dial(client.Options{
		HostPort:  mustEnv("TEMPORAL_ADDRESS"),
		Namespace: mustEnv("TEMPORAL_NAMESPACE"),
		// TEMPORAL_CLOUD_API_KEY is the one name a Temporal Cloud API key goes
		// by in this demo. run.sh sets it for this process to the short-lived,
		// namespace-scoped key Vault minted for this transfer, rather than the
		// admin bootstrap key of the same name in .env.
		Credentials:       client.NewAPIKeyStaticCredentials(mustEnv("TEMPORAL_CLOUD_API_KEY")),
		ConnectionOptions: client.ConnectionOptions{TLS: &tls.Config{}},
	})
	if err != nil {
		log.Fatalln("Unable to create Temporal client:", err)
	}
	defer c.Close()

	input := app.PaymentDetails{
		SourceAccount: "85-150",
		TargetAccount: "43-812",
		Amount:        250,
		ReferenceID:   "12345",
	}

	options := client.StartWorkflowOptions{
		// Upstream hardcodes "pay-invoice-701". A suffix makes the script
		// re-runnable: without it, firing a second transfer while the first is
		// still open fails as a duplicate ID rather than starting anything.
		ID:        fmt.Sprintf("pay-invoice-%d", time.Now().Unix()),
		TaskQueue: app.MoneyTransferTaskQueueName,
	}

	log.Printf("Starting transfer from account %s to account %s for %d",
		input.SourceAccount, input.TargetAccount, input.Amount)

	we, err := startWithRetry(c, options, input)
	if err != nil {
		log.Fatalln("Unable to start the Workflow:", err)
	}

	log.Printf("WorkflowID: %s RunID: %s\n", we.GetID(), we.GetRunID())

	result, err := resultWithRetry(we)
	if err != nil {
		log.Fatalln("Unable to get Workflow result:", err)
	}

	log.Println(result)
}

// startWithRetry works around a Temporal Cloud property this demo runs into
// constantly: a service account's namespace *write* grant reaches the data plane
// later than its read access does. The dial above succeeds on account-level read
// while starting a workflow is still refused, so a freshly minted key can be
// good enough to connect and not yet good enough to use.
//
// Retrying is the honest fix. The alternative — sleeping a fixed amount before
// the first attempt — is slower when the grant has already landed and still
// wrong when it has not.
func startWithRetry(
	c client.Client,
	options client.StartWorkflowOptions,
	input app.PaymentDetails,
) (client.WorkflowRun, error) {
	const (
		attempts = 20
		backoff  = 3 * time.Second
	)
	var lastErr error
	for attempt := 1; attempt <= attempts; attempt++ {
		we, err := c.ExecuteWorkflow(context.Background(), options, app.MoneyTransfer, input)
		if err == nil {
			return we, nil
		}
		lastErr = err
		log.Printf("waiting for the namespace grant to propagate (attempt %d/%d): %v",
			attempt, attempts, err)
		time.Sleep(backoff)
	}
	return nil, lastErr
}

// resultWithRetry exists for the same reason as startWithRetry, one call later.
// Starting the workflow can succeed and fetching its result still be refused,
// because each call is authorized independently and the grant lands somewhere
// between the two. Get is safe to call again — it long-polls for a result rather
// than doing anything — so retrying costs nothing but the wait.
func resultWithRetry(we client.WorkflowRun) (string, error) {
	const (
		attempts = 20
		backoff  = 3 * time.Second
	)
	var lastErr error
	for attempt := 1; attempt <= attempts; attempt++ {
		var result string
		err := we.Get(context.Background(), &result)
		if err == nil {
			return result, nil
		}
		lastErr = err
		log.Printf("waiting for the result to be readable (attempt %d/%d): %v",
			attempt, attempts, err)
		time.Sleep(backoff)
	}
	return "", lastErr
}

func mustEnv(name string) string {
	value := os.Getenv(name)
	if value == "" {
		log.Fatalf("%s is required", name)
	}
	return value
}
