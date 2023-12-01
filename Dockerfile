FROM registry.access.redhat.com/ubi9/ubi-minimal:9.3 AS builder
ARG TARGETARCH
USER root
RUN microdnf install -y tar gzip make which

# install platform specific go version (currently hardcoded to amd64)
RUN curl -O -J  https://dl.google.com/go/go1.21.4.linux-amd64.tar.gz
RUN tar -C /usr/local -xzf go1.21.4.linux-amd64.tar.gz
RUN ln -s /usr/local/go/bin/go /usr/local/bin/go

# Set destination for COPY
WORKDIR /app

# Download Go modules
COPY . ./
RUN go mod vendor

# Build
RUN CGO_ENABLED=0 GOOS=linux go build -o content_server

FROM registry.access.redhat.com/ubi9/ubi-minimal:9.3

COPY --from=builder app/content_server /usr/local/bin/

# Optional:
# To bind to a TCP port, runtime parameters must be supplied to the docker command.
# But we can document in the Dockerfile what ports
# the application is going to listen on by default.
# https://docs.docker.com/engine/reference/builder/#expose
EXPOSE 8080

USER 1001
# Run
CMD ["content_server"]
