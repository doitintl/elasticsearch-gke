# elasticsearch-gke

This repository provides a blueprint for creating production grade configuration of
(Elastic Cloud on Kubernetes)[https://www.elastic.co/guide/en/cloud-on-k8s]
(later referenced just as "ECK") on GKE.

Running the makefile will get you:
* A GKE cluster with 3 node-pools for master nodes, data nodes, and the rest
* Master nodes spread across 3 zones
* Data nodes spread across two zones with ES
 [Shard Allocation Awareness](https://www.elastic.co/guide/en/elasticsearch/reference/current/allocation-awareness.html#allocation-awareness)
  enabled
* GKE CSI Driver enabled and ES data nodes provisioned with *pd-balanced* disk type
* Snapshot ready with:
  * Provisioned GCS bucket
  * Provisioned GCP service account and proper access level to the above bucket
  * Service account keys loaded into the ES
* Kibana and Cerebro launched and configured
* Dedicated K8s services provisioned to access ES cluster through coordinating nodes only

## Why?
ECK documentation is really good but it took me hours to conjure a production-like set of
YAMLs - and I'm well familiar with both ElasticSearch and Kubernetes.

This repo is an attempt to help those who tread on the similar path. The idea is to make
all YAML configuration in this repo as illustrative as possible and that's the reason
that nothing is templated in this repo (except ES cluster name), though the current
ECK CRD schema does cause a fair bit amount of YAML duplication.

## Enough talking, show me some goodies
* Decide on a fancy cluster name (alphanumeric and hyphen characters only).
  Export it as an env var:
  ```bash
  export ES_CLUSTER_NAME=<your fancy cluster name>
  ```
* Now run `make gke-create` to create a GKE cluster with all node pools. It takes a while.
* Create GCS bucket, service account, launch ECK operator and
* then create your ES cluster & friends by running:
  ```console
  make gcs-svcacc-create gcs-bucket-create eck-deploy es-deploy cerebro-deploy
  ```

And we are done! Let's play with it:
* Open another shell, export `ES_CLUSTER_NAME` again and run `make port-forward`
* Back to the first shell, run `make get-creds`, then open http://localhost:9000 to launch
  Cerebro console. Click on the preconfigured cluster URL and login with the obtained credentials.
* Similarly for Kibana which is available on http://localhost:5601.

Let's verify zone-ware shard allocation is working:
* Run `make create-index`
* Go to Cerebro console and verify that no shard/replica are residing in the same zone for
  the `test` index in question

Finally, to create backup repository in the ES that points to the created bucket, run
`make create-backup-repo`. Now you can manage snapshots through ES API or Kibana.
`make get-bucket` will reveal you the GCS bucket name in question.

Enjoy!

## Acknowledgements
Huge thanks to Elastic for creating ECK - while I did run ES on Kubernetes even before
the latter had StatefulSets, operating it through ECK is much, MUCH smoother experience.
