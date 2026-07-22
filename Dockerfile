FROM golang:1.26.5-alpine AS build

WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath \
    -ldflags="-s -w -buildid=" -o /out/twc-lab ./cmd/twc-lab

FROM gcr.io/distroless/static-debian12:nonroot

COPY --from=build /out/twc-lab /twc-lab
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/twc-lab"]
