.PHONY: bootstrap demo smoke verify down crypto seed-demo build-linux client network-gprs network-severe native-network-gprs native-network-severe native-cursor-recovery gui-smoke gui-pending-smoke
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
native-network-gprs:
	.local/venv/bin/python tests/chaos-2g/native_run.py --profile gprs --seeds 7,19,41 --count 200
native-network-severe:
	.local/venv/bin/python tests/chaos-2g/native_run.py --profile severe --seeds 7,19,41 --count 200
native-cursor-recovery:
	.local/venv/bin/python tests/integration/native_cursor_recovery.py
gui-smoke:
	.local/venv/bin/python tests/gui/native_v2.py --script tests/gui/v2_scenario.json
gui-pending-smoke:
	.local/venv/bin/python tests/gui/native_v2.py --script tests/gui/v2_pending_scenario.json
smoke:
	python3 tests/integration/smoke.py
	.local/venv/bin/python tests/integration/delivery.py
verify:
	bash scripts/verify.sh
down:
	bash scripts/down.sh
