.PHONY: build test fmt lint

build:
	zig build

test:
	zig build test

fmt:
	zig fmt src/*.zig build.zig

lint:
	zig fmt --check src/*.zig build.zig
