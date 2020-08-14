ifeq ($(ES_CLUSTER_NAME),)
$(error Please define and export ES_CLUSTER_NAME env var)
endif

REGION = us-central1

ES_DATA_ZONES = "us-central1-a,us-central1-b"
ES_MASTER_ZONES = "us-central1-a,us-central1-b,us-central1-c"
# Runs Cerebro, Kibana, etc.
APPS_ZONES = $(ES_DATA_ZONES)

ECK_VERSION = 1.2.1
ES_CLUSTER_NAME ?= uluru

GKE_VERSION = 1.16.11-gke.5
GKE_NAME = es

ES_DATA_INSTANCE_TYPE = n2-highmem-2
ES_MASTER_INSTANCE_TYPE = n1-standard-1
APPS_INSTANCE_TYPE = n1-standard-2

ES_DATA_NODES = 2    # per zone
ES_MASTER_NODES = 1  # per zone
APPS_NODES = 1       # per zone

GCP_PROJECT := $(shell gcloud config get-value core/project)
SVCACC = es-$(ES_CLUSTER_NAME)-gcs
SVCACC_EMAIL = $(SVCACC)@$(GCP_PROJECT).iam.gserviceaccount.com
SVCACC_KEY_FILE = $(SVCACC).svcacc.key.json
# SVCACC_KEY_FILE = gcs.client.default.credentials_file
GCS_BUCKET ?= es-$(ES_CLUSTER_NAME)-snapshots

TEXT_INDEX_NAME = test

gke-es-master-pool-create:
	gcloud container node-pools create es-master --cluster=$(GKE_NAME) \
		--region=$(REGION) \
		--num-nodes=$(ES_MASTER_NODES) --machine-type=$(ES_MASTER_INSTANCE_TYPE) \
		--image-type=COS --node-labels=workload=es-master \
		--node-locations $(ES_MASTER_ZONES)

gke-es-data-pool-create:
	gcloud container node-pools create es-data --cluster=$(GKE_NAME) \
		--region=$(REGION) \
		--num-nodes=$(ES_DATA_NODES) --machine-type=$(ES_DATA_INSTANCE_TYPE) \
		--image-type=COS --node-labels=workload=es-data \
		--node-locations $(ES_DATA_ZONES)

gke-apps-pool-create:
	gcloud container node-pools create apps --cluster=$(GKE_NAME) \
		--region=$(REGION) \
		--num-nodes=$(APPS_NODES) --machine-type=$(APPS_INSTANCE_TYPE) \
		--image-type=COS --node-labels=workload=apps \
		--node-locations $(APPS_ZONES)

gke-delete-default-pool:
	gcloud container node-pools delete default-pool --region=$(REGION) --quiet --cluster=$(GKE_NAME)

gke-create:
	gcloud beta container clusters create $(GKE_NAME) \
		--addons=GcePersistentDiskCsiDriver \
		--num-nodes=1 \
		--region=$(REGION) \
		--cluster-version=$(GKE_VERSION) \
		--enable-stackdriver-kubernetes --enable-ip-alias \
		--enable-autoupgrade --enable-autorepair
	gcloud container clusters get-credentials --region=$(REGION) $(GKE_NAME)

	$(MAKE) gke-es-master-pool-create
	$(MAKE) gke-es-data-pool-create
	$(MAKE) gke-apps-pool-create
	$(MAKE) gke-delete-default-pool

gke-delete:
	-$(MAKE) es-delete
	sleep 1m
	gcloud container clusters delete --quiet $(GKE_NAME) --region=$(REGION) ||:

gcs-svcacc-create:
	gcloud iam service-accounts describe $(SVCACC_EMAIL) >/dev/null 2>&1 || \
		gcloud iam service-accounts create $(SVCACC)
	gcloud iam service-accounts keys create --iam-account=$(SVCACC_EMAIL) $(SVCACC_KEY_FILE)

gcs-svcacc-delete:
	gcloud iam service-accounts delete --quiet $(SVCACC_EMAIL)

