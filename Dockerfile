FROM registry.access.redhat.com/ubi9/go-toolset:9.7-1770654497 as builder

COPY go.mod go.mod
COPY go.sum go.sum
# cache deps before building and copying source so that we don't need to re-download as much
# and so that source changes don't invalidate our downloaded layer
RUN go mod download

# Copy the go source
COPY . .

# Build
RUN GOOS=linux GOARCH=amd64 go build -a -o metrics-server .

# Use ubi-micro as minimal base image to package the manager binary
# See https://catalog.redhat.com/software/containers/ubi9/ubi-micro/615bdf943f6014fa45ae1b58
FROM registry.access.redhat.com/ubi9/ubi-micro:9.7-1773894938

COPY policy.json /etc/containers/
COPY --from=builder /opt/app-root/src/metrics-server /bin/
COPY --from=builder /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem /etc/pki/ca-trust/extracted/pem/
COPY --from=builder /etc/pki/tls/certs/ca-bundle.crt /etc/pki/tls/certs/

# It is mandatory to set these labels
LABEL name="Konflux Release Service"
LABEL description="Konflux Release Availability Metrics Service"
LABEL io.k8s.description="Konflux Release Availability Metrics Service"
LABEL io.k8s.display-name="release-availability-metrics"
LABEL summary="Konflux Release Availability Metrics Service"
LABEL com.redhat.component="release-availability-service"

USER 65532:65532

ENTRYPOINT ["/bin/metrics-server"]
