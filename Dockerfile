FROM golang:1.27.1-alpine@sha256:8a5910f31396cd4d89662f56c68b3ae31d374308270a1c3bd96672ee5ed43414 AS build

ARG TARGETOS
ARG TARGETARCH
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} go build -trimpath \
    -ldflags="-s -w -buildid=" -o /out/twc-lab ./cmd/twc-lab

FROM gcr.io/distroless/static-debian12:nonroot@sha256:afa5c872c891853ca7fcf1f12c3edb23f7eeef36189728842dd51042ff57f7ab

COPY --from=build /out/twc-lab /twc-lab
COPY --from=build /src/LICENSE /src/THIRD_PARTY_NOTICES.md /licenses/
COPY --from=build /src/LICENSES/ /licenses/third-party/
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/twc-lab"]
