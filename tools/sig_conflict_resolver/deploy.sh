#!/bin/bash
set -euo pipefail

# Sig Conflict Resolver — GCP Cloud Run deployment
#
# Prerequisites:
#   - gcloud CLI authenticated
#   - GCP project with Cloud Run, Vertex AI, Cloud Build APIs enabled
#   - Service account: sig-sync-watcher@{PROJECT}.iam.gserviceaccount.com
#
# Usage:
#   ./deploy.sh [PROJECT_ID] [REGION]

PROJECT_ID="${1:-sbzero}"
REGION="${2:-us-central1}"
SERVICE_NAME="sig-conflict-resolver"
SA_EMAIL="sig-sync-watcher@${PROJECT_ID}.iam.gserviceaccount.com"
CUSTOM_DOMAIN="conflict.sig.best"

echo "==> Building and deploying to Cloud Run"
echo "    Project: $PROJECT_ID"
echo "    Region:  $REGION"
echo "    SA:      $SA_EMAIL"

# Deploy Cloud Run service
gcloud run deploy "$SERVICE_NAME" \
  --project="$PROJECT_ID" \
  --region="$REGION" \
  --source=. \
  --platform=managed \
  --no-allow-unauthenticated \
  --service-account="$SA_EMAIL" \
  --memory=256Mi \
  --cpu=1 \
  --min-instances=0 \
  --max-instances=2 \
  --timeout=120s \
  --set-env-vars="GCP_PROJECT=$PROJECT_ID,GCP_REGION=$REGION,GEMINI_MODEL=gemini-2.0-flash" \
  --quiet

# Get the service URL
SERVICE_URL=$(gcloud run services describe "$SERVICE_NAME" \
  --project="$PROJECT_ID" \
  --region="$REGION" \
  --format="value(status.url)")

echo "==> Service deployed at: $SERVICE_URL"

# Map custom domain
echo "==> Mapping custom domain: $CUSTOM_DOMAIN"
gcloud run domain-mappings create \
  --service="$SERVICE_NAME" \
  --domain="$CUSTOM_DOMAIN" \
  --project="$PROJECT_ID" \
  --region="$REGION" \
  --quiet 2>/dev/null || echo "  Domain mapping already exists"

echo ""
echo "==> Deployment complete!"
echo "    Service:   $CUSTOM_DOMAIN (Cloud Run: $SERVICE_URL)"
echo "    Invoked:   On-demand by GitHub Actions (no scheduler)"
echo "    Endpoint:  POST /resolve"
