#!/bin/bash

# Fleet Enrollment Token (unbedingt anpassen!)
FLEET_ENROLLMENT_TOKEN="QTk5RUg1Z0JmSVIzeTR6X3l3aFk6RDdNMGpzYjhUV2U0MmhGT3JNYWMydw=="

# Optional: TAG setzen
AGENT_TAGS="synthetics"

# Start Elastic Synthetics Agent (Browser)
docker run -d \
  --name elastic-synthetics \
  --cap-add=NET_ADMIN \
  --net=host \
  -e FLEET_URL=https://fleet-server:8220 \
  -e FLEET_ENROLL=1 \
  -e FLEET_ENROLLMENT_TOKEN=${FLEET_ENROLLMENT_TOKEN} \
  -e ELASTIC_AGENT_TAGS="${AGENT_TAGS}" \
  docker.elastic.co/observability/elastic-agent-complete:8.13.2