gcs-bucket-create:
	gsutil ls gs://$(GCS_BUCKET) >/dev/null 2>&1 || \
		gsutil mb gs://$(GCS_BUCKET)
	# gsutil uniformbucketlevelaccess set on gs://$(GCS_BUCKET)
	# gsutil iam ch serviceAccount:$(SVCACC_EMAIL):roles/storage.objectAdmin gs://$(GCS_BUCKET)
	#
	# Still need to use legacy ACLs until https://github.com/elastic/elasticsearch/pull/60899
	# is released. Once it does, uncomment the two commands above and remove the line below
	gsutil iam ch serviceAccount:$(SVCACC_EMAIL):roles/storage.legacyBucketWriter gs://$(GCS_BUCKET)

eck-deploy:
	kubectl apply -f https://download.elastic.co/downloads/eck/$(ECK_VERSION)/all-in-one.yaml

eck-delete:
	-kubectl delete -f https://download.elastic.co/downloads/eck/$(ECK_VERSION)/all-in-one.yaml

es-deploy:
	kubectl apply -f k8s/storage-class.yaml
	kubectl create secret generic gcs-credentials --from-file=$(SVCACC_KEY_FILE) --dry-run -o yaml | \
	   	kubectl apply -f -
	envsubst < k8s/elasticsearch.yaml | kubectl apply -f -
	envsubst < k8s/kibana.yaml | kubectl apply -f -

es-delete:
	-envsubst < k8s/elasticsearch.yaml | kubectl delete -f -
	-envsubst < k8s/kibana.yaml | kubectl delete -f -

cerebro-deploy:
	# Pinned to cerebro 0.9.2
	curl -sSfL https://github.com/lmenezes/cerebro/raw/7a3815d8f5fb0097cd84cc644716da77205615c4/conf/application.conf | \
		sed -e 's|^secret = .*|secret = "$(shell xxd -l 48 -p -c 256  /dev/random)"|' \
		    -e '/^secret/a# It is not really secure to store the above in configmap, but at least better than using default secret' \
		    -e '/^hosts/a\  {\n    host = "https://es-$(ES_CLUSTER_NAME)-coordinator-nodes:9200"\n  }' \
				-e '$$a \\n# Quick workaround to connect to es cluster through HTTPS\nplay.ws.ssl.loose.acceptAnyCertificate = true' | \
		kubectl create --dry-run -o yaml configmap cerebro --from-file=application.conf=/dev/stdin | \
		kubectl apply -f -
	kubectl apply -f k8s/cerebro.yaml

cerebro-delete:
	-kubectl delete -f k8s/cerebro.yaml
	-kubectl delete configmap cerebro

get-password:
	@echo $(shell kubectl get secret $(ES_CLUSTER_NAME)-es-elastic-user -o=jsonpath='{.data.elastic}' | base64 --decode)

get-creds:
	@echo username: elastic
	@echo password: $(shell $(MAKE) get-password)

get-bucket:
	@echo $(GCS_BUCKET)

port-forward:
	bash -c 'kubectl port-forward service/$(ES_CLUSTER_NAME)-kb-http 5601 & \
			 kubectl port-forward service/cerebro 9000 & \
			 kubectl port-forward service/es-$(ES_CLUSTER_NAME)-coordinator-nodes 9200 & \
			 wait'

create-index:
	curl -sSf -k -X PUT -u elastic:$$(make -s get-password) \
		-H 'Content-type: application/json' \
		https://localhost:9200/$(TEXT_INDEX_NAME) -d '{"settings": {"number_of_shards": 6, "number_of_replicas": 1}}' && echo

create-backup-repo:
	curl -sSf -k -X PUT -u elastic:$$(make -s get-password) \
		-H 'Content-type: application/json' \
		https://localhost:9200/_snapshot/gcs -d '{"type": "gcs", "settings": {"bucket": "$(GCS_BUCKET)", "client": "default"}}' && echo

# FIXME: Define GCP repo in the ES
# https://www.elastic.co/guide/en/cloud-on-k8s/current/k8s-snapshots.html#k8s-create-repository
