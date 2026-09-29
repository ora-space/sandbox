GO ?= go
IMAGE ?= ora-sandbox-runtime:dev
BIN_DIR ?= bin

.PHONY: test test-race vet build image clean

test:
	$(GO) test ./...

test-race:
	$(GO) test -race ./...

vet:
	$(GO) vet ./...

build:
	mkdir -p $(BIN_DIR)
	$(GO) build -o $(BIN_DIR)/ora-sandbox-service ./service
	$(GO) build -o $(BIN_DIR)/ora-sandbox-runtime ./runtime
	$(GO) build -o $(BIN_DIR)/ora-controller-demo ./examples/controller-demo

image:
	docker build -f runtime/Containerfile -t $(IMAGE) .

clean:
	rm -rf $(BIN_DIR)
