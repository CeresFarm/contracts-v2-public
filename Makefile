.PHONY: test-euler test-morpho test-silo size

size:
	forge build --sizes

gas-report:
	forge test --gas-report

invariant:
	FOUNDRY_PROFILE=invariant forge test --match-path "test/invariant/**"

test-euler:
	forge test --match-path "test/euler/**/*.sol"

test-morpho:
	forge test --match-path "test/morpho/**/*.sol"

test-silo:
	forge test --match-path "test/silo/**/*.sol"
