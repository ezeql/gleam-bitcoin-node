.PHONY: test

test:
	docker build -t gleam-bitcoin-node .
	docker run --rm gleam-bitcoin-node
