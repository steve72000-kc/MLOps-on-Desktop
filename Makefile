.PHONY: check up down endpoints gitops-init validate validate-container migrate-network

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

validate-container:
	docker run --rm -i \
		-v "$(CURDIR)":/work \
		-w /work \
		python:3.12-bookworm \
		sh -lc '\
			apt-get update && \
			DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends bash ca-certificates curl git shellcheck && \
			curl -L -o /usr/local/bin/kubectl "https://dl.k8s.io/release/v1.35.3/bin/linux/amd64/kubectl" && \
			chmod +x /usr/local/bin/kubectl && \
			kubectl version --client && \
			./scripts/validate.sh \
		'

migrate-network:
	./bootstrap/migrate-network.sh
