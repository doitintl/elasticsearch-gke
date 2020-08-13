PROJECT = zaar-playground
REGION = us-central1

ES_DATA_ZONES = "us-central1-a,us-central1-b"
ES_MASTER_ZONES = "us-central1-a,us-central1-b,us-central1-c"
APPS_ZONES = $(ES_DATA_ZONES)

ECK_VERSION = 1.2.1

GKE_VERSION = 1.16.11-gke.5
GKE_NAME = es

ES_DATA_INSTANCE_TYPE = n2-highmem-2
ES_MASTER_INSTANCE_TYPE = n1-standard-1
APPS_INSTANCE_TYPE = n1-standard-2

ES_DATA_NODES = 2    # per zone
ES_MASTER_NODES = 1  # per zone
APPS_NODES = 1  # per zone

GCP_PROJECT := $(shell gcloud config get-value core/project)
SVCACC = es-uluru-gcs
SVCACC_EMAIL = $(SVCACC)@$(GCP_PROJECT).iam.gserviceaccount.com
SVCACC_KEY_FILE = $(SVCACC).svcacc.key.json
# SVCACC_KEY_FILE = gcs.client.default.credentials_file
GCS_BUCKET = es-uluru-snapshots

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
	kubectl delete -f k8s/elasticsearch.yaml
	sleep 1m
	gcloud container clusters delete --quiet $(GKE_NAME) --region=$(REGION) ||:

gcs-svcacc-create:
	gcloud iam service-accounts create $(SVCACC)
	gcloud iam service-accounts keys create --iam-account=$(SVCACC_EMAIL) $(SVCACC_KEY_FILE)

gcs-svcacc-delete:
	gcloud iam service-accounts delete --quiet $(SVCACC_EMAIL)

gcs-bucket:
	gsutil mb gs://$(GCS_BUCKET)
	gsutil uniformbucketlevelaccess set on gs://$(GCS_BUCKET)
	gsutil iam ch serviceAccount:$(SVCACC_EMAIL):roles/storage.objectAdmin

sc-deploy:
	kubectl apply -f k8s/storage-class.yaml

eck-deploy:
	kubectl apply -f https://download.elastic.co/downloads/eck/$(ECK_VERSION)/all-in-one.yaml

es-deploy:
	kubectl create secret generic gcs-credentials --from-file=$(SVCACC_KEY_FILE) --dry-run -o yaml | \
	   	kubectl apply -f -
	kubectl apply -f k8s/elasticsearch.yaml
	kubectl apply -f k8s/service.yaml
	kubectl apply -f k8s/kibana.yaml

cerebro-deploy:
	# Pinned to cerebro 0.9.2
	curl -sSfL https://github.com/lmenezes/cerebro/raw/7a3815d8f5fb0097cd84cc644716da77205615c4/conf/application.conf | \
		sed -e 's|^secret = .*|secret = "$(shell xxd -l 48 -p -c 256  /dev/random)"|' \
		    -e '/^secret/a# It is not really secure to store the above in configmap, but at least better than using default secret' \
		    -e '/^hosts/a\  {\n    host = "https://es-uluru-coordinator-nodes:9200"\n    auth = {\n      username = elastic\n      password = $(shell kubectl get secret uluru-es-elastic-user -o=jsonpath='{.data.elastic}' | base64 --decode)\n    }\n  }' \
				-e '$$a \\n# Quick workaround to connect to es cluster through HTTPS\nplay.ws.ssl.loose.acceptAnyCertificate = true' | \
		kubectl create --dry-run -o yaml configmap cerebro --from-file=application.conf=/dev/stdin | \
		kubectl apply -f -
	kubectl apply -f k8s/cerebro.yaml


# FIXME: Define GCP repo in the ES
# https://www.elastic.co/guide/en/cloud-on-k8s/current/k8s-snapshots.html#k8s-create-repository