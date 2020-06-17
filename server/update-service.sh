export AWS_PAGER=""

CLUSTER_NAME=mesh
MESH_NAME=echo-mesh
NAMESPACE=echo.local
SERVICE_NAME=echo_server
VIRTUAL_ROUTER_NAME=virtual-router
ROUTE_NAME=route
VERSION=$(date +%Y%m%d%H%M%S)

# Desired number of Tasks to run on ECS
DESIRED_COUNT=2

# Subnets & Security Groups to launch the ECS Service
PRIVATE_SUBNET_1=subnet-0274f96968481c828
PRIVATE_SUBNET_2=subnet-0667ed5ab8cd664cb
SECURITY_GROUP=sg-0db5043bcff9192e8

VIRTUAL_NODE_NAME=${SERVICE_NAME}-${VERSION}
ECS_SERVICE_NAME=${SERVICE_NAME}-${VERSION}-service

create_virtual_node() {
  echo "Creating Virtual Node: $VIRTUAL_NODE_NAME"
  SPEC=$(cat <<-EOF
{
    "serviceDiscovery": {
        "awsCloudMap": {
            "namespaceName": "$NAMESPACE",
            "serviceName": "$SERVICE_NAME",
            "attributes": [
                {
                    "key": "ECS_TASK_SET_EXTERNAL_ID",
                    "value": "${VIRTUAL_NODE_NAME}-task-set"
                }
            ]
        }
    },
    "listeners": [
        {
            "healthCheck": {
                "healthyThreshold": 2,
                "intervalMillis": 5000,
                "port": 8080,
                "protocol": "grpc",
                "timeoutMillis": 2000,
                "unhealthyThreshold": 3
            },
            "portMapping": {
                "port": 8080,
                "protocol": "grpc"
            }
        }
    ]
}
EOF
)
  # Create app mesh virtual node #
  aws appmesh create-virtual-node \
    --mesh-name $MESH_NAME \
    --virtual-node-name $VIRTUAL_NODE_NAME \
    --spec "$SPEC"
}

# based on the existing route definition, we'll add the newly created virtual node to the list, but not forwarding any traffic
init_traffic_route() {
  echo "Updating the traffic route definition"
  SPEC=$(aws appmesh describe-route --mesh-name $MESH_NAME --virtual-router-name $VIRTUAL_ROUTER_NAME --route-name $ROUTE_NAME \
         | jq ".route.spec" | jq '.grpcRoute.action.weightedTargets += [{"virtualNode":"'$VIRTUAL_NODE_NAME'", "weight": 0}]')
  aws appmesh update-route --mesh-name $MESH_NAME --virtual-router-name $VIRTUAL_ROUTER_NAME --route-name $ROUTE_NAME --spec "$SPEC"
}

register_new_task() {
  echo "Registering new task definition"
  TASK_DEF_ARN=$(aws ecs list-task-definitions | \
    jq -r ' .taskDefinitionArns[] | select( . | contains("'$SERVICE_NAME'"))' | tail -1)
  TASK_DEF_OLD=$(aws ecs describe-task-definition --task-definition $TASK_DEF_ARN);
  TASK_DEF_NEW=$(echo $TASK_DEF_OLD \
    | jq ' .taskDefinition' \
    | jq ' .containerDefinitions[].environment |= map(
          if .name=="APPMESH_VIRTUAL_NODE_NAME" then 
                .value="mesh/'$MESH_NAME'/virtualNode/'$VIRTUAL_NODE_NAME'" 
          else . end) ' \
    | jq ' del(.status, .compatibilities, .taskDefinitionArn, .requiresAttributes, .revision) '
  ); \
  TASK_DEF_FAMILY=$(echo $TASK_DEF_ARN | cut -d"/" -f2 | cut -d":" -f1);
  echo $TASK_DEF_NEW > /tmp/$TASK_DEF_FAMILY.json && 
  # Register ecs task definition #
  aws ecs register-task-definition \
    --cli-input-json file:///tmp/$TASK_DEF_FAMILY.json
}

create_ecs_service() {
  echo "Creating a new ECS Service: $ECS_SERVICE_NAME"
  aws ecs create-service \
    --cluster $CLUSTER_NAME \
    --service-name $ECS_SERVICE_NAME \
    --desired-count $DESIRED_COUNT \
    --deployment-controller type=EXTERNAL
}

