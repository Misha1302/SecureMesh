.PHONY: bootstrap demo smoke verify down crypto
bootstrap:
	bash scripts/bootstrap.sh
demo:
	bash scripts/demo.sh
crypto:
	python3 tests/crypto/process_spike.py
smoke:
	python3 tests/integration/smoke.py
verify:
	bash scripts/verify.sh
down:
	docker compose down
