FROM postgres:latest

VOLUME ["/backup"]
ADD https://storage.googleapis.com/kubernetes-release/release/v1.8.5/bin/linux/amd64/kubectl /bin/
RUN chmod +x /bin/kubectl
RUN apt-get update \
	&& apt-get install -y jq \
	&& rm -rf /var/lib/apt/lists/*
ADD docker-entrypoint.sh \
	deploy-tmpl.yaml \
	postgresqls.exp.wheel.jp-crd.yaml \
	svc-tmpl.yaml \
	/

CMD ["/docker-entrypoint.sh"]
