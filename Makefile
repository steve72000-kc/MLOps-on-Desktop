.PHONY: check up down endpoints gitops-init validate migrate-network

check:
	./bootstrap/check-prereqs.sh

up:
	./bootstrap/install.sh

down:
	./bootstrap/uninstall.sh

endpoints:
	./bootstrap/discover-endpoints.sh

gitops-init:
	./bootstrap/gitops-init.sh

validate:
	./scripts/validate.sh

migrate-network:
	./bootstrap/migrate-network.sh
