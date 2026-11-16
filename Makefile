# Convenience targets for macOS and Linux. On Windows use lab.ps1.
EXEC = docker compose exec -T mssql bash /lab/scripts

.PHONY: up deploy drill perf maintain migrate test report all reset down destroy

.env:
	cp .env.example .env

up: .env
	docker compose up -d --wait

deploy drill perf maintain migrate test reset: up
	$(EXEC)/$@.sh

all: up
	$(EXEC)/all.sh
	$(MAKE) report

report:
	mkdir -p docs/evidence
	$(EXEC)/report.sh > docs/evidence/lab-report.md
	@echo "Wrote docs/evidence/lab-report.md"

down:
	docker compose down

destroy:
	docker compose down -v
