# Worker image for the money-transfer sample.
#
# Built for the host architecture on purpose: minikube runs on this machine, so
# its nodes share the host's arch and no cross-compilation is involved. run.sh
# loads the result straight into the cluster instead of pushing to a registry.

FROM golang:1.26-alpine AS build
WORKDIR /src

# Copy the manifests alone first, so `go mod download` is cached independently
# of source edits. Rebuilds after a code change skip the module fetch entirely.
COPY app/go.mod app/go.sum ./
RUN go mod download

COPY app/ ./

# CGO_ENABLED=0 produces a static binary, which is what lets the runtime stage
# be a distroless image with no libc at all.
RUN CGO_ENABLED=0 go build -trimpath -o /out/worker ./worker

# No shell, no package manager, and a non-root user by default. The worker reads
# one Secret and opens one outbound connection, so it needs nothing else — and a
# customer asking "what else is in that image?" deserves "nothing" as the answer.
FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/worker /worker
USER nonroot:nonroot
ENTRYPOINT ["/worker"]
