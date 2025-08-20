#!/bin/bash

# Usage: ./update_images_by_keyword.sh <keyword> <new_tag>
# Example: ./update_images_by_keyword.sh Bhaskar 5

set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <keyword> <new_tag>"
    exit 1
fi

KEYWORD="$1"
NEW_TAG="$2"

declare -A updated_deployments

echo "🔍 Scanning all pods for images containing keyword: '$KEYWORD'..."

kubectl get pods --all-namespaces -o json | jq -r \
  '.items[] | 
   {ns: .metadata.namespace, pod: .metadata.name, containers: .spec.containers[]} |
   select(.containers.image | contains("'"$KEYWORD"'")) |
   "\(.ns) \(.pod) \(.containers.name) \(.containers.image)"' | while read ns pod container image; do

    echo "📦 Found pod '$pod' in namespace '$ns' with container '$container' using image '$image'"

    # Extract base image name without tag (e.g., image/path:1 -> image/path)
    base_image="${image%%:*}"
    new_image="${base_image}:${NEW_TAG}"

    echo "🔁 New image to be set: $new_image"

    # Find the owning ReplicaSet
    owner_ref=$(kubectl -n "$ns" get pod "$pod" -o jsonpath="{.metadata.ownerReferences[0].name}")
    owner_kind=$(kubectl -n "$ns" get pod "$pod" -o jsonpath="{.metadata.ownerReferences[0].kind}")

    if [ "$owner_kind" != "ReplicaSet" ]; then
        echo "⚠️ Pod '$pod' is not owned by a ReplicaSet. Skipping."
        continue
    fi

    # Find the Deployment that owns the ReplicaSet
    deployment=$(kubectl -n "$ns" get rs "$owner_ref" -o jsonpath="{.metadata.ownerReferences[0].name}")

    if [ -z "$deployment" ]; then
        echo "⚠️ Could not find Deployment for ReplicaSet '$owner_ref'. Skipping."
        continue
    fi

    key="${ns}/${deployment}/${container}"
    if [[ -n "${updated_deployments[$key]:-}" ]]; then
        echo "ℹ️ Already updated deployment '$deployment' (container: '$container') in namespace '$ns'. Skipping."
        continue
    fi

    echo "🔧 Patching deployment '$deployment' (container: '$container') in namespace '$ns' to image '$new_image'"

    kubectl -n "$ns" set image deployment/"$deployment" "$container"="$new_image" || {
        echo "❌ Failed to update deployment '$deployment' in namespace '$ns'"
        continue
    }

    updated_deployments[$key]=1
    echo "✅ Updated deployment '$deployment' with new image '$new_image'"
done