create_task_set() {
  echo "Creating a new task set"
  SERVICE_ARN=$(aws ecs list-services --cluster $CLUSTER_NAME | \
    jq -r ' .serviceArns[] | select( . | contains("'$ECS_SERVICE_NAME'"))' | tail -1)
  TASK_DEF_ARN=$(aws ecs list-task-definitions | \
    jq -r ' .taskDefinitionArns[] | select( . | contains("'$SERVICE_NAME'"))' | tail -1)
  CMAP_SVC_ARN=$(aws servicediscovery list-services | \
    jq -r '.Services[] | select(.Name == "'$SERVICE_NAME'") | .Arn');
  # Create ecs task set #
  aws ecs create-task-set \
    --service $SERVICE_ARN \
    --cluster $CLUSTER_NAME \
    --external-id $VIRTUAL_NODE_NAME-task-set \
    --task-definition "$(echo $TASK_DEF_ARN)" \
    --service-registries "registryArn=$CMAP_SVC_ARN" \
    --scale value=100,unit=PERCENT \
    --launch-type FARGATE \
    --network-configuration \
        "awsvpcConfiguration={subnets=[$PRIVATE_SUBNET_1,$PRIVATE_SUBNET_2],
          securityGroups=[$SECURITY_GROUP],
          assignPublicIp=DISABLED}"
}

wait_for_ecs_service() {
  echo "Waiting for ECS Service to be in RUNNING state..."
  TASK_DEF_ARN=$(aws ecs list-task-definitions | \
    jq -r ' .taskDefinitionArns[] | select( . | contains("'$SERVICE_NAME'"))' | tail -1);
  CMAP_SVC_ID=$(aws servicediscovery list-services | \
    jq -r '.Services[] | select(.Name == "'$SERVICE_NAME'") | .Id');

  # Get number of running tasks #
  _list_tasks() {
    aws ecs list-tasks --cluster $CLUSTER_NAME --service $ECS_SERVICE_NAME | \
      jq -r ' .taskArns | @text' | \
        while read taskArns; do 
          aws ecs describe-tasks --cluster $CLUSTER_NAME --tasks $taskArns;
        done | \
      jq -r --arg TASK_DEF_ARN $TASK_DEF_ARN \
        ' [.tasks[] | select( (.taskDefinitionArn == $TASK_DEF_ARN) 
                        and (.lastStatus == "RUNNING" ))] | length'
  }

  # Get count of instances with unhealth status #
  _count_unhealthy_instances() {
    aws servicediscovery get-instances-health-status --service-id $CMAP_SVC_ID | \
      jq ' [.Status | to_entries[] | select( .value != "HEALTHY")] | length'
  }

  until [ "$(_list_tasks)" -ge $DESIRED_COUNT ]; do
    echo "Tasks are starting ($(_list_tasks)/$DESIRED_COUNT)..."
    sleep 10s
    if [ "$(_list_tasks)" -ge $DESIRED_COUNT ]; then
      echo "Tasks started"
      break
    fi
  done
  sleep 10s
  until [ "$(_count_unhealthy_instances)" -eq 0 ]; do
    echo "Waiting for All Instances to be in HEALTHY status (Waiting for $(_count_unhealthy_instances) instances)..."
    sleep 10s
    if [ "$(_count_unhealthy_instances)" -eq 0 ]; then
      echo "All instances area HEALTHY"
      break
    fi
  done
}

update_traffic_route() {
  echo "Updating traffic route"
  SPEC=$(aws appmesh describe-route --mesh-name $MESH_NAME --virtual-router-name $VIRTUAL_ROUTER_NAME --route-name $ROUTE_NAME \
    | jq ".route.spec" | jq '.grpcRoute.action.weightedTargets |= map({"virtualNode":.virtualNode, "weight": 1})' | jq '.grpcRoute.action.weightedTargets |= [.[-2,-1]]')
  echo $SPEC
  aws appmesh update-route --mesh-name $MESH_NAME --virtual-router-name $VIRTUAL_ROUTER_NAME --route-name $ROUTE_NAME --spec "$SPEC"
}

switch_traffic_route() {
  echo "Updating traffic route"
  SPEC=$(aws appmesh describe-route --mesh-name $MESH_NAME --virtual-router-name $VIRTUAL_ROUTER_NAME --route-name $ROUTE_NAME \
    | jq ".route.spec" | jq '.grpcRoute.action.weightedTargets |= map({"virtualNode":.virtualNode, "weight": 1})' | jq '.grpcRoute.action.weightedTargets |= [.[-1]]')
  echo $SPEC
  aws appmesh update-route --mesh-name $MESH_NAME --virtual-router-name $VIRTUAL_ROUTER_NAME --route-name $ROUTE_NAME --spec "$SPEC"
}


create_virtual_node
init_traffic_route 
register_new_task
create_ecs_service
create_task_set
wait_for_ecs_service

update_traffic_route
echo "Routing 50% of traffic to the new service"
sleep 15
switch_traffic_route
echo "Routing 100% of traffic to the new service"

echo New Virtual Node: $VIRTUAL_NODE_NAME
echo New ECS Service: $ECS_SERVICE_NAME
