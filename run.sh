#!/bin/bash

set -e
set -o pipefail

KEEP_EVENT_HUB=${KEEP_EVENT_HUB:=false}
PRINT_METRICS=${PRINT_METRICS:=false}

if [ $EXISTING_EVENT_HUB ]; then
  KEEP_EVENT_HUB=true
  export EVENT_HUB_CONNECTION=$EXISTING_EVENT_HUB
else
  echo "Creating the Event Hub..."
  PARTITION_COUNT=${PARTITION_COUNT:=8}
  NAMESPACE_NAME=$(date +%s | shasum | base64 | head -c 16)
  CREATE_OUTPUT=$(az group deployment create --output json --resource-group $RESOURCE_GROUP --template-file azuredeploy.json --name $NAMESPACE_NAME --parameters namespaceName=$NAMESPACE_NAME partitionCount=$PARTITION_COUNT)

  export EVENT_HUB_CONNECTION=$(echo $CREATE_OUTPUT | python -c '
import sys, json
output = json.load(sys.stdin)
print output["properties"]["outputs"]["connectionString"]["value"]
')

  export EVENT_HUB_ID=$(export NAMESPACE_NAME=$NAMESPACE_NAME; echo $CREATE_OUTPUT | python -c '
import sys, json, os
output = json.load(sys.stdin)
print "%s/providers/Microsoft.EventHub/namespaces/%s" % ("/".join(output["id"].split("/")[:5]), os.environ["NAMESPACE_NAME"])
')
fi

TARGET_URL=$(node -e "require('./index.js').printUrl()")

IMAGE="vjrantal/wrk-with-online-script"
CONTAINER_PREFIX=$(date +%s)
CONTAINER_COUNT=${CONTAINER_COUNT:=8}

SLEEP_IN_SECONDS=${SLEEP_IN_SECONDS:=300}

# Default options is duration twice the amount of sleep
# so that the test takes at least as long as the time we
# keep the container alive
WRK_OPTIONS=${WRK_OPTIONS:="-d $((SLEEP_IN_SECONDS*2))"}
WRK_HEADER=$(node -e "require('./index.js').printHeader()")

echo "Creating the Container Instances..."

COUNTER=1
while [ $COUNTER -le $CONTAINER_COUNT ]; do
  az container create --output json -g $RESOURCE_GROUP --name $CONTAINER_PREFIX$COUNTER --image "$IMAGE" -e SCRIPT_URL="$WRK_SCRIPT_URL" TARGET_URL="$TARGET_URL" WRK_OPTIONS="$WRK_OPTIONS" WRK_HEADER="$WRK_HEADER" > /dev/null
  let COUNTER=COUNTER+1
done

echo "Sleeping for ${SLEEP_IN_SECONDS} seconds..."
sleep $SLEEP_IN_SECONDS

# for metrics, if you reused an existing event hub by exporting EXISTING_EVENT_HUB, please also export the corresponding EVENT_HUB_ID (format: /subscriptions/.../resourceGroups/.../providers/Microsoft.EventHub/namespaces/...)
if [[ $EVENT_HUB_ID && "$PRINT_METRICS" != true && "$KEEP_EVENT_HUB" = true ]]; then
  echo -e "Get metrics with the following command:\naz monitor metrics list --output json --resource $EVENT_HUB_ID --metric incomingMessages --interval P1D"
fi

if [[ $EVENT_HUB_ID && "$PRINT_METRICS" = true ]]; then
  METRICS_OUTPUT=$(az monitor metrics list --output json --resource $EVENT_HUB_ID --metric incomingMessages --interval P1D)
  echo $(echo $METRICS_OUTPUT | python -c '
import sys, json
output = json.load(sys.stdin)
print "The Event Hub currently has %s incoming messages" % (output[0]["data"][1]["total"])
')
fi

echo "Removing the Container Instances..."

COUNTER=1
while [ $COUNTER -le $CONTAINER_COUNT ]; do
  az container delete -g $RESOURCE_GROUP --name $CONTAINER_PREFIX$COUNTER --yes > /dev/null
  let COUNTER=COUNTER+1
done

if [ "$KEEP_EVENT_HUB" = true ]; then
  echo "The Event Hub was not removed..."
else
  echo "Removing the Event Hub..."
  # Ignore the return value of above command, because sometimes error value is
  # returned even when the resource deletion succeeds.
  az resource delete --id $EVENT_HUB_ID || true
fi
