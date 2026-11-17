# 37. Call Viam with gRPC-web and generated protobuf types

Date: 2026-10-31

Status: Accepted

## Context

The app calls Viam's AppService to validate keys ([Viam sign-in with an API key (#35)](https://github.com/ashitaka1/viam-batch-provisioner/issues/35)) and to list orgs and locations, create machines and fetch part credentials ([Create machines and fetch credentials from the app (#36)](https://github.com/ashitaka1/viam-batch-provisioner/issues/36)). Viam publishes no Swift SDK. app.viam.com serves gRPC and gRPC-web, and Viam's TypeScript SDK uses gRPC-web. An API key authenticates through `proto.rpc.v1.AuthService/Authenticate` (entity = key ID, credentials type `api-key`), which returns a bearer token for later calls.

## Decision

`ViamAPI` sends unary gRPC-web requests over URLSession, with swift-protobuf types generated from pinned commits of `viamrobotics/api` and `viamrobotics/goutils` by `scripts/gen-viam-protos.sh` and checked in.

## Consequences

- The calls run on macOS and iOS with no HTTP/2 or gRPC runtime dependency.
- Each new call is a request type and a method.
- Streaming calls are out of reach until something needs one.
- Picking up API changes means bumping the pins and regenerating.

## Alternatives

- grpc-swift has its own HTTP/2 transport, which is a larger dependency.
- Connect-Swift needs a second code generator and runtime.
- Hand-encoded protobuf doesn't scale past a few messages.
