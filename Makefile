.PHONY: bootstrap demo smoke verify down crypto seed-demo build-linux client network-gprs network-severe native-network-gprs native-network-severe native-cursor-recovery restore-v2 enrollment-quota onboarding-recovery refresh-recovery refresh-quota refresh-upgrade gui-reauthentication gui-smoke gui-pending-smoke gui-onboarding-recovery
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
restore-v2:
	.local/venv/bin/python tests/integration/restore_v2.py
enrollment-quota:
	.local/venv/bin/python tests/integration/enrollment_quota.py
onboarding-recovery:
	.local/venv/bin/python tests/integration/onboarding_recovery.py
refresh-recovery:
	.local/venv/bin/python tests/integration/refresh_recovery.py
refresh-quota:
	.local/venv/bin/python tests/integration/refresh_quota.py
refresh-upgrade:
	dotnet build tests/migration_runner
	.local/venv/bin/python tests/integration/refresh_upgrade.py
gui-reauthentication:
	.local/venv/bin/python tests/gui/reauthentication.py --script tests/gui/v2_reauthentication_scenario.json
gui-smoke:
	.local/venv/bin/python tests/gui/native_v2.py --script tests/gui/v2_scenario.json
gui-pending-smoke:
	.local/venv/bin/python tests/gui/native_v2.py --script tests/gui/v2_pending_scenario.json
gui-onboarding-recovery:
	.local/venv/bin/python tests/gui/onboarding_resume.py --script tests/gui/v2_resume_scenario.json
smoke:
	python3 tests/integration/smoke.py
	.local/venv/bin/python tests/integration/delivery.py
verify:
	bash scripts/verify.sh
down:
	bash scripts/down.sh
