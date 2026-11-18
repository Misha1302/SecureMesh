.PHONY: bootstrap demo smoke verify down crypto seed-demo build-linux client
bootstrap:
	bash scripts/bootstrap.sh
demo:
	bash scripts/demo.sh
crypto:
	python3 tests/crypto/process_spike.py
seed-demo:
	.local/venv/bin/python scripts/seed_demo.py
build-linux:
	bash scripts/build-linux.sh
client:
	bash scripts/client.sh
network-gprs:
	.local/venv/bin/python tests/chaos-2g/run.py --profile gprs --seeds 7,19,41 --count 200
network-severe:
	.local/venv/bin/python tests/chaos-2g/run.py --profile severe --seeds 7,19,41 --count 200
smoke:
	python3 tests/integration/smoke.py
	.local/venv/bin/python tests/integration/delivery.py
verify:
	bash scripts/verify.sh
down:
	bash scripts/down.sh
