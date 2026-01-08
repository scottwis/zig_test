# zig_test

Simple Zig HTTP server exposing a `/v1/ping` endpoint that returns `pong`.

## Development

- `make build` – build the server
- `make test` – run the unit test suite
- `make fmt` – format the codebase
- `make lint` – check formatting without modifying files

Start the server locally with `zig build run` and it will listen on port 8080.
