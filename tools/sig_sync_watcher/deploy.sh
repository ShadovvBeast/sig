#!/bin/bash
set -euo pipefail

# Sig Sync Watcher — GCP Cloud Run deployment
#
# Prerequisites:
#   - gcloud CLI authenticated
#   - GCP project with Cloud Run, Cloud Scheduler, Secret Manager, Cloud Build APIs enabled
#   - Service account: sig-sync-watcher@{PROJECT}.iam.gserviceaccount.com
#   - Secret: sig-sync-github-token in Secret Manager
#
# Usage:
#   ./deploy.sh [PROJECT_ID] [REGION]

PROJECT_ID="${1:-sbzero}"
REGION="${2:-us-central1}"
SERVICE_NAME="sig-sync-watcher"
SA_EMAIL="sig-sync-watcher@${PROJECT_ID}.iam.gserviceaccount.com"
GITHUB_REPO="ShadovvBeast/sig"
SCHEDULER_JOB="sig-sync-poll"

echo "==> Building and deploying to Cloud Run"
echo "    Project: $PROJECT_ID"
echo "    Region:  $REGION"
echo "    SA:      $SA_EMAIL"

# Deploy Cloud Run service with Secret Manager integration
gcloud run deploy "$SERVICE_NAME" \
  --project="$PROJECT_ID" \
  --region="$REGION" \
  --source=. \
  --platform=managed \
  --no-allow-unauthenticated \
  --service-account="$SA_EMAIL" \
  --memory=128Mi \
  --cpu=1 \
  --min-instances=0 \
  --max-instances=1 \
  --timeout=30s \
  --set-env-vars="GITHUB_REPO=$GITHUB_REPO" \
  --set-secrets="GITHUB_TOKEN=sig-sync-github-token:latest" \
  --quiet

# Get the service URL
SERVICE_URL=$(gcloud run services describe "$SERVICE_NAME" \
  --project="$PROJECT_ID" \
  --region="$REGION" \
  --format="value(status.url)")

echo "==> Service deployed at: $SERVICE_URL"

# Create Cloud Scheduler jobs (2 jobs offset by 30s for ~30s polling)
echo "==> Setting up Cloud Scheduler"

for OFFSET in 0 30; do
  JOB_NAME="${SCHEDULER_JOB}-${OFFSET}s"

  # Delete existing job if present
  gcloud scheduler jobs delete "$JOB_NAME" \
    --project="$PROJECT_ID" \
    --location="$REGION" \
    --quiet 2>/dev/null || true

  gcloud scheduler jobs create http "$JOB_NAME" \
    --project="$PROJECT_ID" \
    --location="$REGION" \
    --schedule="* * * * *" \
    --uri="${SERVICE_URL}/check" \
    --http-method=GET \
    --oidc-service-account-email="$SA_EMAIL" \
    --oidc-token-audience="$SERVICE_URL" \
    --attempt-deadline=30s \
    --quiet

  echo "  Created: $JOB_NAME"
done

echo ""
echo "==> Deployment complete!"
echo "    Service:   $SERVICE_URL"
echo "    Polling:   Every ~30 seconds"
echo "    RSS feed:  https://codeberg.org/ziglang/zig/rss/branch/master"
echo "    Dispatch:  https://api.github.com/repos/$GITHUB_REPO/dispatches"
